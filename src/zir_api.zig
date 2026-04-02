//! ZIR Library API
//!
//! C-ABI surface for creating a Zig compilation, injecting pre-built ZIR
//! (bypassing AstGen), running Sema/codegen/link, and producing a binary.
//!
//! This allows external compilers (e.g. Zap) to lower directly to ZIR and
//! feed it into the Zig compiler pipeline without going through source text.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const fs = std.fs;
const assert = std.debug.assert;

const zir_builder = @import("zir_builder.zig");
const Compilation = @import("Compilation.zig");
const Zcu = @import("Zcu.zig");
const Package = @import("Package.zig");
const link = @import("link.zig");
const Zir = std.zig.Zir;
const Cache = std.Build.Cache;
const introspect = @import("introspect.zig");
const target_util = @import("target.zig");
const build_options = @import("build_options");

/// Flat, C-ABI-safe representation of ZIR data.
/// The caller builds these arrays directly, matching the internal Zir layout.
pub const ZirData = extern struct {
    /// Array of Zir.Inst.Tag values (each is a u8).
    instructions_tags: [*]u8,
    /// Array of Zir.Inst.Data values, encoded as raw bytes.
    /// Each element is @sizeOf(Zir.Inst.Data) bytes.
    instructions_data: [*]u8,
    instructions_len: u32,

    /// Interned string pool. Index 0 is reserved.
    string_bytes: [*]u8,
    string_bytes_len: u32,

    /// Overflow payload data.
    extra: [*]u32,
    extra_len: u32,
};

/// Opaque context wrapping a Compilation plus its owned resources.
pub const ZirContext = struct {
    gpa: Allocator,
    /// Arena that owns the Compilation and related long-lived allocations.
    arena_state: std.heap.ArenaAllocator,
    thread_pool: *std.Thread.Pool,
    dirs: Compilation.Directories,
    compilation: *Compilation,
    root_mod: *Package.Module,
    output_mode: std.builtin.OutputMode = .Exe,
    /// Builder mode: the compiled binary is a build system builder.
    /// The stub source sets up a runtime that reads os_argv, constructs
    /// a Zap.Env struct, calls the configured entry point function, and
    /// serializes the returned Zap.Manifest to stdout.
    is_builder: bool = false,
    /// The entry point function name for builder mode (e.g., "manifest").
    /// Set via zir_compilation_set_builder_entry.
    builder_entry: ?[]const u8 = null,
    /// The module-qualified entry point (e.g., "FooBar__Builder__manifest").
    /// This is the mangled name as it appears in ZIR.
    builder_entry_mangled: ?[]const u8 = null,

    pub fn arena(self: *ZirContext) Allocator {
        return self.arena_state.allocator();
    }
};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Create a new compilation context targeting the native platform.
///
/// All path arguments are null-terminated C strings.
/// Returns null on failure.
pub export fn zir_compilation_create(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
) ?*ZirContext {
    return createImpl(
        mem.sliceTo(zig_lib_dir, 0),
        mem.sliceTo(local_cache_dir, 0),
        mem.sliceTo(global_cache_dir, 0),
        mem.sliceTo(output_path, 0),
        mem.sliceTo(root_name, 0),
        output_mode,
        optimize_mode,
        is_dynamic,
        link_libc,
    ) catch null;
}

/// Inject pre-built ZIR into the compilation.
/// The ZIR data is copied; the caller may free it after this call.
/// Returns 0 on success, non-zero on error.
pub export fn zir_compilation_add_zir(
    ctx: *ZirContext,
    name: [*:0]const u8,
    data: *const ZirData,
) i32 {
    addZirImpl(ctx, mem.sliceTo(name, 0), data) catch return -1;
    return 0;
}

/// Run semantic analysis, codegen, and linking.
/// Returns 0 on success, non-zero if errors occurred.
pub export fn zir_compilation_update(ctx: *ZirContext) i32 {
    const prog_node = std.Progress.start(.{});
    defer prog_node.end();
    ctx.compilation.update(prog_node) catch |err| {
        logErr("update failed: {s}", .{@errorName(err)});
        // Print detailed errors
        var error_bundle = ctx.compilation.getAllErrorsAlloc() catch |e| {
            logErr("getAllErrorsAlloc failed: {s}", .{@errorName(e)});
            return -1;
        };
        defer error_bundle.deinit(ctx.gpa);
        const count = error_bundle.errorMessageCount();
        logErr("error count from update catch: {d}", .{count});
        if (count > 0) {
            const stderr = std.debug.lockStderrWriter(&.{});
            defer std.debug.unlockStderrWriter();
            error_bundle.renderToWriter(.{
                .ttyconf = .no_color,
                .include_source_line = false,
                .include_reference_trace = false,
            }, stderr) catch |render_err| {
                logErr("renderToWriter failed: {s}", .{@errorName(render_err)});
            };
        } else {
            logErr("no error messages in bundle despite error count", .{});
        }
        return -1;
    };
    if (ctx.compilation.anyErrors()) {
        var error_bundle = ctx.compilation.getAllErrorsAlloc() catch |e| {
            logErr("getAllErrorsAlloc failed: {s}", .{@errorName(e)});
            return -1;
        };
        defer error_bundle.deinit(ctx.gpa);
        dumpErrorBundle(error_bundle);
        return -1;
    }
    return 0;
}

fn dumpErrorBundle(eb: std.zig.ErrorBundle) void {
    const w = std.fs.File.stderr().deprecatedWriter();
    const count = eb.errorMessageCount();
    w.print("\n=== {d} compilation error(s) ===\n", .{count}) catch return;

    if (eb.extra.len == 0) {
        w.print("(error bundle extra array is empty)\n", .{}) catch return;
        return;
    }

    const messages = eb.getMessages();
    for (messages, 0..) |msg_index, i| {
        const err_msg = eb.getErrorMessage(msg_index);
        const text = eb.nullTerminatedString(err_msg.msg);

        if (err_msg.src_loc != .none) {
            const src = eb.getSourceLocation(err_msg.src_loc);
            const path = eb.nullTerminatedString(src.src_path);
            w.print("[{d}] {s}:{d}:{d}: error: {s}\n", .{
                i, path, src.line + 1, src.column + 1, text,
            }) catch return;
        } else {
            w.print("[{d}] error: {s}\n", .{ i, text }) catch return;
        }

        for (eb.getNotes(msg_index)) |note_index| {
            const note = eb.getErrorMessage(note_index);
            const note_text = eb.nullTerminatedString(note.msg);
            if (note.src_loc != .none) {
                const note_src = eb.getSourceLocation(note.src_loc);
                const note_path = eb.nullTerminatedString(note_src.src_path);
                w.print("       {s}:{d}:{d}: note: {s}\n", .{
                    note_path, note_src.line + 1, note_src.column + 1, note_text,
                }) catch return;
            } else {
                w.print("       note: {s}\n", .{note_text}) catch return;
            }
        }
    }
    w.print("=== end errors ===\n", .{}) catch return;
}

/// Print compilation errors to stderr.
pub export fn zir_compilation_print_errors(ctx: *ZirContext) void {
    var error_bundle = ctx.compilation.getAllErrorsAlloc() catch |err| {
        logErr("getAllErrorsAlloc failed: {s}", .{@errorName(err)});
        return;
    };
    defer error_bundle.deinit(ctx.gpa);
    const count = error_bundle.errorMessageCount();
    if (count == 0) {
        logErr("anyErrors() true but errorMessageCount=0", .{});
        return;
    }

    logErr("error count: {d}", .{count});
    const stderr = std.debug.lockStderrWriter(&.{});
    defer std.debug.unlockStderrWriter();
    error_bundle.renderToWriter(.{
        .ttyconf = .no_color,
        .include_source_line = false,
        .include_reference_trace = false,
    }, stderr) catch {};
}

/// Add a named module dependency so the root module can @import it.
/// `name` is the import name (e.g., "zap_runtime").
/// `source_path` is the full path to the .zig source file.
/// Returns 0 on success, -1 on error.
pub export fn zir_compilation_add_module(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_path: [*:0]const u8,
) callconv(.c) i32 {
    addModuleImpl(ctx, mem.sliceTo(name, 0), mem.sliceTo(source_path, 0)) catch return -1;
    return 0;
}

/// Register a Zig module from an in-memory source buffer instead of a file path.
/// The source is written to a file in the compilation's cache directory,
/// then registered as a module dependency of the root module.
/// `name` is the import name (null-terminated C string).
/// `source_ptr`/`source_len` is the Zig source code.
/// Returns 0 on success, -1 on error.
pub export fn zir_compilation_add_module_source(
    ctx: ?*ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) callconv(.c) i32 {
    const c = ctx orelse return -1;
    addModuleSourceImpl(c, mem.sliceTo(name, 0), source_ptr[0..source_len]) catch return -1;
    return 0;
}

/// Configure the compilation as a builder binary.
/// The builder's stub source sets up a runtime that:
/// 1. Reads os_argv to get target, os, arch, and -D flags
/// 2. Constructs a Zap.Env struct from those args
/// 3. Calls the configured entry point function with the env
/// 4. Serializes the returned Zap.Manifest fields to stdout
///
/// `entry_name` is the mangled function name (e.g., "FooBar__Builder__manifest").
/// Must be called after create and before addZir/update.
pub export fn zir_compilation_set_builder_entry(
    ctx: ?*ZirContext,
    entry_name: [*:0]const u8,
) callconv(.c) i32 {
    const c = ctx orelse return -1;
    const ar = c.arena();
    c.is_builder = true;
    c.builder_entry_mangled = ar.dupe(u8, mem.sliceTo(entry_name, 0)) catch return -1;
    return 0;
}

/// Link a system library by name (e.g., "m" for libm).
/// Searches standard system library directories for the library file.
/// Must be called after create and before update.
/// Returns 0 on success, -1 if the library was not found.
pub export fn zir_compilation_add_link_lib(
    ctx: ?*ZirContext,
    name: [*:0]const u8,
) callconv(.c) i32 {
    const c = ctx orelse return -1;
    addLinkLibImpl(c, mem.sliceTo(name, 0)) catch return -1;
    return 0;
}

/// Destroy the compilation context and free all resources.
pub export fn zir_compilation_destroy(ctx: *ZirContext) void {
    const gpa = ctx.gpa;

    if (ctx.compilation.zcu) |zcu| zcu.deinit();
    ctx.dirs.deinit();
    ctx.thread_pool.deinit();
    gpa.destroy(ctx.thread_pool);
    ctx.arena_state.deinit();
    gpa.destroy(ctx);
}

// ---------------------------------------------------------------------------
// Internal: compilation creation
// ---------------------------------------------------------------------------

fn addModuleImpl(ctx: *ZirContext, name: []const u8, source_path: []const u8) !void {
    const ar = ctx.arena();

    // Separate directory and filename from the source path.
    const dir_path = std.fs.path.dirname(source_path) orelse ".";
    const file_name = std.fs.path.basename(source_path);

    // Resolve the module root directory.
    const mod_root = Compilation.Path.fromUnresolved(ar, ctx.dirs, &.{dir_path}) catch
        return error.OutOfMemory;

    // Create the module as a child of the root module (inherits config).
    const mod = Package.Module.create(ar, .{
        .paths = .{
            .root = mod_root,
            .root_src_path = try ar.dupe(u8, file_name),
        },
        .fully_qualified_name = try ar.dupe(u8, name),
        .cc_argv = &.{},
        .inherited = .{},
        .global = ctx.compilation.config,
        .parent = ctx.root_mod,
    }) catch return error.OutOfMemory;

    // Register as a dependency of the root module.
    const name_duped = try ar.dupe(u8, name);
    try ctx.root_mod.deps.put(ar, name_duped, mod);

    // Register the new module in module_roots so doImport can find its file.
    // We can't re-call populateModuleRootTable because it overwrites existing
    // entries with undefined values. Instead, manually add just this module.
    const zcu = ctx.compilation.zcu orelse return error.OutOfMemory;
    const gpa = zcu.gpa;

    // Build the path for the new module's source file.
    const path = try mod.root.join(gpa, ctx.dirs, mod.root_src_path);
    errdefer path.deinit(gpa);

    // Check if this file is already in the import table.
    const gop = try zcu.import_table.getOrPutAdapted(gpa, path, Zcu.ImportTableAdapter{ .zcu = zcu });

    if (gop.found_existing) {
        path.deinit(gpa);
        try zcu.module_roots.put(gpa, mod, gop.key_ptr.*.toOptional());
    } else {
        // Create a new File for this module.
        const new_file = try gpa.create(Zcu.File);
        const pt: Zcu.PerThread = .activate(zcu, .main);
        defer pt.deactivate();
        const new_file_index = try zcu.intern_pool.createFile(gpa, pt.tid, .{
            .bin_digest = path.digest(),
            .file = new_file,
            .root_type = .none,
        });
        gop.key_ptr.* = new_file_index;
        new_file.* = .{
            .status = .never_loaded,
            .path = path,
            .stat = undefined,
            .is_builtin = false,
            .source = null,
            .tree = null,
            .zir = null,
            .zoir = null,
            .mod = mod,
            .sub_file_path = try gpa.dupe(u8, file_name),
            .module_changed = false,
            .prev_zir = null,
            .zoir_invalidated = false,
        };
        try zcu.module_roots.put(gpa, mod, new_file_index.toOptional());
    }

    // Ensure all files in module_roots have sub_file_path set.
    // Files created by populateModuleRootTable leave sub_file_path undefined,
    // and updateAliveFiles may not run for dynamically-added modules.
    for (zcu.module_roots.keys(), zcu.module_roots.values()) |m, opt_file_idx| {
        if (opt_file_idx.unwrap()) |file_idx| {
            const f = zcu.fileByIndex(file_idx);
            // Check if sub_file_path is undefined (pointer is sentinel value)
            const ptr_val = @intFromPtr(f.sub_file_path.ptr);
            if (ptr_val == 0 or ptr_val == 0x5555555555555555 or ptr_val == 0xaaaaaaaaaaaaaaaa) {
                f.sub_file_path = m.root_src_path;
                if (f.mod == null) f.mod = m;
            }
        }
    }
}

fn addModuleSourceImpl(ctx: *ZirContext, name: []const u8, source: []const u8) !void {
    const ar = ctx.arena();

    // Build a path within the local cache directory for the source file.
    const cache_path = ctx.dirs.local_cache.path orelse return error.OutOfMemory;
    const sub_dir = try std.fmt.allocPrint(ar, "{s}/zap_modules", .{cache_path});
    const file_name = try std.fmt.allocPrint(ar, "{s}.zig", .{name});
    const full_path = try std.fmt.allocPrint(ar, "{s}/{s}", .{ sub_dir, file_name });

    // Ensure the subdirectory exists.
    fs.cwd().makePath(sub_dir) catch |err| {
        logErr("addModuleSource: makePath failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Write the source to disk.
    fs.cwd().writeFile(.{
        .sub_path = full_path,
        .data = source,
    }) catch |err| {
        logErr("addModuleSource: writeFile failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Null-terminate the strings for the C-ABI add_module path.
    const full_path_z = try ar.dupeZ(u8, full_path);

    // Register the module using the existing addModuleImpl.
    try addModuleImpl(ctx, name, full_path_z);
}

fn addLinkLibImpl(ctx: *ZirContext, lib_name: []const u8) !void {
    const ar = ctx.arena();
    const target = &ctx.root_mod.resolved_target.result;

    // Library search paths (platform-specific)
    const search_dirs: []const []const u8 = if (target.os.tag.isDarwin())
        &.{
            "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib",
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib",
            "/usr/lib",
            "/opt/homebrew/lib",
            "/usr/local/lib",
        }
    else
        &.{
            "/usr/lib",
            "/usr/lib/x86_64-linux-gnu",
            "/usr/local/lib",
            "/lib",
        };

    // File extensions to try (prefer dynamic, fall back to static)
    const exts: []const []const u8 = if (target.os.tag.isDarwin())
        &.{ ".tbd", ".dylib", ".a" }
    else
        &.{ ".so", ".a" };

    for (search_dirs) |dir_path| {
        for (exts) |ext| {
            const file_name = std.fmt.allocPrint(ar, "lib{s}{s}", .{ lib_name, ext }) catch continue;
            const full_path = std.fmt.allocPrint(ar, "{s}/{s}", .{ dir_path, file_name }) catch continue;

            var file = fs.cwd().openFile(full_path, .{}) catch continue;
            errdefer file.close();

            // Found the library — open the containing directory for the Path
            var dir = fs.cwd().openDir(dir_path, .{}) catch {
                file.close();
                continue;
            };
            errdefer dir.close();

            const is_shared = !mem.endsWith(u8, ext, ".a");
            const path: Cache.Path = .{
                .root_dir = .{ .handle = dir, .path = ar.dupe(u8, dir_path) catch null },
                .sub_path = file_name,
            };

            // Grow the link_inputs slice
            const old = ctx.compilation.link_inputs;
            const new = try ar.alloc(link.Input, old.len + 1);
            @memcpy(new[0..old.len], old);

            if (is_shared) {
                new[old.len] = .{ .dso = .{
                    .path = path,
                    .file = file,
                    .needed = true,
                    .weak = false,
                    .reexport = false,
                } };
            } else {
                new[old.len] = .{ .archive = .{
                    .path = path,
                    .file = file,
                    .must_link = false,
                    .hidden = false,
                } };
            }

            ctx.compilation.link_inputs = new;
            return;
        }
    }

    logErr("system library not found: lib{s}", .{lib_name});
    return error.OutOfMemory;
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.debug.lockStderrWriter(&.{});
    defer std.debug.unlockStderrWriter();
    stderr.print("zir_api: " ++ fmt ++ "\n", args) catch {};
}

fn createImpl(
    zig_lib_dir_path: []const u8,
    local_cache_dir_path: []const u8,
    global_cache_dir_path: []const u8,
    output_path: []const u8,
    root_name_str: []const u8,
    output_mode_raw: u8,
    optimize_mode_raw: u8,
    is_dynamic: bool,
    do_link_libc: bool,
) !*ZirContext {
    // Use c_allocator (libc malloc) instead of page_allocator.
    // page_allocator creates one mmap per allocation, hitting the kernel's
    // per-process mapping limit before physical memory runs out.
    const gpa = std.heap.c_allocator;

    const ctx = gpa.create(ZirContext) catch {
        logErr("failed to allocate ZirContext", .{});
        return error.OutOfMemory;
    };
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .arena_state = undefined,
        .thread_pool = undefined,
        .dirs = undefined,
        .compilation = undefined,
        .root_mod = undefined,
    };
    ctx.arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer ctx.arena_state.deinit();
    const ar = ctx.arena_state.allocator();

    // Thread pool.
    const tp = gpa.create(std.Thread.Pool) catch {
        logErr("failed to allocate ThreadPool", .{});
        return error.OutOfMemory;
    };
    errdefer gpa.destroy(tp);
    tp.* = undefined;
    // Limit thread pool to reduce concurrent memory pressure from MIR codegen.
    const cpu_count: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 4));
    tp.init(.{ .allocator = gpa, .n_jobs = cpu_count, .track_ids = true }) catch {
        logErr("ThreadPool.init failed", .{});
        return error.OutOfMemory;
    };
    ctx.thread_pool = tp;

    // Open directory handles.
    const zig_lib_handle = fs.cwd().openDir(zig_lib_dir_path, .{}) catch |err| {
        logErr("openDir(zig_lib={s}) failed: {s}", .{ zig_lib_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };
    const local_cache_handle = fs.cwd().openDir(local_cache_dir_path, .{}) catch |err| {
        logErr("openDir(local_cache={s}) failed: {s}", .{ local_cache_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };
    const global_cache_handle = fs.cwd().openDir(global_cache_dir_path, .{}) catch |err| {
        logErr("openDir(global_cache={s}) failed: {s}", .{ global_cache_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };

    ctx.dirs = .{
        .cwd = try introspect.getResolvedCwd(ar),
        .zig_lib = .{ .handle = zig_lib_handle, .path = try ar.dupe(u8, zig_lib_dir_path) },
        .local_cache = .{ .handle = local_cache_handle, .path = try ar.dupe(u8, local_cache_dir_path) },
        .global_cache = .{ .handle = global_cache_handle, .path = try ar.dupe(u8, global_cache_dir_path) },
    };

    // Native target resolution.
    const target_query = std.zig.parseTargetQueryOrReportFatalError(ar, .{
        .arch_os_abi = "native",
    });
    const native_target = std.zig.resolveTargetQueryOrFatal(target_query);
    const resolved_target: Package.Module.ResolvedTarget = .{
        .result = native_target,
        .is_native_os = target_query.isNativeOs(),
        .is_native_abi = target_query.isNativeAbi(),
        .is_explicit_dynamic_linker = false,
    };

    // Map integer output/optimize modes to enums.
    const output_mode_enum: std.builtin.OutputMode = switch (output_mode_raw) {
        0 => .Exe,
        1 => .Lib,
        2 => .Obj,
        else => .Exe,
    };
    const optimize_mode_enum: std.builtin.OptimizeMode = switch (optimize_mode_raw) {
        0 => .Debug,
        1 => .ReleaseSafe,
        2 => .ReleaseFast,
        3 => .ReleaseSmall,
        else => .ReleaseSafe,
    };

    // Compilation config.
    const config = Compilation.Config.resolve(.{
        .output_mode = output_mode_enum,
        .resolved_target = resolved_target,
        .is_test = false,
        .have_zcu = true,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode_enum,
        .root_strip = true,
        .link_libc = do_link_libc,
        .link_mode = if (output_mode_enum == .Lib and is_dynamic) .dynamic else null,
        .lto = .none,
        .use_llvm = build_options.have_llvm,
    }) catch |err| {
        logErr("Config.resolve failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Root module.
    // Write a stub source file to the cwd. The path uses .none root (cwd-relative)
    // so that module-level imports resolve correctly against the cwd.
    const root_name_z = try ar.dupeZ(u8, root_name_str);
    // Create a subdirectory for the stub source so that the root path (directory)
    // and root_src_path (filename within it) are separate.
    const stub_dir = try std.fmt.allocPrint(ar, ".zap-cache/{s}.zig", .{root_name_str});
    const stub_src_name = try std.fmt.allocPrint(ar, "{s}.zig", .{root_name_str});

    // Builder mode uses a comptime stub since the entry point is custom (not main).
    const stub_source = if (ctx.is_builder)
        "comptime {}\n"
    else if (output_mode_enum == .Exe)
        "pub fn main() void {}\n"
    else
        "comptime {}\n";
    fs.cwd().makePath(stub_dir) catch {};
    const stub_full = try std.fmt.allocPrint(ar, "{s}/{s}", .{ stub_dir, stub_src_name });
    fs.cwd().writeFile(.{
        .sub_path = stub_full,
        .data = stub_source,
    }) catch return error.OutOfMemory;

    // Resolve the path canonically using the Compilation's directory system.
    const root_path = Compilation.Path.fromUnresolved(ar, ctx.dirs, &.{stub_dir}) catch
        return error.OutOfMemory;

    const root_mod = Package.Module.create(ar, .{
        .paths = .{
            .root = root_path,
            .root_src_path = stub_src_name,
        },
        .fully_qualified_name = "root",
        .cc_argv = &.{},
        .inherited = .{ .resolved_target = resolved_target },
        .global = config,
        .parent = null,
    }) catch return error.OutOfMemory;
    ctx.root_mod = root_mod;
    ctx.output_mode = output_mode_enum;

    const output_path_duped = try ar.dupe(u8, output_path);

    // When LLVM is available, the compiler can build compiler_rt itself,
    // but it needs self_exe_path to find the lib/ directory. Use the path
    // of the currently running binary (which statically links everything needed).
    const self_exe_path: ?[]const u8 = if (build_options.have_llvm)
        (std.fs.selfExePathAlloc(ar) catch null)
    else
        null;

    // Set custom entry point for builder mode.
    const entry: Compilation.CreateOptions.Entry = if (ctx.builder_entry_mangled) |name|
        .{ .named = name }
    else
        .default;

    var create_diag: Compilation.CreateDiagnostic = undefined;
    ctx.compilation = Compilation.create(gpa, ar, &create_diag, .{
        .dirs = ctx.dirs,
        .thread_pool = tp,
        .self_exe_path = self_exe_path,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name_z,
        .cache_mode = .none,
        .emit_bin = .{ .yes_path = output_path_duped },
        .skip_linker_dependencies = !build_options.have_llvm,
        .entry = entry,
    }) catch |err| {
        // Log the error for debugging.
        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();
        switch (err) {
            error.CreateFail => stderr.print("zir_api: Compilation.create failed: {f}\n", .{create_diag}) catch {},
            error.OutOfMemory => stderr.print("zir_api: Compilation.create OOM\n", .{}) catch {},
            else => stderr.print("zir_api: Compilation.create error: {s}\n", .{@errorName(err)}) catch {},
        }
        return error.OutOfMemory;
    };

    return ctx;
}

// ---------------------------------------------------------------------------
// Internal: ZIR injection
// ---------------------------------------------------------------------------

fn addZirFromFinalized(ctx: *ZirContext, fzir: zir_builder.FinalizedZir) !void {
    const zir_data = ZirData{
        .instructions_tags = @constCast(fzir.instructions_tags.ptr),
        .instructions_data = @constCast(fzir.instructions_data.ptr),
        .instructions_len = fzir.instructions_len,
        .string_bytes = @constCast(fzir.string_bytes.ptr),
        .string_bytes_len = fzir.string_bytes_len,
        .extra = @constCast(fzir.extra.ptr),
        .extra_len = fzir.extra_len,
    };
    return addZirImpl(ctx, "root", &zir_data);
}

fn addZirImpl(ctx: *ZirContext, name: []const u8, data: *const ZirData) !void {
    _ = name;
    const gpa = ctx.gpa;
    const zcu = ctx.compilation.zcu orelse {
        logErr("addZir: zcu is null", .{});
        return error.OutOfMemory;
    };

    const inst_len: usize = data.instructions_len;

    // Build ZIR instructions using MultiArrayList to get correct internal layout.
    var mal: std.MultiArrayList(Zir.Inst) = .{};
    try mal.ensureTotalCapacity(gpa, inst_len);
    mal.len = inst_len;

    const slice = mal.slice();

    // Copy tag bytes.
    const tag_items = slice.items(.tag);
    @memcpy(
        @as([*]u8, @ptrCast(tag_items.ptr))[0..inst_len],
        data.instructions_tags[0..inst_len],
    );

    // Copy data bytes. Each Data element occupies @sizeOf(Zir.Inst.Data) bytes.
    const data_items = slice.items(.data);
    const data_byte_len = inst_len * @sizeOf(Zir.Inst.Data);
    @memcpy(
        @as([*]u8, @ptrCast(data_items.ptr))[0..data_byte_len],
        data.instructions_data[0..data_byte_len],
    );

    // Copy string_bytes and extra (these are simple flat arrays).
    const string_bytes = try gpa.dupe(u8, data.string_bytes[0..data.string_bytes_len]);
    errdefer gpa.free(string_bytes);

    const extra = try gpa.dupe(u32, data.extra[0..data.extra_len]);
    errdefer gpa.free(extra);

    // Assemble the Zir struct. The slice owns the MultiArrayList's backing memory.
    const zir: Zir = .{
        .instructions = slice,
        .string_bytes = string_bytes,
        .extra = extra,
    };

    // Find the root file and inject the ZIR.
    const root_file_opt = zcu.module_roots.get(ctx.root_mod) orelse
        return error.OutOfMemory;
    const file_index = root_file_opt.unwrap() orelse
        return error.OutOfMemory;
    const file = zcu.fileByIndex(file_index);

    // Parse the stub source so that error reporting has a valid AST tree.
    // Without this, SrcLoc.span crashes when Sema tries to format errors.
    if (file.source == null) {
        const stub_source = if (ctx.output_mode == .Exe) "pub fn main() void {}\n" else "comptime {}\n";
        const source = try gpa.allocSentinel(u8, stub_source.len, 0);
        @memcpy(source, stub_source);
        file.source = source;
        file.tree = try std.zig.Ast.parse(gpa, source, .zig);
    }

    // Free any previous ZIR.
    if (file.zir) |*old_zir| old_zir.deinit(gpa);

    // Inject the pre-built ZIR.
    file.zir = zir;
    file.status = .success;

    // Mark as ZIR-injected so the pipeline skips AstGen for this file.
    file.zir_injected = true;

    // Ensure the file has its module set (needed by doImport for @import resolution).
    if (file.mod == null) {
        file.mod = ctx.root_mod;
    }
}

// ---------------------------------------------------------------------------
// C-ABI exports: ZIR Builder
// ---------------------------------------------------------------------------

/// Opaque handle type for the ZIR builder, used across the C ABI boundary.
pub const ZirBuilderHandle = opaque {};

/// Recover a `*zir_builder.Builder` from an opaque handle.
fn getBuilder(handle: ?*ZirBuilderHandle) ?*zir_builder.Builder {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

/// Create a new ZIR builder. Returns null on failure.
pub export fn zir_builder_create() callconv(.c) ?*ZirBuilderHandle {
    const gpa = std.heap.page_allocator;
    const b = gpa.create(zir_builder.Builder) catch return null;
    b.* = zir_builder.Builder.init(gpa) catch {
        gpa.destroy(b);
        return null;
    };
    return @ptrCast(b);
}

/// Destroy a ZIR builder and free all resources.
pub export fn zir_builder_destroy(handle: ?*ZirBuilderHandle) callconv(.c) void {
    const b = getBuilder(handle) orelse return;
    b.deinit();
    std.heap.page_allocator.destroy(b);
}

/// Begin a function declaration.
/// `name_ptr` + `name_len` specify the function name.
/// `ret_type` is 0 for void, or a `Zir.Inst.Ref` value for the return type
/// (e.g. `@intFromEnum(Zir.Inst.Ref.i64_type)`).
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_begin_func(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    ret_type: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const name = name_ptr[0..name_len];
    const rt: zir_builder.ReturnType = @enumFromInt(ret_type);
    _ = b.beginFunction(name, rt) catch return -1;
    return 0;
}

/// End the current function declaration.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_end_func(handle: ?*ZirBuilderHandle) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    b.endFunction(body) catch return -1;
    return 0;
}

/// Emit a function parameter declaration.
/// `name_ptr` + `name_len` specify the parameter name.
/// `type_ref` is a `Zir.Inst.Ref` value for the parameter type
/// (e.g. `@intFromEnum(Zir.Inst.Ref.i64_type)`), or 0 for anytype.
/// Returns `@intFromEnum(Ref)` to the param instruction, or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_param(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const tr: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addParam(name_ptr[0..name_len], tr) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an integer literal. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, value: i64) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addInt(value) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a float literal. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_float(handle: ?*ZirBuilderHandle, value: f64) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addFloat(value) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a string literal. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_str(
    handle: ?*ZirBuilderHandle,
    ptr: [*]const u8,
    len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addStr(ptr[0..len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a boolean literal. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bool(handle: ?*ZirBuilderHandle, value: bool) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    if (value) {
        return @intFromEnum(body.addBoolTrue());
    } else {
        return @intFromEnum(body.addBoolFalse());
    }
}

/// Emit a void value. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_void(handle: ?*ZirBuilderHandle) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    return @intFromEnum(body.addVoidValue());
}

/// Emit an enum literal. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_enum_literal(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addEnumLiteral(name_ptr[0..name_len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a binary operation.
/// `tag` is the `u8` value of `Zir.Inst.Tag` (e.g. add, sub, mul, ...).
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_binop(
    handle: ?*ZirBuilderHandle,
    tag: u8,
    lhs: u32,
    rhs: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const zig_tag: Zir.Inst.Tag = @enumFromInt(tag);
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addBinOp(zig_tag, lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit arithmetic negation. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_negate(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addNegate(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit boolean NOT. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bool_not(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addBoolNot(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@as(dest_type, operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_as(
    handle: ?*ZirBuilderHandle,
    dest_type: u32,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const dest_type_ref: Zir.Inst.Ref = @enumFromInt(dest_type);
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addAs(dest_type_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@ptrCast(dest_type, operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_ptr_cast(
    handle: ?*ZirBuilderHandle,
    dest_type: u32,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const dest_type_ref: Zir.Inst.Ref = @enumFromInt(dest_type);
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addPtrCast(dest_type_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a full pointer cast such as `@alignCast(dest_type, operand)`.
/// `flags_bits` is the packed `u5` representation of `Zir.Inst.FullPtrCastFlags`.
pub export fn zir_builder_emit_ptr_cast_full(
    handle: ?*ZirBuilderHandle,
    flags_bits: u8,
    dest_type: u32,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const dest_type_ref: Zir.Inst.Ref = @enumFromInt(dest_type);
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(flags_bits)));
    const ref = body.addFullPtrCast(flags, dest_type_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a function call by name.
/// `args_ptr` points to an array of `u32` Ref values, `args_len` is the count.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_call(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    args_ptr: [*]const u32,
    args_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;

    // Convert u32 args to Zir.Inst.Ref slice using stack buffer or heap.
    const gpa = b.gpa;
    const refs = gpa.alloc(Zir.Inst.Ref, args_len) catch return 0xFFFFFFFF;
    defer gpa.free(refs);
    for (0..args_len) |i| {
        refs[i] = @enumFromInt(args_ptr[i]);
    }

    const ref = body.addCall(name_ptr[0..name_len], refs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an explicit return with a value.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_ret(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    body.addRetNode(operand_ref) catch return -1;
    return 0;
}

/// Emit an implicit void return.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_ret_void(handle: ?*ZirBuilderHandle) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.addRetImplicit() catch return -1;
    return 0;
}

/// Emit `@import("module_name")`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_import(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addImport(name_ptr[0..name_len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit field access (a.b syntax). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_field_val(
    handle: ?*ZirBuilderHandle,
    object: u32,
    field_ptr: [*]const u8,
    field_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const object_ref: Zir.Inst.Ref = @enumFromInt(object);
    const ref = body.addFieldVal(object_ref, field_ptr[0..field_len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit field pointer access (get pointer to a.b). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_field_ptr(
    handle: ?*ZirBuilderHandle,
    object: u32,
    field_ptr_arg: [*]const u8,
    field_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const object_ref: Zir.Inst.Ref = @enumFromInt(object);
    const ref = body.addFieldPtr(object_ref, field_ptr_arg[0..field_len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a store through a pointer. Stores value into the location pointed to by ptr_ref.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_store(
    handle: ?*ZirBuilderHandle,
    ptr_ref: u32,
    value_ref: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const ptr: Zir.Inst.Ref = @enumFromInt(ptr_ref);
    const value: Zir.Inst.Ref = @enumFromInt(value_ref);
    body.addStore(ptr, value) catch return -1;
    return 0;
}

/// Emit is_non_null check on an optional. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_is_non_null(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addIsNonNull(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit optional payload extraction with safety. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_optional_payload(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addOptionalPayloadSafe(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an anonymous struct initialization.
/// `names_ptr` is a packed array of (ptr, len) pairs for field names.
/// `values_ptr` is an array of u32 Ref values.
/// `fields_len` is the number of fields.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_struct_init_anon(
    handle: ?*ZirBuilderHandle,
    names_ptrs: [*]const [*]const u8,
    names_lens: [*]const u32,
    values_ptr: [*]const u32,
    fields_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    // Convert C arrays to Zig slices
    const names = gpa.alloc([]const u8, fields_len) catch return 0xFFFFFFFF;
    defer gpa.free(names);
    for (0..fields_len) |i| {
        names[i] = names_ptrs[i][0..names_lens[i]];
    }

    const refs = gpa.alloc(Zir.Inst.Ref, fields_len) catch return 0xFFFFFFFF;
    defer gpa.free(refs);
    for (0..fields_len) |i| {
        refs[i] = @enumFromInt(values_ptr[i]);
    }

    const ref = body.addStructInitAnon(names, refs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Begin a switch_block on a tagged union value. Returns the instruction index
/// and a payload Ref. Body instructions that reference the payload Ref will
/// receive the captured union payload at runtime.
/// Returns packed: lower 32 bits = inst_idx, upper 32 bits = payload_ref.
/// Returns 0xFFFFFFFFFFFFFFFF on error.
pub export fn zir_builder_begin_switch_block(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u64 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFFFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFFFFFFFFFF;
    const result = body.beginSwitchBlock(@enumFromInt(operand)) catch return 0xFFFFFFFFFFFFFFFF;
    const lo: u64 = result.inst_idx;
    const hi: u64 = @as(u64, @intFromEnum(result.payload_ref)) << 32;
    return lo | hi;
}

/// Finalize a switch_block with prong data. Each prong has:
/// - item: u32 Ref (enum literal)
/// - has_capture: bool (1 or 0)
/// - body_insts_ptr + body_insts_len: instruction indices for the body
/// - body_result: u32 Ref (the result value)
///
/// Prongs are packed as: [item, has_capture, body_insts_len, body_result, body_inst_0, body_inst_1, ...]
/// `prong_data_ptr` points to this packed array, `prong_data_len` is total u32 count.
/// `num_prongs` is the number of prongs.
/// Returns the switch result Ref or 0xFFFFFFFF on error.
pub export fn zir_builder_finalize_switch_block(
    handle: ?*ZirBuilderHandle,
    inst_idx: u32,
    operand: u32,
    prong_data_ptr: [*]const u32,
    prong_data_len: u32,
    num_prongs: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    // Parse packed prong data
    const ZirBuilder = @import("zir_builder.zig");
    const prongs = gpa.alloc(ZirBuilder.FuncBody.SwitchProng, num_prongs) catch return 0xFFFFFFFF;
    defer gpa.free(prongs);

    var offset: u32 = 0;
    for (0..num_prongs) |i| {
        if (offset + 4 > prong_data_len) return 0xFFFFFFFF;
        const item: Zir.Inst.Ref = @enumFromInt(prong_data_ptr[offset]);
        const has_capture = prong_data_ptr[offset + 1] != 0;
        const body_insts_len = prong_data_ptr[offset + 2];
        const body_result: Zir.Inst.Ref = @enumFromInt(prong_data_ptr[offset + 3]);
        offset += 4;

        if (offset + body_insts_len > prong_data_len) return 0xFFFFFFFF;
        const body_insts = prong_data_ptr[offset .. offset + body_insts_len];
        offset += body_insts_len;

        prongs[i] = .{
            .item = item,
            .has_capture = has_capture,
            .body_insts = body_insts,
            .body_result = body_result,
        };
    }

    const ref = body.finalizeSwitchBlock(inst_idx, @enumFromInt(operand), prongs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a union initialization: @unionInit(union_type, field_name, init_value).
/// `union_type` is a Ref to the union type, `field_name_ptr`/`field_name_len`
/// specify the variant name (will be interned as an enum_literal),
/// `init_value` is the payload value Ref.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_union_init(
    handle: ?*ZirBuilderHandle,
    union_type: u32,
    field_name_ptr: [*]const u8,
    field_name_len: u32,
    init_value: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;

    const union_type_ref: Zir.Inst.Ref = @enumFromInt(union_type);
    const init_value_ref: Zir.Inst.Ref = @enumFromInt(init_value);

    // Create an enum_literal for the field name
    const field_name = field_name_ptr[0..field_name_len];
    const field_name_ref = body.addEnumLiteral(field_name) catch return 0xFFFFFFFF;

    const ref = body.addUnionInit(union_type_ref, field_name_ref, init_value_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a function call using a Ref as the callee (e.g. from @import + field access).
/// `args_ptr` points to an array of `u32` Ref values, `args_len` is the count.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_call_ref(
    handle: ?*ZirBuilderHandle,
    callee: u32,
    args_ptr: [*]const u32,
    args_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const callee_ref: Zir.Inst.Ref = @enumFromInt(callee);

    const refs = gpa.alloc(Zir.Inst.Ref, args_len) catch return 0xFFFFFFFF;
    defer gpa.free(refs);
    for (0..args_len) |i| {
        refs[i] = @enumFromInt(args_ptr[i]);
    }

    const ref = body.addCallRef(callee_ref, refs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit element access by immediate index (tuple/array indexing).
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_elem_val_imm(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    index: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addElemValImm(operand_ref, index) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit @typeInfo(operand). Returns the type info value.
pub export fn zir_builder_emit_type_info(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addTypeInfo(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an anonymous array initialization (creates a tuple type).
/// `values_ptr` points to an array of `u32` Ref values, `values_len` is the count.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_array_init_anon(
    handle: ?*ZirBuilderHandle,
    values_ptr: [*]const u32,
    values_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const refs = gpa.alloc(Zir.Inst.Ref, values_len) catch return 0xFFFFFFFF;
    defer gpa.free(refs);
    for (0..values_len) |i| {
        refs[i] = @enumFromInt(values_ptr[i]);
    }

    const ref = body.addArrayInitAnon(refs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Mark a value as used (prevents "result not used" compile error).
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_ensure_result_used(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    body.addEnsureResultUsed(operand_ref) catch return -1;
    return 0;
}

/// Emit a debug statement with line/column info.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_dbg_stmt(
    handle: ?*ZirBuilderHandle,
    line: u32,
    column: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.addDbgStmt(line, column) catch return -1;
    return 0;
}

/// Emit @TypeOf(operand). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_typeof(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addTypeOf(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an if-then-else expression.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_if_else(
    handle: ?*ZirBuilderHandle,
    condition: u32,
    then_value: u32,
    else_value: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const cond_ref: Zir.Inst.Ref = @enumFromInt(condition);
    const then_ref: Zir.Inst.Ref = @enumFromInt(then_value);
    const else_ref: Zir.Inst.Ref = @enumFromInt(else_value);
    const ref = body.addIfElse(cond_ref, then_ref, else_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Enable or disable body tracking for the active function body.
/// When disabled, emitted instructions are NOT added to the function's
/// body_inst_indices — they exist in the instruction array but are only
/// reachable from sub-body payloads (e.g. condbr_inline branches).
pub export fn zir_builder_set_body_tracking(
    handle: ?*ZirBuilderHandle,
    enabled: bool,
) callconv(.c) void {
    const b = getBuilder(handle) orelse return;
    const body = b.active_body orelse return;
    body.body_tracking = enabled;
}

/// Return the current instruction count in the builder.
/// Used to track instruction index ranges when body tracking is off.
pub export fn zir_builder_get_inst_count(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    return body.getInstCount();
}

/// Thread-local capture buffer used by begin_capture / end_capture.
/// Only one capture session at a time per builder.
var capture_buf: std.ArrayListUnmanaged(u32) = .{};

/// Begin capturing would-be-body instruction indices. Disables body tracking
/// and directs top-level instruction indices into an internal capture buffer.
/// Call `zir_builder_end_capture` to retrieve the collected indices and
/// re-enable body tracking.
pub export fn zir_builder_begin_capture(
    handle: ?*ZirBuilderHandle,
) callconv(.c) void {
    const b = getBuilder(handle) orelse return;
    const body = b.active_body orelse return;
    capture_buf.clearRetainingCapacity();
    body.body_tracking = false;
    body.non_body_capture = &capture_buf;
}

/// End capture mode: re-enables body tracking and returns a pointer to the
/// captured instruction indices. The returned pointer is valid until the
/// next call to `zir_builder_begin_capture`.
/// `out_len` receives the number of captured indices.
pub export fn zir_builder_end_capture(
    handle: ?*ZirBuilderHandle,
    out_len: *u32,
) callconv(.c) [*]const u32 {
    const b = getBuilder(handle) orelse {
        out_len.* = 0;
        return @as([*]const u32, @ptrCast(&capture_buf.items));
    };
    const body = b.active_body orelse {
        out_len.* = 0;
        return @as([*]const u32, @ptrCast(&capture_buf.items));
    };
    body.body_tracking = true;
    body.non_body_capture = null;
    out_len.* = @intCast(capture_buf.items.len);
    return capture_buf.items.ptr;
}

/// Emit an if-then-else with full branch instruction bodies.
/// `then_insts_ptr`/`then_insts_len` specify raw instruction indices for the
/// then branch (emitted with body tracking off). `else_insts_ptr`/`else_insts_len`
/// do the same for the else branch. Only the taken branch's instructions are
/// analyzed by Sema.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_if_else_bodies(
    handle: ?*ZirBuilderHandle,
    condition: u32,
    then_insts_ptr: [*]const u32,
    then_insts_len: u32,
    then_result: u32,
    else_insts_ptr: [*]const u32,
    else_insts_len: u32,
    else_result: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const cond_ref: Zir.Inst.Ref = @enumFromInt(condition);
    const then_ref: Zir.Inst.Ref = @enumFromInt(then_result);
    const else_ref: Zir.Inst.Ref = @enumFromInt(else_result);
    const ref = body.addIfElseWithBodies(
        cond_ref,
        then_insts_ptr[0..then_insts_len],
        then_ref,
        else_insts_ptr[0..else_insts_len],
        else_ref,
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Pop the last instruction index from body_inst_indices and return it.
/// Used when chaining nested if-else blocks: the inner block_inline must
/// be removed from the function body and placed inside the outer condbr's
/// else branch instead.
/// Returns the popped instruction index, or 0xFFFFFFFF if body is empty.
pub export fn zir_builder_pop_body_inst(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    if (body.body_inst_indices.items.len == 0) return 0xFFFFFFFF;
    const idx = body.body_inst_indices.items[body.body_inst_indices.items.len - 1];
    body.body_inst_indices.items.len -= 1;
    return idx;
}

/// Emit `try operand` — unwrap an error union, panicking on error.
/// Returns `@intFromEnum(Ref)` to the unwrapped payload, or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_try(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addTry(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a struct_init for a known struct type (e.g., tuple return).
/// `struct_type` is a Ref to the target struct type.
/// `field_names_ptrs`/`field_names_lens` specify field names.
/// `values_ptr` contains the init value Refs.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_struct_init_typed(
    handle: ?*ZirBuilderHandle,
    struct_type: u32,
    field_names_ptrs: [*]const [*]const u8,
    field_names_lens: [*]const u32,
    values_ptr: [*]const u32,
    fields_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const struct_type_ref: Zir.Inst.Ref = @enumFromInt(struct_type);

    const names = gpa.alloc([]const u8, fields_len) catch return 0xFFFFFFFF;
    defer gpa.free(names);
    for (0..fields_len) |i| {
        names[i] = field_names_ptrs[i][0..field_names_lens[i]];
    }

    const refs = gpa.alloc(Zir.Inst.Ref, fields_len) catch return 0xFFFFFFFF;
    defer gpa.free(refs);
    for (0..fields_len) |i| {
        refs[i] = @enumFromInt(values_ptr[i]);
    }

    const ref = body.addStructInitTyped(struct_type_ref, names, refs) catch return 0xFFFFFFFF;

    // Don't clear here — nested tuples check element count to decide.

    return @intFromEnum(ref);
}

/// Emit a tuple_decl instruction (as a param-like instruction in the declaration body)
/// and return its Ref. Used to build nested tuple types.
pub export fn zir_builder_emit_tuple_decl(
    handle: ?*ZirBuilderHandle,
    types_ptr: [*]const u32,
    types_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const fields_len: u16 = @intCast(types_len);
    const tuple_payload_idx: u32 = @intCast(b.extra.items.len);
    b.extra.append(gpa, 0) catch return 0xFFFFFFFF; // src_node
    for (0..types_len) |i| {
        b.extra.append(gpa, types_ptr[i]) catch return 0xFFFFFFFF; // field type
        b.extra.append(gpa, @intFromEnum(Zir.Inst.Ref.none)) catch return 0xFFFFFFFF; // no init
    }
    const idx = b.addInst(
        .extended,
        zir_builder.Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.tuple_decl), fields_len, tuple_payload_idx),
    ) catch return 0xFFFFFFFF;

    // Track as a param instruction so it's in the declaration value body
    body.param_inst_indices.append(gpa, idx) catch return 0xFFFFFFFF;

    return @intFromEnum(zir_builder.Builder.instRef(idx));
}

/// Emit a tuple_decl as a function BODY instruction and return its Ref.
/// Used to create body-local tuple types for nested struct_init_typed.
pub export fn zir_builder_emit_tuple_decl_body(
    handle: ?*ZirBuilderHandle,
    types_ptr: [*]const u32,
    types_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const fields_len: u16 = @intCast(types_len);
    const tuple_payload_idx: u32 = @intCast(b.extra.items.len);
    b.extra.append(gpa, 0) catch return 0xFFFFFFFF;
    for (0..types_len) |i| {
        b.extra.append(gpa, types_ptr[i]) catch return 0xFFFFFFFF;
        b.extra.append(gpa, @intFromEnum(Zir.Inst.Ref.none)) catch return 0xFFFFFFFF;
    }
    const ref = body.emitBodyInst(
        .extended,
        zir_builder.Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.tuple_decl), fields_len, tuple_payload_idx),
    ) catch return 0xFFFFFFFF;

    return @intFromEnum(ref);
}

/// Get the tuple return type Ref and element count for the current function.
/// Returns 0 if not a tuple-returning function.
/// `out_elem_count` receives the number of elements in the tuple type.
pub export fn zir_builder_get_tuple_return_type(handle: ?*ZirBuilderHandle) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    if (body.tuple_ret_types.items.len > 0 and body.tuple_element_type_refs.items.len > 0) {
        return @intFromEnum(body.tuple_ret_types.items[0]);
    }
    return 0;
}

/// Get the number of elements in the tuple return type, or 0.
pub export fn zir_builder_get_tuple_return_type_len(handle: ?*ZirBuilderHandle) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    return @intCast(body.tuple_element_type_refs.items.len);
}

/// Set a tuple return type for the current function from an array of element type Refs.
/// Each element in `types_ptr` is a u32 Ref value (e.g., @intFromEnum(Zir.Inst.Ref.i64_type)).
/// Must be called after begin_func and before end_func.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_tuple_return_type(
    handle: ?*ZirBuilderHandle,
    types_ptr: [*]const u32,
    types_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const gpa = b.gpa;

    const refs = gpa.alloc(Zir.Inst.Ref, types_len) catch return -1;
    defer gpa.free(refs);
    for (0..types_len) |i| {
        refs[i] = @enumFromInt(types_ptr[i]);
    }

    body.setTupleReturnType(refs) catch return -1;
    return 0;
}

/// Set the current function's return type to a tagged union(enum).
/// `names_ptrs`/`names_lens` are the variant names, `types_ptr` are the variant
/// type Refs (use 0 for void/unit variants).
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_union_return_type(
    handle: ?*ZirBuilderHandle,
    names_ptrs: [*]const [*]const u8,
    names_lens: [*]const u32,
    types_ptr: [*]const u32,
    fields_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const gpa = b.gpa;

    const names = gpa.alloc([]const u8, fields_len) catch return -1;
    defer gpa.free(names);
    for (0..fields_len) |i| {
        names[i] = names_ptrs[i][0..names_lens[i]];
    }

    const refs = gpa.alloc(Zir.Inst.Ref, fields_len) catch return -1;
    defer gpa.free(refs);
    for (0..fields_len) |i| {
        refs[i] = @enumFromInt(types_ptr[i]);
    }

    body.setUnionReturnType(names, refs) catch return -1;
    return 0;
}

/// Finalize the builder and inject its ZIR into a compilation context.
/// After this call the builder is consumed; the handle must not be reused
/// (call `zir_builder_destroy` is not needed — resources are freed here).
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_inject(
    builder_handle: ?*ZirBuilderHandle,
    compilation_handle: ?*ZirContext,
) callconv(.c) i32 {
    const b = getBuilder(builder_handle) orelse return -1;
    const ctx = compilation_handle orelse return -1;

    const fzir = b.finalize() catch return -1;
    addZirFromFinalized(ctx, fzir) catch return -1;

    // Clean up the builder — it has been consumed.
    b.deinit();
    std.heap.page_allocator.destroy(b);

    return 0;
}

fn testRepoLibDir(allocator: Allocator) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, "lib") catch |err| switch (err) {
        error.FileNotFound => blk: {
            const src_dir = std.fs.path.dirname(@src().file) orelse break :blk error.FileNotFound;
            const lib_path = try std.fs.path.join(allocator, &.{ src_dir, "..", "lib" });
            defer allocator.free(lib_path);
            break :blk std.fs.cwd().realpathAlloc(allocator, lib_path);
        },
        else => err,
    };
}

fn testExpectSegmentVmaddrOrder(file_path: []const u8, allocator: Allocator) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(bytes.len >= @sizeOf(std.macho.mach_header_64));

    const header: *align(1) const std.macho.mach_header_64 = @ptrCast(bytes.ptr);
    try std.testing.expectEqual(std.macho.MH_MAGIC_64, header.magic);

    var offset: usize = @sizeOf(std.macho.mach_header_64);
    var last_vmaddr: u64 = 0;

    for (0..header.ncmds) |_| {
        try std.testing.expect(offset + @sizeOf(std.macho.load_command) <= bytes.len);
        const lc: *align(1) const std.macho.load_command = @ptrCast(bytes.ptr + offset);
        try std.testing.expect(offset + lc.cmdsize <= bytes.len);

        if (lc.cmd == .SEGMENT_64) {
            const seg: *align(1) const std.macho.segment_command_64 = @ptrCast(bytes.ptr + offset);
            try std.testing.expect(seg.vmaddr >= last_vmaddr);
            last_vmaddr = seg.vmaddr;
        }

        offset += lc.cmdsize;
    }
}

test "zir_api: injected executable update succeeds" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("local-cache");
    try tmp.dir.makePath("global-cache");

    const zig_lib_dir = try testRepoLibDir(allocator);
    defer allocator.free(zig_lib_dir);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(original_cwd) catch {};

    const local_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "local-cache" });
    defer allocator.free(local_cache_dir);
    const global_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "global-cache" });
    defer allocator.free(global_cache_dir);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "repro-bin" });
    defer allocator.free(output_path);

    const ctx = try createImpl(
        zig_lib_dir,
        local_cache_dir,
        global_cache_dir,
        output_path,
        "zir_api_oom_repro",
        0,
        1,
        false,
        true,
    );
    defer zir_compilation_destroy(ctx);

    try addModuleSourceImpl(ctx, "zap_runtime", "pub fn noop() void {}\n");

    var builder = try zir_builder.Builder.init(allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("main", .void);
    try builder.endFunction(body);

    const fzir = try builder.finalize();
    try addZirFromFinalized(ctx, fzir);

    try std.testing.expectEqual(@as(i32, 0), zir_compilation_update(ctx));

    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    try testExpectSegmentVmaddrOrder(output_path, allocator);
}
