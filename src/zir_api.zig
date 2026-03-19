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
) ?*ZirContext {
    return createImpl(
        mem.sliceTo(zig_lib_dir, 0),
        mem.sliceTo(local_cache_dir, 0),
        mem.sliceTo(global_cache_dir, 0),
        mem.sliceTo(output_path, 0),
        mem.sliceTo(root_name, 0),
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
    ctx.compilation.update(.none) catch |err| {
        logErr("update failed: {s}", .{@errorName(err)});
        return -1;
    };
    if (ctx.compilation.anyErrors()) return -1;
    return 0;
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
        logErr("addModule: file already exists in import table", .{});
    } else {
        logErr("addModule: creating new file entry", .{});
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

    logErr("addModule: registered '{s}' from '{s}' (deps count: {d}, roots: {d})", .{
        name, source_path, ctx.root_mod.deps.count(), zcu.module_roots.count(),
    });
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
) !*ZirContext {
    const gpa = std.heap.page_allocator;

    const ctx = gpa.create(ZirContext) catch {
        logErr("failed to allocate ZirContext", .{});
        return error.OutOfMemory;
    };
    errdefer gpa.destroy(ctx);
    ctx.gpa = gpa;
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
    tp.init(.{ .allocator = gpa, .n_jobs = 1, .track_ids = true }) catch {
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

    // Compilation config.
    const config = Compilation.Config.resolve(.{
        .output_mode = .Exe,
        .resolved_target = resolved_target,
        .is_test = false,
        .have_zcu = true,
        .emit_bin = true,
        .root_optimize_mode = .ReleaseFast, // TODO: make configurable; Debug triggers safety checks that need proper source locations
        .root_strip = false,
        .link_libc = true,
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

    const stub_source = "pub fn main() void {}\n";
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

    const output_path_duped = try ar.dupe(u8, output_path);

    // When LLVM is available, the compiler can build compiler_rt itself,
    // but it needs self_exe_path to find the lib/ directory. Use the path
    // of the currently running binary (which statically links everything needed).
    const self_exe_path: ?[]const u8 = if (build_options.have_llvm)
        (std.fs.selfExePathAlloc(ar) catch null)
    else
        null;

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
        const stub_source = "pub fn main() void {}\n";
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
