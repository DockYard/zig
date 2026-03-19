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
    var error_bundle = ctx.compilation.getAllErrorsAlloc() catch return;
    defer error_bundle.deinit(ctx.gpa);
    if (error_bundle.errorMessageCount() == 0) return;

    const stderr = std.debug.lockStderrWriter(&.{});
    defer std.debug.unlockStderrWriter();
    error_bundle.renderToWriter(.{
        .ttyconf = .no_color,
        .include_source_line = false,
        .include_reference_trace = false,
    }, stderr) catch {};
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
        .root_optimize_mode = .Debug,
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
    const stub_filename = try std.fmt.allocPrint(ar, ".zap-cache/{s}.zig", .{root_name_str});

    const stub_source = "pub fn main() void {}\n";
    fs.cwd().makePath(".zap-cache") catch {};
    fs.cwd().writeFile(.{
        .sub_path = stub_filename,
        .data = stub_source,
    }) catch return error.OutOfMemory;

    // Resolve the path canonically using the Compilation's directory system.
    const root_path = Compilation.Path.fromUnresolved(ar, ctx.dirs, &.{stub_filename}) catch
        return error.OutOfMemory;

    const root_mod = Package.Module.create(ar, .{
        .paths = .{
            .root = root_path,
            .root_src_path = std.fs.path.basename(stub_filename),
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

    // Free any previous ZIR.
    if (file.zir) |*old_zir| old_zir.deinit(gpa);

    // Inject the pre-built ZIR.
    file.zir = zir;
    file.status = .success;

    // Mark as ZIR-injected so the pipeline skips AstGen for this file.
    file.zir_injected = true;
}
