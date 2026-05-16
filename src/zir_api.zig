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
const Io = std.Io;
const Dir = Io.Dir;
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
    /// Zig 0.16 I/O interface (replaces thread pool).
    io_impl: Io.Threaded,
    dirs: Compilation.Directories,
    compilation: *Compilation,
    root_mod: *Package.Module,
    output_mode: std.builtin.OutputMode = .Exe,
    /// Builder mode: the compiled binary is a build system builder.
    is_builder: bool = false,
    /// The entry point function name for builder mode (e.g., "manifest").
    builder_entry: ?[]const u8 = null,
    /// The struct-qualified entry point (e.g., "FooBar__Builder__manifest").
    builder_entry_mangled: ?[]const u8 = null,

    pub fn arena(self: *ZirContext) Allocator {
        return self.arena_state.allocator();
    }

    pub fn io(self: *ZirContext) Io {
        return self.io_impl.io();
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
        null,
        null,
    ) catch null;
}

/// Create a new compilation context with an explicit target triple
/// and optional CPU model/feature set.
///
/// `target_triple` is a null-terminated target string (e.g., "wasm32-wasi",
/// "aarch64-linux-gnu"). Pass null or "native" for native compilation.
/// `cpu_features` is a null-terminated CPU string (e.g., "baseline",
/// "apple_m1", "x86_64_v3", "<model>+feat-feat") mirroring `zig build`'s
/// `-Dcpu=`. Pass null or "" for the target's default CPU. Returns null
/// on failure.
pub export fn zir_compilation_create_cross(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    target_triple: ?[*:0]const u8,
    cpu_features: ?[*:0]const u8,
) ?*ZirContext {
    const target_str: ?[]const u8 = if (target_triple) |t| mem.sliceTo(t, 0) else null;
    const cpu_str: ?[]const u8 = if (cpu_features) |c| mem.sliceTo(c, 0) else null;
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
        target_str,
        cpu_str,
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
    // `std.Progress` is process-global: `Progress.start` asserts that
    // `node_end_index == 0` and the matching `prog_node.end()` does NOT
    // reset that counter back to zero. Multiple compiles in the same
    // process (e.g., the manager-object compile via
    // `compileToObjectImpl` followed by the user-code compile here)
    // would therefore trip the `unreachable` inside `Progress.start`
    // on the second call.
    //
    // We side-step the singleton entirely by passing `Progress.Node.none`
    // directly. The library's host (Zap's CLI) already prints its own
    // progress via stderr; the internal compiler progress bar would
    // overwrite that output anyway.
    const prog_node: std.Progress.Node = .none;
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
            var stderr_buf2: [256]u8 = undefined;
            const stderr_locked2 = std.debug.lockStderr(&stderr_buf2);
            defer std.debug.unlockStderr();
            error_bundle.renderToWriter(.{
                .include_source_line = false,
                .include_reference_trace = false,
            }, &stderr_locked2.file_writer.interface) catch |render_err| {
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

    // Post-link artifact verification (mirrors the object-compile
    // primitive). `update()` returning cleanly and `anyErrors()` being
    // false does not by itself prove the binary was written: a linker
    // flush can complete "successfully" yet emit nothing if the link
    // step could not actually run (historically: the LLD relocatable
    // step re-spawning the embedder as `<self_exe> ld.lld ...`).
    // `internal_tools_in_process` fixes the known cause, but this primitive must
    // NEVER report success without the artifact, regardless of linker
    // path or target class.
    if (ctx.compilation.bin_file) |lf| {
        const io = ctx.io();
        const st = lf.emit.root_dir.handle.statFile(io, lf.emit.sub_path, .{}) catch |stat_err| {
            logErr(
                "zap_fork: compilation reported success but produced no output binary at '{s}' ({s}); the requested target may require a linker toolchain this build cannot provide",
                .{ lf.emit.sub_path, @errorName(stat_err) },
            );
            return -1;
        };
        if (st.size == 0) {
            logErr(
                "zap_fork: compilation reported success but produced an empty output binary at '{s}'",
                .{lf.emit.sub_path},
            );
            return -1;
        }
    }
    return 0;
}

fn dumpErrorBundle(eb: std.zig.ErrorBundle) void {
    var buf: [256]u8 = undefined;
    const locked = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const w = &locked.file_writer.interface;
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
    var stderr_buf: [256]u8 = undefined;
    const stderr_locked = std.debug.lockStderr(&stderr_buf);
    defer std.debug.unlockStderr();
    const stderr = &stderr_locked.file_writer.interface;
    error_bundle.renderToWriter(.{
        .include_source_line = false,
        .include_reference_trace = false,
    }, stderr) catch {};
}

/// Add a named struct dependency so the root can @import it.
/// `name` is the import name (e.g., "zap_runtime").
/// `source_path` is the full path to the .zig source file.
/// Returns 0 on success, -1 on error.
pub export fn zir_compilation_add_struct(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_path: [*:0]const u8,
) callconv(.c) i32 {
    addStructImpl(ctx, mem.sliceTo(name, 0), mem.sliceTo(source_path, 0)) catch return -1;
    return 0;
}

/// Register a Zap struct from an in-memory source buffer instead of a file path.
/// The source is written to a file in the compilation's cache directory,
/// then registered as a dependency of the root.
/// `name` is the import name (null-terminated C string).
/// `source_ptr`/`source_len` is the Zig source code.
/// Returns 0 on success, -1 on error.
pub export fn zir_compilation_add_struct_source(
    ctx: ?*ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) callconv(.c) i32 {
    const c = ctx orelse return -1;
    addStructSourceImpl(c, mem.sliceTo(name, 0), source_ptr[0..source_len]) catch return -1;
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

/// Append an object file to the compilation's link inputs.
///
/// Used by Zap's memory-manager driver (Memory Manager ABI v1.0,
/// `docs/memory-manager-abi.md` section 10) to splice a separately-compiled
/// manager `.o` into the final binary's link line. The caller has already
/// produced the object via `zap_fork_compile_zig_to_object` and parsed and
/// validated the resulting `.zapmem` section; this entry point only
/// performs the link-time mechanical step.
///
/// Returns 0 on success and a negative error code on failure:
///   * `-1` — general failure (allocation, internal error, etc.).
///   * `-2` — filesystem error opening either the object file or its
///     parent directory. Distinguishing this from `-1` lets the Zap-side
///     driver surface a useful diagnostic ("object not readable") instead
///     of falling back to a generic OOM message.
///
/// Must be invoked AFTER `zir_compilation_create*` and BEFORE
/// `zir_compilation_update`.
pub export fn zir_compilation_add_link_object_file(
    ctx: ?*ZirContext,
    path: [*:0]const u8,
) callconv(.c) i32 {
    const c = ctx orelse return -1;
    addLinkObjectFileImpl(c, mem.sliceTo(path, 0)) catch |err| switch (err) {
        error.LinkObjectFileNotReadable => return -2,
        else => return -1,
    };
    return 0;
}

/// Destroy the compilation context and free all resources.
pub export fn zir_compilation_destroy(ctx: *ZirContext) void {
    const gpa = ctx.gpa;
    const io = ctx.io();

    // `Compilation.destroy` cleans up all resources allocated by
    // `Compilation.create` (bin_file, cache_use, c_object_work_queue,
    // win32_resource_work_queue, windows_libs, crt_files,
    // libcxx/libcxxabi/libunwind/tsan/ubsan_rt/compiler_rt static libs,
    // glibc_so_files, c_object_table, failed_c_objects,
    // win32_resource_table, failed_win32_resources, time_report,
    // link_diags, oneshot_prelink_tasks, misc_failures,
    // cache_parent.manifest_dir). It also handles `zcu.deinit()` for
    // us, so we don't call it manually.
    ctx.compilation.destroy();
    ctx.dirs.deinit(io);
    ctx.io_impl.deinit();
    ctx.arena_state.deinit();
    // The static tid pool's items slice was backed by `ctx.arena_state`;
    // reset it before the next `allocate` so the stale pointer doesn't
    // trip the empty-pool invariant.
    Zcu.PerThread.Id.deinit();
    gpa.destroy(ctx);
}

/// Prepare the compilation for an incremental update.
///
/// For every file in `module_roots` that was ZIR-injected, saves the current
/// `file.zir` into `file.prev_zir` so the incremental pipeline can diff old
/// vs new ZIR during the next `zir_compilation_update`.
///
/// Must be called BEFORE injecting new ZIR and calling update.
/// Returns 0 on success, -1 on error.
pub export fn zir_compilation_prepare_update(ctx: ?*ZirContext) callconv(.c) i32 {
    const c = ctx orelse return -1;
    const gpa = c.gpa;
    const zcu = c.compilation.zcu orelse return -1;

    for (zcu.module_roots.values()) |opt_file_index| {
        const file_index = opt_file_index.unwrap() orelse continue;
        const file = zcu.fileByIndex(file_index);

        if (!file.zir_injected) continue;

        if (file.zir) |current_zir| {
            // If prev_zir already exists, free it first.
            if (file.prev_zir) |prev| {
                prev.deinit(gpa);
                gpa.destroy(prev);
            }

            // Allocate a new Zir on the heap and copy the current ZIR into it.
            const prev_zir_ptr = gpa.create(Zir) catch return -1;
            prev_zir_ptr.* = current_zir;
            file.prev_zir = prev_zir_ptr;

            // Clear the current ZIR so new ZIR can be injected.
            file.zir = null;
        }
    }

    return 0;
}

/// Mark a named struct's root file as changed for incremental recompilation.
///
/// Looks up `name` in the root dependencies, finds its root file in
/// `module_roots`, and sets `file.module_changed = true`. This tells the
/// incremental pipeline to invalidate and re-analyze that struct.
///
/// Returns 0 on success, -1 if the struct was not found.
pub export fn zir_compilation_invalidate_file(ctx: ?*ZirContext, name: [*:0]const u8) callconv(.c) i32 {
    const c = ctx orelse return -1;
    const zcu = c.compilation.zcu orelse return -1;

    const mod_name = mem.sliceTo(name, 0);
    const target_mod = c.root_mod.deps.get(mod_name) orelse return -1;

    const file_opt = zcu.module_roots.get(target_mod) orelse return -1;
    const file_index = file_opt.unwrap() orelse return -1;
    const file = zcu.fileByIndex(file_index);

    file.module_changed = true;
    return 0;
}

// ---------------------------------------------------------------------------
// zap_fork_compile_zig_to_object — general-purpose in-process Zig compile
// primitive (Memory Manager ABI v1.0 spec section 10.1.1).
//
// Public C-ABI surface used by Zap (and other third-party callers) to compile
// a single Zig source file to an object file in-process — no subprocess, no
// `zig build-obj`. The same Compilation API used elsewhere in zir_api.zig
// drives the compile; the only differences are:
//   * the root module's source is the caller's actual Zig file rather than
//     a generated stub + ZIR injection;
//   * the output mode is fixed to .Obj;
//   * libc is not linked (object files are partial — final link decides);
//   * `skip_linker_dependencies = true` since we are not producing a binary.
//
// The primitive is intentionally NOT memory-manager-specific. It is general
// to any caller that needs to compile a self-contained Zig file (codegen
// plugins, build-time helpers, etc.).
// ---------------------------------------------------------------------------

/// Wire-format target descriptor. Fields are integer values of
/// `std.Target.Cpu.Arch`, `std.Target.Os.Tag`, and `std.Target.Abi` as
/// pinned by ABI v1.0 (memory-manager-abi.md Appendix C).
pub const ZapForkTarget = extern struct {
    arch_tag: u16,
    os_tag: u16,
    abi_tag: u16,
    _reserved: u16,
};

/// Sentinel value for `ZapForkTarget.arch_tag` that requests the host
/// target. When set, `os_tag` and `abi_tag` are ignored and the
/// primitive selects the running compiler's native target. See spec
/// Appendix C.
pub const ZAP_FORK_ARCH_NATIVE: u16 = 0xFFFF;

/// Optimize mode. Mirrors `std.builtin.OptimizeMode` ordering.
pub const ZapForkOptimize = enum(c_int) {
    Debug = 0,
    ReleaseSafe = 1,
    ReleaseFast = 2,
    ReleaseSmall = 3,
};

/// Result codes for `zap_fork_compile_zig_to_object`.
pub const ZapForkResult = enum(c_int) {
    Ok = 0,
    SourceNotFound = 1,
    CompilationFailed = 2,
    TargetUnsupported = 3,
    InternalError = 99,
};

/// Diagnostic buffer writer used by `zap_fork_compile_zig_to_object`
/// and its internal helpers. The buffer is caller-supplied (UTF-8,
/// NUL-terminated on return) and bounded; oversize messages are
/// truncated with a clear marker.
///
/// The `Writer` is a `std.Io.Writer.fixed` over the caller's buffer so
/// that we can render `Compilation.CreateDiagnostic` and
/// `ErrorBundle` messages directly into it without an intermediate
/// allocation. When the buffer fills up, `Writer` returns
/// `error.WriteFailed`; the caller is expected to record the
/// truncation marker.
const ZapForkDiag = struct {
    /// Pointer to the caller's buffer, or null if the caller passed
    /// `null` for the diagnostic argument.
    buf: ?[*]u8,
    /// Buffer capacity in bytes (including the trailing NUL slot).
    cap: usize,

    /// Format a small message into the caller's buffer. Truncates if
    /// the rendered text exceeds the capacity. Always NUL-terminates.
    fn write(self: ZapForkDiag, comptime fmt: []const u8, args: anytype) void {
        if (self.cap == 0) return;
        const out = self.buf orelse return;
        var scratch: [1024]u8 = undefined;
        const printed = std.fmt.bufPrint(&scratch, fmt, args) catch &scratch;
        const copy_len = @min(printed.len, self.cap - 1);
        @memcpy(out[0..copy_len], printed[0..copy_len]);
        out[copy_len] = 0;
    }

    /// Render `Compilation.CreateDiagnostic` through its `format`
    /// method into the caller's buffer. The diagnostic union carries
    /// structured fields (cache path, libc-detection error, etc.); the
    /// `format` method is the canonical way to flatten them to a
    /// human-readable message.
    fn writeCreateDiag(self: ZapForkDiag, diag: Compilation.CreateDiagnostic) void {
        if (self.cap == 0) return;
        const out = self.buf orelse return;
        // Reserve one byte for NUL.
        var writer = std.Io.Writer.fixed(out[0 .. self.cap - 1]);
        writer.print("zap_fork: Compilation.create failed: {f}", .{diag}) catch {};
        out[writer.end] = 0;
    }

    /// Render an `ErrorBundle` into the caller's buffer. Each error
    /// message is written on its own line with source-location prefix
    /// where available. Note (sub-message) records attached to each
    /// error message are written as additional indented `note:` lines
    /// immediately after their parent error, mirroring
    /// `dumpErrorBundle` (the stderr path). If the buffer fills up,
    /// the remaining errors are summarized as `... [truncated, N more
    /// errors]`. Notes belonging to a parent error that itself didn't
    /// fit are elided implicitly; notes belonging to a parent that
    /// did fit are dropped silently if there's no room — the parent's
    /// presence is the primary signal and is preserved.
    ///
    /// Buffer layout (cap = self.cap):
    ///   [0 .. cap-1-marker_reserve)         normal output region
    ///   [cap-1-marker_reserve .. cap-1)     reserved for truncation marker
    ///   [cap-1]                             NUL terminator slot
    ///
    /// `marker_reserve` is sized to fit the longest possible truncation
    /// marker (`... [truncated, N more errors]`) up to a 10-digit
    /// `omitted` count, plus a leading newline so the marker always
    /// starts on its own line even when the last in-region write
    /// happens to be a partial fragment. Reserving up front guarantees
    /// the marker can always be emitted intact when needed, and never
    /// clobbers a trailing newline from earlier output.
    fn writeErrorBundle(self: ZapForkDiag, eb: std.zig.ErrorBundle) void {
        if (self.cap == 0) return;
        const out = self.buf orelse return;
        // Longest truncation marker shape (leading newline + body +
        // up to 10 decimal digits for the count); use a static upper
        // bound so the reserve is comptime-known. If the buffer is
        // smaller than `marker_reserve + 1` (for NUL), skip reserving
        // and fall back to no-marker behavior — the buffer is too
        // small to be useful anyway.
        const marker_reserve: usize = "\n... [truncated, 4294967295 more errors]".len;
        const reserve = if (self.cap >= marker_reserve + 1) marker_reserve else 0;

        var writer = std.Io.Writer.fixed(out[0 .. self.cap - 1 - reserve]);

        const messages = eb.getMessages();
        var first_omitted_index: ?u32 = null;
        outer: for (messages, 0..) |msg_index, i| {
            const err_msg = eb.getErrorMessage(msg_index);
            const text = eb.nullTerminatedString(err_msg.msg);

            const printed = if (err_msg.src_loc != .none) blk: {
                const src = eb.getSourceLocation(err_msg.src_loc);
                const path = eb.nullTerminatedString(src.src_path);
                break :blk writer.print("[{d}] {s}:{d}:{d}: error: {s}\n", .{
                    i, path, src.line + 1, src.column + 1, text,
                });
            } else writer.print("[{d}] error: {s}\n", .{ i, text });

            printed catch {
                first_omitted_index = @intCast(i);
                break :outer;
            };

            // Notes are best-effort: once the parent error has been
            // recorded, dropping a note loses context but does not
            // change the count of errors reported. If a note doesn't
            // fit, stop emitting notes for this error and continue to
            // the next error (which may still fit if it's shorter).
            for (eb.getNotes(msg_index)) |note_index| {
                const note = eb.getErrorMessage(note_index);
                const note_text = eb.nullTerminatedString(note.msg);
                const note_printed = if (note.src_loc != .none) blk: {
                    const note_src = eb.getSourceLocation(note.src_loc);
                    const note_path = eb.nullTerminatedString(note_src.src_path);
                    break :blk writer.print("       {s}:{d}:{d}: note: {s}\n", .{
                        note_path, note_src.line + 1, note_src.column + 1, note_text,
                    });
                } else writer.print("       note: {s}\n", .{note_text});

                note_printed catch break;
            }
        }

        // End of normal output region. The reserve tail is still
        // available for the truncation marker.
        var end: usize = writer.end;
        if (first_omitted_index) |idx| {
            const omitted = @as(u32, @intCast(messages.len)) - idx;
            // Render the marker into the reserved tail using a
            // separate fixed writer; this cannot fail to fit because
            // `marker_reserve` was sized for the worst case.
            if (reserve != 0) {
                var marker_writer = std.Io.Writer.fixed(out[end .. end + reserve]);
                marker_writer.print("\n... [truncated, {d} more errors]", .{omitted}) catch {};
                end += marker_writer.end;
            }
        }

        out[end] = 0;
    }
};

/// Resolve a platform-appropriate default cache directory.
///
/// On Linux/macOS this is `/tmp/zap-fork-cache` (preserves the spike's
/// historical behavior). On Windows this is `%TEMP%\zap-fork-cache`
/// (or `%TMP%\zap-fork-cache` as a fallback). On any other host this
/// returns `error.UnsupportedOs` so the caller can surface a clear
/// diagnostic — callers on exotic hosts must pass an explicit override.
///
/// Returned slice is allocated in `ar` so its lifetime matches the
/// caller's arena.
fn defaultCachePath(ar: Allocator) ![]const u8 {
    return switch (builtin.target.os.tag) {
        .linux, .macos => "/tmp/zap-fork-cache",
        .windows => blk: {
            // Try TEMP first (the conventional Windows variable),
            // then TMP as a fallback. Both follow the same path
            // convention (no trailing separator). If neither is set,
            // surface the failure clearly rather than silently
            // defaulting to a path that may not be writable.
            const temp: []const u8 = temp_blk: {
                if (std.process.getEnvVarOwned(ar, "TEMP")) |t| {
                    break :temp_blk t;
                } else |err| switch (err) {
                    error.EnvironmentVariableNotFound => {},
                    else => return err,
                }
                if (std.process.getEnvVarOwned(ar, "TMP")) |t| {
                    break :temp_blk t;
                } else |err| switch (err) {
                    error.EnvironmentVariableNotFound => return error.WindowsTempEnvMissing,
                    else => return err,
                }
            };
            break :blk try std.fmt.allocPrint(ar, "{s}\\zap-fork-cache", .{temp});
        },
        else => error.UnsupportedOs,
    };
}

/// Returns true iff `(arch, os_tag, abi_tag)` is a target this
/// primitive can compile a self-contained object for.
///
/// IMPORTANT: this primitive emits a SINGLE relocatable object via
/// `build-obj` with `skip_linker_dependencies = true`. It does NOT
/// link, so the target's libc/CRT availability is irrelevant to object
/// emission itself — only Zig's codegen + integrated assembler need to
/// support the target, which they do for the entire matrix below
/// WITHOUT any external toolchain (Zig bundles musl and provides
/// freestanding/none ABIs out of the box; the glibc/Windows entries
/// only need Zig's bundled stubs to *link*, which is the caller's
/// final-link concern, not this object-compile step).
///
/// The earlier hard-coded five-triple whitelist was an artificial
/// restriction that rejected fully-supported targets such as
/// `*-linux-musl`. It is replaced here with the real capability
/// boundary: the common cross targets Zig handles natively. A genuinely
/// unsupported arch/os/abi (e.g. an exotic embedded target Zig's
/// codegen cannot target) still returns false and is rejected with a
/// clear diagnostic — there is no silent success.
fn isSupportedTriple(
    arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    abi_tag: std.Target.Abi,
) bool {
    return switch (arch) {
        .x86_64, .aarch64 => switch (os_tag) {
            // Linux: glibc and musl (musl is fully bundled by Zig; no
            // external toolchain needed for either to produce objects).
            .linux => abi_tag == .gnu or abi_tag == .musl or abi_tag == .none,
            // macOS: native ABI is `.none` for Zig's Mach-O target.
            .macos => abi_tag == .none,
            // Windows: MSVC and GNU (mingw) ABIs.
            .windows => abi_tag == .msvc or abi_tag == .gnu,
            // Bare-metal / freestanding has no ABI requirement.
            .freestanding => true,
            else => false,
        },
        else => false,
    };
}

/// Compile a Zig source file to an object file in-process.
///
/// `source_path` and `out_object_path` are null-terminated UTF-8 paths.
/// `target` specifies the cross-compile target. Pass
/// `arch_tag = ZAP_FORK_ARCH_NATIVE` (0xFFFF) for native compilation;
/// the implementation rejects any other invalid combination with
/// `TargetUnsupported`. The resolved triple — whether from explicit
/// tags or the native sentinel — is checked against the v1.0 supported
/// whitelist (Appendix C.1); unsupported triples are rejected with a
/// diagnostic naming the requested triple. `target._reserved` must be
/// zero in v1.0; the primitive rejects a non-zero value with
/// `TargetUnsupported`.
/// `optimize` selects the optimize mode.
/// `out_diagnostic_buffer`/`out_diagnostic_capacity` receive a UTF-8
/// diagnostic message on non-Ok return; pass null to discard. On
/// `CompilationFailed` the buffer is populated with the formatted
/// contents of the Zig compiler's structured `ErrorBundle` (one error
/// per line with source-location prefix; note records appear as
/// indented `note:` lines below their parent error); the rest of the
/// messages are summarized as `... [truncated, N more errors]` if the
/// buffer fills up. On `Ok` return, the buffer is left untouched.
///
/// Thread safety: the function spins up its own `Compilation` instance
/// and tears it down before returning. Concurrent calls from different
/// threads are safe in principle, but the underlying Zig compiler relies
/// on a per-Compilation `Io.Threaded` runtime that is *not* designed for
/// many concurrent in-process compilations — callers should serialize
/// calls at the Zap-side build orchestrator. The function itself does no
/// caller synchronization.
///
/// LLVM context note: when `build_options.have_llvm` is true, the
/// compiler uses a global LLVM context for codegen. Re-entrant calls
/// from within an existing Zig Compilation (e.g., from a hypothetical
/// build-step plugin running inside another `compilation.update()`)
/// would be unsafe. The Zap build orchestrator drives this primitive
/// from the top level only, well before any other Compilation is alive,
/// so the LLVM-context restriction is not exercised in Zap's use case.
/// Future v2 work could decouple the LLVM context via Compilation's
/// nested sub-compilation mechanism (see Compilation.zig:5032 and
/// related sub_compilation paths), which already runs in-process.
pub export fn zap_fork_compile_zig_to_object(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    /// Optional caller-supplied Zig stdlib directory. Pass null to let
    /// the primitive auto-detect from the running compiler's self-exe
    /// (uses `introspect.findZigLibDir`). Callers like Zap, which
    /// embed the stdlib in a tar archive that's unpacked to a temp
    /// dir at runtime, must pass that temp dir explicitly because the
    /// running binary is not laid out like a Zig install.
    zig_lib_dir_opt: ?[*:0]const u8,
    /// Optional caller-supplied local cache directory. Pass null to
    /// use the primitive's platform default (`/tmp/zap-fork-cache` on
    /// Linux/macOS, `%TEMP%\zap-fork-cache` on Windows). On hosts that
    /// have no documented default, the primitive returns
    /// `InternalError` with an explanatory diagnostic, so exotic-host
    /// callers must thread an explicit path through this argument.
    /// Callers driving many compilations (e.g., Zap's build
    /// orchestrator) can thread their own per-build cache through this
    /// argument.
    local_cache_dir_opt: ?[*:0]const u8,
    /// Optional caller-supplied global cache directory. Pass null to
    /// use the same default as `local_cache_dir_opt`.
    global_cache_dir_opt: ?[*:0]const u8,
    /// Optional CPU model/feature set (mirrors `zig build`'s `-Dcpu=`,
    /// e.g. "baseline", "apple_m1", "x86_64_v3", "<model>+feat-feat").
    /// Pass null or "" for the resolved triple's default CPU. When set,
    /// the manager `.o` is built for the SAME CPU as the user binary so
    /// every object in the final link agrees on the target machine.
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult {
    const diag = ZapForkDiag{
        .buf = out_diagnostic_buffer,
        .cap = out_diagnostic_capacity,
    };

    const source_path_slice = mem.sliceTo(source_path, 0);
    const out_object_path_slice = mem.sliceTo(out_object_path, 0);

    // Reserved field validation. v1.0 fixes `_reserved` to zero;
    // a non-zero value indicates either caller error or a struct
    // built against a future ABI version we cannot interpret
    // safely. This check runs unconditionally — including when
    // `arch_tag == ZAP_FORK_ARCH_NATIVE` — because the spec rules
    // `_reserved` is fixed for the entire struct, not just the
    // explicit-triple branch (Appendix C of the spec).
    if (target._reserved != 0) {
        diag.write("zap_fork: target._reserved must be 0 (got {d})", .{target._reserved});
        return .TargetUnsupported;
    }

    // Resolve target. Special sentinel `ZAP_FORK_ARCH_NATIVE` for
    // native; otherwise construct a target query directly from the
    // wire-format triple.
    const target_query: std.Target.Query = blk: {
        if (target.arch_tag == ZAP_FORK_ARCH_NATIVE) {
            // For the native sentinel, resolve the host triple and
            // verify it's in the v1.0 supported whitelist. An
            // experimental developer machine whose host doesn't
            // appear in the supported set must fail clearly rather
            // than silently miscompiling.
            const host = builtin.target;
            if (!isSupportedTriple(host.cpu.arch, host.os.tag, host.abi)) {
                diag.write(
                    "zap_fork: native host triple {s}-{s}-{s} is not in the v1.0 supported set",
                    .{ @tagName(host.cpu.arch), @tagName(host.os.tag), @tagName(host.abi) },
                );
                return .TargetUnsupported;
            }
            break :blk .{};
        }
        // Validate the triple against the v1.0 supported set (Appendix C).
        const arch: std.Target.Cpu.Arch = inline for (@typeInfo(std.Target.Cpu.Arch).@"enum".fields) |f| {
            if (f.value == target.arch_tag) break @field(std.Target.Cpu.Arch, f.name);
        } else {
            diag.write("zap_fork: unsupported arch_tag={d}", .{target.arch_tag});
            return .TargetUnsupported;
        };
        const os_tag: std.Target.Os.Tag = inline for (@typeInfo(std.Target.Os.Tag).@"enum".fields) |f| {
            if (f.value == target.os_tag) break @field(std.Target.Os.Tag, f.name);
        } else {
            diag.write("zap_fork: unsupported os_tag={d}", .{target.os_tag});
            return .TargetUnsupported;
        };
        const abi_tag: std.Target.Abi = inline for (@typeInfo(std.Target.Abi).@"enum".fields) |f| {
            if (f.value == target.abi_tag) break @field(std.Target.Abi, f.name);
        } else {
            diag.write("zap_fork: unsupported abi_tag={d}", .{target.abi_tag});
            return .TargetUnsupported;
        };
        // Whitelist check: even though each individual tag resolves
        // to a valid enum value, the v1.0 spec (Appendix C.1) supports
        // exactly five (arch, os, abi) triples. Any other combination
        // is rejected here with a diagnostic that names the requested
        // triple.
        if (!isSupportedTriple(arch, os_tag, abi_tag)) {
            diag.write(
                "zap_fork: unsupported target triple {s}-{s}-{s} (v1.0 supports x86_64-linux-gnu, x86_64-macos-none, aarch64-linux-gnu, aarch64-macos-none, x86_64-windows-msvc)",
                .{ @tagName(arch), @tagName(os_tag), @tagName(abi_tag) },
            );
            return .TargetUnsupported;
        }
        break :blk .{
            .cpu_arch = arch,
            .os_tag = os_tag,
            .abi = abi_tag,
        };
    };

    // Apply an optional CPU model/feature set onto the resolved
    // triple. We re-parse through `std.Target.Query.parse` (the
    // canonical path, identical to what the user-binary compile uses)
    // so the manager `.o` is built for exactly the same machine as the
    // rest of the binary. An empty/absent string keeps the triple's
    // default CPU. The arch is pinned to the already-validated triple
    // so a CPU string can only refine the CPU, never change the arch.
    // Heap-allocated `arch_os_abi` buffer (only when an explicit triple
    // forces a synthesized "arch-os-abi" string). Owned at function
    // scope with a `defer` so it is freed on EVERY exit path, including
    // the `return .TargetUnsupported` taken from inside the block on an
    // invalid CPU. `std.Target.Query.parse` copies what it needs (CPU
    // model -> enum/`.explicit` model pointer into static tables,
    // features -> bit-sets; see `lib/std/Target/Query.zig`) and never
    // retains a slice into this buffer, so freeing it right after the
    // `cpu_query` block is correct.
    var arch_os_abi_owned: ?[]u8 = null;
    defer if (arch_os_abi_owned) |buf| std.heap.c_allocator.free(buf);

    const cpu_query: std.Target.Query = blk: {
        const cpu_str: ?[]const u8 = if (cpu_features_opt) |c| mem.sliceTo(c, 0) else null;
        if (cpu_str == null or cpu_str.?.len == 0) break :blk target_query;

        const arch_for_cpu = target_query.cpu_arch orelse builtin.target.cpu.arch;
        const arch_os_abi: []const u8 = if (target_query.cpu_arch == null)
            "native"
        else blk2: {
            const buf = std.fmt.allocPrint(std.heap.c_allocator, "{s}-{s}-{s}", .{
                @tagName(arch_for_cpu),
                @tagName(target_query.os_tag orelse builtin.target.os.tag),
                @tagName(target_query.abi orelse builtin.target.abi),
            }) catch {
                diag.write("zap_fork: out of memory resolving -Dcpu", .{});
                return .InternalError;
            };
            arch_os_abi_owned = buf;
            break :blk2 buf;
        };
        var diags: std.Target.Query.ParseOptions.Diagnostics = .{};
        const parsed = std.Target.Query.parse(.{
            .arch_os_abi = arch_os_abi,
            .cpu_features = cpu_str.?,
            .diagnostics = &diags,
        }) catch {
            diag.write("zap_fork: invalid -Dcpu='{s}' for target", .{cpu_str.?});
            return .TargetUnsupported;
        };
        break :blk parsed;
    };

    const zig_lib_dir_slice: ?[]const u8 = if (zig_lib_dir_opt) |p| mem.sliceTo(p, 0) else null;
    const local_cache_dir_slice: ?[]const u8 = if (local_cache_dir_opt) |p| mem.sliceTo(p, 0) else null;
    const global_cache_dir_slice: ?[]const u8 = if (global_cache_dir_opt) |p| mem.sliceTo(p, 0) else null;

    compileToObjectImpl(
        source_path_slice,
        out_object_path_slice,
        cpu_query,
        optimize,
        zig_lib_dir_slice,
        local_cache_dir_slice,
        global_cache_dir_slice,
        diag,
    ) catch |err| switch (err) {
        error.SourceNotFound => {
            diag.write("zap_fork: source not found: {s}", .{source_path_slice});
            return .SourceNotFound;
        },
        // For CompilationFailed and CreateFailed, `compileToObjectImpl`
        // has already written the structured diagnostic (an
        // `ErrorBundle` or a `Compilation.CreateDiagnostic`) into the
        // caller's buffer. Don't overwrite it here.
        error.CompilationFailed => return .CompilationFailed,
        error.CreateFailed => return .CompilationFailed,
        error.OutputDirInaccessible => {
            // Diagnostic was written by the impl with the full path.
            return .InternalError;
        },
        // The impl already wrote a target-naming diagnostic; surface it
        // as `TargetUnsupported` (the semantically-correct code, and
        // symmetric with the explicit-triple rejection paths above that
        // also return `.TargetUnsupported`). Do NOT fall through to the
        // generic `else` arm — that would clobber the precise message
        // with "internal error: UnableToResolveTarget".
        error.UnableToResolveTarget => return .TargetUnsupported,
        else => {
            diag.write("zap_fork: internal error: {s}", .{@errorName(err)});
            return .InternalError;
        },
    };

    return .Ok;
}

/// Result of `zap_fork_classify_subtool` / dispatched by
/// `zap_fork_run_subtool`.
pub const ZapForkSubtool = enum(c_int) {
    /// argv[1] is not a recognized Zig toolchain subcommand.
    not_a_subtool = 0,
    /// argv[1] is `clang`, `-cc1`, or `-cc1as`.
    clang = 1,
    /// argv[1] is `ld.lld`, `lld-link`, or `wasm-ld`.
    lld = 2,
    /// argv[1] is `ar`, `dlltool`, `ranlib`, or `lib`.
    llvm_ar = 3,
};

/// Classify `argv[1]` as a Zig toolchain subcommand that the embedded
/// Zig compiler can service in-process.
///
/// Zig's cross-compilation architecture builds CRT/libc/compiler_rt by
/// having the running executable re-invoke itself as
/// `<self_exe> clang|-cc1|-cc1as|ld.lld|... <args>`. When a library
/// embedder (Zap) is `self_exe`, it must recognize these subcommands
/// and dispatch them into the embedded Zig tool entry points exactly
/// as the Zig CLI does — otherwise the subprocess is a no-op and the
/// cross build silently produces no artifact. Clang's driver
/// legitimately spawns `<self_exe> -cc1`/`-cc1as` for multi-phase
/// `.S` (assembler-with-cpp) inputs even with integrated-cc1, so the
/// in-process `Compilation` flag alone is insufficient; the embedder
/// MUST be a faithful `self_exe`.
///
/// `argc`/`argv` are the embedder's full process argv (argv[0] is the
/// program path). Returns `.not_a_subtool` when `argc < 2` or argv[1]
/// is not a recognized subcommand; the embedder then proceeds with its
/// normal CLI dispatch.
pub export fn zap_fork_classify_subtool(
    argc: c_int,
    argv: [*]const [*:0]const u8,
) callconv(.c) ZapForkSubtool {
    if (argc < 2) return .not_a_subtool;
    const cmd = mem.sliceTo(argv[1], 0);
    if (mem.eql(u8, cmd, "clang") or
        mem.eql(u8, cmd, "-cc1") or
        mem.eql(u8, cmd, "-cc1as"))
        return .clang;
    if (mem.eql(u8, cmd, "ld.lld") or
        mem.eql(u8, cmd, "lld-link") or
        mem.eql(u8, cmd, "wasm-ld"))
        return .lld;
    if (mem.eql(u8, cmd, "ar") or
        mem.eql(u8, cmd, "dlltool") or
        mem.eql(u8, cmd, "ranlib") or
        mem.eql(u8, cmd, "lib"))
        return .llvm_ar;
    return .not_a_subtool;
}

/// Run the Zig toolchain subcommand identified by `argv[1]` in-process
/// and return its process exit code (0 = success). The caller
/// (embedder `main`) should pass this exit code straight to
/// `std.process.exit` — these subcommands ARE the entire purpose of the
/// process invocation (Zig spawns `<self_exe> <subtool> ...` as a
/// dedicated child), so exiting with the returned code is correct.
///
/// `argv` mirrors the layout the Zig CLI's `mainArgs` sees: argv[0] is
/// the program path, argv[1] is the subcommand, argv[2..] are the tool
/// arguments. This matches what `clangMain`/`lldMain`/`llvmArMain`
/// expect (each shaves argv[0] internally; `clangMain` additionally
/// keeps `-cc1`/`-cc1as` at slot 1, exactly as the CLI path does).
///
/// Behavior is byte-identical to the Zig CLI's own dispatch in
/// `mainArgs` (src/main.zig): `clang`/`-cc1`/`-cc1as` -> `clangMain`;
/// `ld.lld`/`lld-link`/`wasm-ld` -> `lldMain(.., true)`;
/// `ar`/`dlltool`/`ranlib`/`lib` -> `llvmArMain`. Returns 0xFF if
/// `argv[1]` is not a recognized subtool (caller should have checked
/// `zap_fork_classify_subtool` first) or on internal allocation
/// failure.
pub export fn zap_fork_run_subtool(
    argc: c_int,
    argv: [*]const [*:0]const u8,
) callconv(.c) c_int {
    if (argc < 2) return 0xFF;
    const gpa = std.heap.c_allocator;

    // Rebuild a `[]const []const u8` slice for the Zig tool entry
    // points. They expect the same shape as `std.process.argsAlloc`
    // would yield (argv[0] = program path, argv[1] = subcommand).
    const n: usize = @intCast(argc);
    const args = gpa.alloc([]const u8, n) catch return 0xFF;
    defer gpa.free(args);
    for (0..n) |i| args[i] = mem.sliceTo(argv[i], 0);

    const main = @import("main.zig");
    const cmd = args[1];

    if (mem.eql(u8, cmd, "clang") or
        mem.eql(u8, cmd, "-cc1") or
        mem.eql(u8, cmd, "-cc1as"))
    {
        const code = main.clangMain(gpa, args) catch return 0xFF;
        return code;
    }
    if (mem.eql(u8, cmd, "ld.lld") or
        mem.eql(u8, cmd, "lld-link") or
        mem.eql(u8, cmd, "wasm-ld"))
    {
        // `can_exit_early = true` matches the Zig CLI's `lldMain(.., true)`:
        // this process exists solely to run LLD, so an early exit is
        // correct and matches the behavior Zig's own re-spawn relies on.
        const code = main.lldMain(gpa, args, true) catch return 0xFF;
        return code;
    }
    if (mem.eql(u8, cmd, "ar") or
        mem.eql(u8, cmd, "dlltool") or
        mem.eql(u8, cmd, "ranlib") or
        mem.eql(u8, cmd, "lib"))
    {
        const code = main.llvmArMain(gpa, args) catch return 0xFF;
        return code;
    }
    return 0xFF;
}

const CompileToObjectError = error{
    SourceNotFound,
    CompilationFailed,
    CreateFailed,
    OutputDirInaccessible,
    OutOfMemory,
    UnableToResolveTarget,
};

fn compileToObjectImpl(
    source_path: []const u8,
    out_object_path: []const u8,
    target_query: std.Target.Query,
    optimize: ZapForkOptimize,
    zig_lib_dir_opt: ?[]const u8,
    local_cache_dir_opt: ?[]const u8,
    global_cache_dir_opt: ?[]const u8,
    diag: ZapForkDiag,
) CompileToObjectError!void {
    const gpa = std.heap.c_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // Initialize an Io.Threaded instance for this compile. Reuses the
    // same threading model as createImpl above. We allow up to 4 worker
    // threads, mirroring the rest of zir_api.zig. The `catch 2`
    // fallback handles platforms where `getCpuCount` fails. We choose
    // 2 (rather than 1) so that the subsequent `Io.Limit.limited(N-1)`
    // call always sees a non-zero limit; with `1` the limit collapses
    // to `.limited(0)`, which is at best a noop and at worst trips a
    // latent assertion downstream.
    const thread_limit = @min(std.Thread.getCpuCount() catch 2, 4);
    var io_impl: Io.Threaded = .init(gpa, .{ .stack_size = 16 * 1024 * 1024 });
    defer io_impl.deinit();
    const limit: Io.Limit = .limited(thread_limit - 1);
    io_impl.setAsyncLimit(limit);
    io_impl.concurrent_limit = limit;
    // Reset the global tid pool first. Sibling compiles in this same
    // process (e.g. the outer ZIR build invoked through `createImpl`
    // after this manager-object compile returns) keep their tid storage
    // alive via separate arenas; without this reset, the static
    // `available_tids` slice still points into the previous compile's
    // arena (already freed at `arena_state.deinit()`) and the
    // `assert(items.len == 0)` inside `allocate` either trips or
    // silently corrupts.
    Zcu.PerThread.Id.deinit();
    Zcu.PerThread.Id.allocate(ar, @max(thread_limit, 2)) catch |err| {
        logErr("zap_fork: PerThread.Id.allocate failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };
    // Make sure the pool is reset BEFORE this arena dies, otherwise a
    // future compile (re)allocate trips an assert on the dangling
    // pointer into our about-to-be-freed arena memory.
    defer Zcu.PerThread.Id.deinit();
    const io = io_impl.io();

    // Resolve the zig lib dir. If the caller provided an explicit path,
    // use that — Zap embeds its pinned stdlib in a tar archive and
    // unpacks it at runtime, so it must supply that path directly.
    // Otherwise auto-detect from the running compiler's self-exe.
    //
    // `self_exe_path` is required by `Compilation.create` regardless of
    // whether `zig_lib_dir_opt` is supplied — the compiler uses it to
    // anchor a number of auxiliary lookups (cache key derivation,
    // compiler_rt source location, etc.) that are independent of the
    // stdlib path. Always resolve it.
    const self_exe_path = std.process.executablePathAlloc(io, ar) catch |err| {
        logErr("zap_fork: executablePathAlloc failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };
    const zig_lib_dir: Cache.Directory = blk: {
        if (zig_lib_dir_opt) |dir_path| {
            const cwd_for_open = Dir.cwd();
            const handle = cwd_for_open.openDir(io, dir_path, .{}) catch |err| {
                logErr("zap_fork: openDir(zig_lib_dir={s}) failed: {s}", .{ dir_path, @errorName(err) });
                return error.OutOfMemory;
            };
            break :blk .{ .handle = handle, .path = try ar.dupe(u8, dir_path) };
        }
        break :blk introspect.findZigLibDir(ar, io) catch |err| {
            logErr("zap_fork: findZigLibDir failed: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        };
    };

    // Resolve local and global cache paths. On Linux/macOS the default
    // is `/tmp/zap-fork-cache` (matches the spike's historical
    // behaviour); on Windows we use `%TEMP%\zap-fork-cache` because
    // `/tmp` does not exist. On any other host the primitive emits an
    // `OutputDirInaccessible` diagnostic naming the OS — callers on
    // exotic hosts must pass `local_cache_dir_opt`/`global_cache_dir_opt`
    // explicitly. Callers driving many compilations (e.g., Zap's build
    // orchestrator) can override both independently.
    const default_cache_path: []const u8 = if (local_cache_dir_opt != null and global_cache_dir_opt != null)
        // Both caller-supplied — the placeholder is never read.
        ""
    else
        defaultCachePath(ar) catch |err| switch (err) {
            error.UnsupportedOs => {
                diag.write(
                    "zap_fork: no default cache path for OS '{s}'; pass local_cache_dir_opt/global_cache_dir_opt",
                    .{@tagName(builtin.target.os.tag)},
                );
                return error.OutputDirInaccessible;
            },
            error.WindowsTempEnvMissing => {
                diag.write(
                    "zap_fork: cannot resolve default cache path: neither TEMP nor TMP env var is set",
                    .{},
                );
                return error.OutputDirInaccessible;
            },
            else => {
                diag.write(
                    "zap_fork: failed to resolve default cache path: {s}",
                    .{@errorName(err)},
                );
                return error.OutputDirInaccessible;
            },
        };
    const local_cache_path: []const u8 = local_cache_dir_opt orelse default_cache_path;
    const global_cache_path: []const u8 = global_cache_dir_opt orelse default_cache_path;

    const cwd = Dir.cwd();
    // `createDirPath` returns `PathAlreadyExists` when the path is
    // already present — that's the happy case, suppress it. Any other
    // error (permission denied, ENOSPC, etc.) is fatal and must
    // surface through the diagnostic buffer.
    cwd.createDirPath(io, local_cache_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            diag.write("zap_fork: createDirPath({s}) failed: {s}", .{ local_cache_path, @errorName(err) });
            return error.OutputDirInaccessible;
        },
    };
    if (!mem.eql(u8, local_cache_path, global_cache_path)) {
        cwd.createDirPath(io, global_cache_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                diag.write("zap_fork: createDirPath({s}) failed: {s}", .{ global_cache_path, @errorName(err) });
                return error.OutputDirInaccessible;
            },
        };
    }

    const local_cache_handle = cwd.openDir(io, local_cache_path, .{}) catch |err| {
        diag.write("zap_fork: openDir({s}) failed: {s}", .{ local_cache_path, @errorName(err) });
        return error.OutputDirInaccessible;
    };

    const global_cache_handle: Dir = if (mem.eql(u8, local_cache_path, global_cache_path))
        local_cache_handle
    else
        cwd.openDir(io, global_cache_path, .{}) catch |err| {
            diag.write("zap_fork: openDir({s}) failed: {s}", .{ global_cache_path, @errorName(err) });
            return error.OutputDirInaccessible;
        };

    var dirs: Compilation.Directories = .{
        .cwd = introspect.getResolvedCwd(io, ar) catch |err| {
            logErr("zap_fork: getResolvedCwd failed: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        },
        .zig_lib = zig_lib_dir,
        .local_cache = .{ .handle = local_cache_handle, .path = try ar.dupe(u8, local_cache_path) },
        .global_cache = .{ .handle = global_cache_handle, .path = try ar.dupe(u8, global_cache_path) },
    };
    defer dirs.deinit(io);

    // Resolve the target query GRACEFULLY. This MUST NOT use
    // `std.zig.resolveTargetQueryOrFatal`: that helper calls
    // `std.process.fatal` on any resolution failure, which aborts the
    // entire embedder (Zap) process and bypasses Zap's structured
    // diagnostic + non-zero-exit handling. A parseable-but-unresolvable
    // `-Dtarget=`/`-Dcpu=` (e.g. a valid-enum triple the system
    // resolver rejects, or a CPU/feature mismatch threaded in via
    // `cpu_query`) must fail this primitive with a returned error and a
    // target-naming diagnostic — EXACTLY symmetric with the user-binary
    // path (`createImpl`, which already uses
    // `std.zig.system.resolveTargetQuery` + a graceful
    // `error.InvalidTargetQuery`). The Zap-side driver then surfaces
    // this through `DriverDiagnostic` and a clean non-zero exit instead
    // of a whole-process abort.
    const resolved_result = std.zig.system.resolveTargetQuery(io, target_query) catch |resolve_err| {
        diag.write(
            "zap_fork: unable to resolve target {s}-{s}-{s}: {s}",
            .{
                if (target_query.cpu_arch) |a| @tagName(a) else "native",
                if (target_query.os_tag) |o| @tagName(o) else "native",
                if (target_query.abi) |ab| @tagName(ab) else "native",
                @errorName(resolve_err),
            },
        );
        return error.UnableToResolveTarget;
    };
    const resolved_target: Package.Module.ResolvedTarget = .{
        .result = resolved_result,
        .is_native_os = target_query.isNativeOs(),
        .is_native_abi = target_query.isNativeAbi(),
        .is_explicit_dynamic_linker = false,
    };

    const optimize_mode_enum: std.builtin.OptimizeMode = switch (optimize) {
        .Debug => .Debug,
        .ReleaseSafe => .ReleaseSafe,
        .ReleaseFast => .ReleaseFast,
        .ReleaseSmall => .ReleaseSmall,
    };

    // Object-file output: no compiler_rt, no ubsan_rt, no linker passes
    // — that is the responsibility of the final link performed by Zap's
    // build orchestrator.
    //
    // `link_libc` selection: on targets where the platform stdlib only
    // works under libc (macOS, iOS, Solaris, etc. — see
    // `std.Target.requiresLibC`), `std.os` cannot resolve syscall-layer
    // primitives without libc bindings, and even purely `std.mem` /
    // `std.atomic` translation units fail because `std.posix.system`
    // resolves to an empty fallback struct that lacks members like
    // `getrandom` and `IOV_MAX`. Forcing `link_libc = false` on those
    // platforms breaks compilation of any non-trivial manager source
    // before codegen. Honour `requiresLibC()` here; manager objects are
    // still linked into the host binary by Zap's final link, which adds
    // libc once across all objects (the manager's symbol contributions
    // are unchanged either way — `linksection`, `zap_memory_section`,
    // and the vtable function pointers are all opaque to the libc
    // toggle).
    const target_requires_libc = resolved_target.result.requiresLibC();
    // LTO note: ThinLTO would let the host-binary link step inline through
    // the manager's vtable across the `.o` boundary, recovering the per-
    // allocation overhead that retain/release/allocate pay today on every
    // call. But Zig's `Compilation.Config.resolve` requires LLD for LTO
    // and `target_util.hasLldSupport` returns false for Mach-O (Zig has
    // its own Mach-O linker). So LTO is unavailable on macOS through this
    // path. ELF and COFF could enable LTO if the fork is built with
    // `-Denable-llvm=true`; that's worth revisiting once the perf-
    // critical workloads run on Linux CI.
    const config = Compilation.Config.resolve(.{
        .output_mode = .Obj,
        .resolved_target = resolved_target,
        .is_test = false,
        .have_zcu = true,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode_enum,
        .root_strip = false,
        .link_libc = target_requires_libc,
        .link_mode = null,
        .lto = .none,
        .use_llvm = build_options.have_llvm,
    }) catch return error.OutOfMemory;

    // Verify the source file exists. We do this before constructing the
    // root module so that a missing source produces the precise
    // `SourceNotFound` error rather than a downstream compilation error.
    {
        const f = cwd.openFile(io, source_path, .{}) catch return error.SourceNotFound;
        defer f.close(io);
    }

    // Pre-validate the output path's parent directory. If the parent
    // does not exist or is not writable, fail fast with a clear
    // diagnostic instead of letting `Compilation.create` fail at link
    // time with a generic "open output binary" error.
    {
        const out_dir = std.fs.path.dirname(out_object_path) orelse ".";
        cwd.access(io, out_dir, .{ .write = true }) catch |err| switch (err) {
            // All `access` failures (permission denied, file not
            // found, name too long, etc.) collapse to
            // `OutputDirInaccessible`. The diagnostic preserves the
            // underlying OS error name (`@errorName(err)`) so callers
            // can still distinguish cases at the message level
            // without us hard-coding a switch over an open-ended
            // platform-error set.
            else => {
                diag.write(
                    "zap_fork: output directory not accessible: {s} ({s})",
                    .{ out_dir, @errorName(err) },
                );
                return error.OutputDirInaccessible;
            },
        };
    }

    const dir_path = std.fs.path.dirname(source_path) orelse ".";
    const file_name = std.fs.path.basename(source_path);

    const root_path = Compilation.Path.fromUnresolved(ar, dirs, &.{dir_path}) catch return error.OutOfMemory;

    const root_mod = Package.Module.create(ar, .{
        .paths = .{
            .root = root_path,
            .root_src_path = try ar.dupe(u8, file_name),
        },
        .fully_qualified_name = "root",
        .cc_argv = &.{},
        .inherited = .{ .resolved_target = resolved_target },
        .global = config,
        .parent = null,
    }) catch return error.OutOfMemory;

    // Pick a stable "root name" derived from the source filename (no
    // extension) so emitted artifacts have a sensible base.
    const root_name = blk: {
        const base = std.fs.path.stem(file_name);
        if (base.len == 0) break :blk "zap_fork_obj";
        break :blk ar.dupe(u8, base) catch return error.OutOfMemory;
    };
    const root_name_z = try ar.dupeZ(u8, root_name);

    var environ_map = std.process.Environ.Map.init(ar);

    const output_path_duped = try ar.dupe(u8, out_object_path);

    var create_diag: Compilation.CreateDiagnostic = undefined;
    var compilation = Compilation.create(gpa, ar, io, &create_diag, .{
        .dirs = dirs,
        .thread_limit = thread_limit,
        .environ_map = &environ_map,
        .self_exe_path = self_exe_path,
        // The running executable is a library embedder (Zap), not the
        // Zig compiler, so LLD must run in-process. Without this, ELF
        // (and any other LLD-driven) targets would re-spawn the
        // embedder as `<self_exe> ld.lld ...`, which has no such
        // subcommand, silently producing no object file.
        .internal_tools_in_process = true,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name_z,
        .cache_mode = .none,
        .emit_bin = .{ .yes_path = output_path_duped },
        // Object output produces nothing that needs compiler_rt / ubsan_rt
        // / libc startup — Zap's final link adds them once across all
        // objects.
        .skip_linker_dependencies = true,
        .entry = .default,
    }) catch |err| switch (err) {
        // `CreateFail` is the carrier for the structured diagnostic;
        // surface the contents of `create_diag` through the caller's
        // buffer rather than burying them in a generic message.
        error.CreateFail => {
            diag.writeCreateDiag(create_diag);
            return error.CreateFailed;
        },
        else => {
            logErr("zap_fork: Compilation.create failed: {s}", .{@errorName(err)});
            return error.CompilationFailed;
        },
    };
    // Compilation.create allocates many resources (bin_file, cache_use,
    // c_object_work_queue, win32_resource_work_queue, windows_libs,
    // crt_files, libcxx/libcxxabi/libunwind/tsan/ubsan_rt/compiler_rt
    // static libs, glibc_so_files, c_object_table, failed_c_objects,
    // win32_resource_table, failed_win32_resources, time_report,
    // link_diags, oneshot_prelink_tasks, misc_failures,
    // cache_parent.manifest_dir) that only `Compilation.destroy()`
    // cleans up. The canonical caller pattern (src/main.zig:3833) uses
    // `defer comp.destroy()`. Match that here.
    defer compilation.destroy();

    // See the matching comment in `zir_compilation_update`. `Progress`
    // is process-global and stateful across calls, but the manager
    // compile is one of two sibling compiles that run inside a single
    // Zap CLI invocation (the second being the user-code compile). The
    // singleton state can only be initialized once per process, so we
    // pass `.none` here and let the host (Zap CLI) own all progress
    // reporting it cares about.
    const prog_node: std.Progress.Node = .none;
    compilation.update(prog_node) catch |err| {
        logErr("zap_fork: compilation.update failed: {s}", .{@errorName(err)});
        var error_bundle = compilation.getAllErrorsAlloc() catch {
            diag.write("zap_fork: compilation.update failed: {s}", .{@errorName(err)});
            return error.CompilationFailed;
        };
        defer error_bundle.deinit(gpa);
        if (error_bundle.errorMessageCount() > 0) {
            diag.writeErrorBundle(error_bundle);
        } else {
            diag.write("zap_fork: compilation.update failed: {s}", .{@errorName(err)});
        }
        return error.CompilationFailed;
    };
    if (compilation.anyErrors()) {
        var error_bundle = compilation.getAllErrorsAlloc() catch {
            diag.write("zap_fork: compilation produced errors (failed to extract bundle)", .{});
            return error.CompilationFailed;
        };
        defer error_bundle.deinit(gpa);
        // Mirror the line ~1053 pattern: if `anyErrors()` returns true
        // but the bundle is empty, the compiler is in an anomalous
        // state — surface that explicitly rather than handing the
        // caller a `CompilationFailed` with an empty diagnostic.
        if (error_bundle.errorMessageCount() > 0) {
            diag.writeErrorBundle(error_bundle);
        } else {
            diag.write("zap_fork: anyErrors() is true but error bundle is empty (compiler is in an anomalous state)", .{});
        }
        return error.CompilationFailed;
    }

    // Post-link artifact verification.
    //
    // `compilation.update()` succeeding and `anyErrors()` being false is
    // NOT sufficient proof that the requested object was actually
    // written. The linker flush path can complete "successfully" yet
    // emit nothing (historically: the LLD relocatable step re-spawned
    // the embedder as `<self_exe> ld.lld ...`, which produced no file;
    // `internal_tools_in_process` now fixes that, but a general post-condition
    // check belongs here regardless of linker path so this primitive
    // can NEVER report `.Ok` without the artifact). If the object is
    // absent or empty, surface a real error instead of silent success.
    {
        const st = cwd.statFile(io, out_object_path, .{}) catch |stat_err| {
            diag.write(
                "zap_fork: compilation reported success but produced no object file at '{s}' ({s}); the requested target may require a linker toolchain this build cannot provide",
                .{ out_object_path, @errorName(stat_err) },
            );
            return error.CompilationFailed;
        };
        if (st.size == 0) {
            diag.write(
                "zap_fork: compilation reported success but produced an empty object file at '{s}'",
                .{out_object_path},
            );
            return error.CompilationFailed;
        }
    }
}

// ---------------------------------------------------------------------------
// Internal: compilation creation
// ---------------------------------------------------------------------------

fn addStructImpl(ctx: *ZirContext, name: []const u8, source_path: []const u8) !void {
    const ar = ctx.arena();

    // Separate directory and filename from the source path.
    const dir_path = std.fs.path.dirname(source_path) orelse ".";
    const file_name = std.fs.path.basename(source_path);

    // Resolve the module root directory.
    const mod_root = Compilation.Path.fromUnresolved(ar, ctx.dirs, &.{dir_path}) catch
        return error.OutOfMemory;

    // Create the Zig module as a child of the root (inherits config).
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

    // Register as a dependency of the root.
    const name_duped = try ar.dupe(u8, name);
    try ctx.root_mod.deps.put(ar, name_duped, mod);

    // Share deps bidirectionally: new struct gets existing deps, existing structs
    // get new struct. This allows cross-struct @import to work between all Zap structs.
    for (ctx.root_mod.deps.keys(), ctx.root_mod.deps.values()) |dep_name, dep_mod| {
        if (dep_mod != mod) {
            // Give new struct access to existing deps
            mod.deps.put(ar, dep_name, dep_mod) catch {};
            // Give existing structs access to new struct
            dep_mod.deps.put(ar, name_duped, mod) catch {};
        }
    }

    // Register the new struct in module_roots so doImport can find its file.
    // We can't re-call populateModuleRootTable because it overwrites existing
    // entries with undefined values. Instead, manually add just this struct.
    const zcu = ctx.compilation.zcu orelse return error.OutOfMemory;
    const gpa = zcu.gpa;

    // Build the path for the new struct's source file.
    const path = try mod.root.join(gpa, ctx.dirs, mod.root_src_path);
    errdefer path.deinit(gpa);

    // Check if this file is already in the import table.
    const gop = try zcu.import_table.getOrPutAdapted(gpa, path, Zcu.ImportTableAdapter{ .zcu = zcu });

    if (gop.found_existing) {
        path.deinit(gpa);
        try zcu.module_roots.put(gpa, mod, gop.key_ptr.*.toOptional());
    } else {
        // Create a new File for this struct.
        const new_file = try gpa.create(Zcu.File);
        const pt: Zcu.PerThread = .activate(zcu, .main);
        defer pt.deactivate();
        const io = ctx.io();
        const new_file_index = try zcu.intern_pool.createFile(gpa, io, pt.tid, .{
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
    // and updateAliveFiles may not run for dynamically-added structs.
    //
    // Per Zcu.zig, `sub_file_path` is documented as `undefined` when
    // `mod == null`. We use `mod == null` as the explicit sentinel
    // rather than reading the undefined slice — the previous code
    // pattern-matched against the debug allocator's fill bytes
    // (0x5555…/0xaaaa…), which is only well-defined under that one
    // allocator configuration. Any other allocator (e.g. release
    // builds, third-party allocators) would leave non-sentinel garbage
    // and silently skip the back-fill, leaving the file unusable.
    for (zcu.module_roots.keys(), zcu.module_roots.values()) |m, opt_file_idx| {
        if (opt_file_idx.unwrap()) |file_idx| {
            const f = zcu.fileByIndex(file_idx);
            if (f.mod == null) {
                f.sub_file_path = m.root_src_path;
                f.mod = m;
            }
        }
    }
}

fn addStructSourceImpl(ctx: *ZirContext, name: []const u8, source: []const u8) !void {
    const ar = ctx.arena();

    // Build a path within the local cache directory for the source file.
    const cache_path = ctx.dirs.local_cache.path orelse return error.OutOfMemory;
    const sub_dir = try std.fmt.allocPrint(ar, "{s}/zap_structs", .{cache_path});
    const file_name = try std.fmt.allocPrint(ar, "{s}.zig", .{name});
    const full_path = try std.fmt.allocPrint(ar, "{s}/{s}", .{ sub_dir, file_name });

    // Ensure the subdirectory exists.
    const io = ctx.io();
    const cwd = Dir.cwd();
    cwd.createDirPath(io, sub_dir) catch |err| {
        logErr("addStructSource: createDirPath failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Write the source to disk.
    {
        var file = cwd.createFile(io, full_path, .{}) catch |err| {
            logErr("addStructSource: createFile failed: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        };
        defer file.close(io);
        file.writeStreamingAll(io, source) catch |err| {
            logErr("addStructSource: writeStreaming failed: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        };
    }

    // Null-terminate the strings for the C-ABI add_struct path.
    const full_path_z = try ar.dupeZ(u8, full_path);

    // Register the struct using the existing addStructImpl.
    try addStructImpl(ctx, name, full_path_z);
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

    const io = ctx.io();
    const cwd_dir = Dir.cwd();
    for (search_dirs) |dir_path| {
        for (exts) |ext| {
            const file_name = std.fmt.allocPrint(ar, "lib{s}{s}", .{ lib_name, ext }) catch continue;
            const full_path = std.fmt.allocPrint(ar, "{s}/{s}", .{ dir_path, file_name }) catch continue;

            var file = cwd_dir.openFile(io, full_path, .{}) catch continue;
            errdefer file.close(io);

            // Found the library — open the containing directory for the Path
            var dir = cwd_dir.openDir(io, dir_path, .{}) catch {
                file.close(io);
                continue;
            };
            errdefer dir.close(io);

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

/// Append a precompiled object file at `obj_path` to the compilation's
/// `link_inputs`. Used by the Memory Manager ABI v1.0 build pipeline to
/// splice a manager `.o` into the final binary link line.
///
/// The path is opened relative to the host's current working directory.
/// On success the `Input.object` entry is added to `link_inputs` and the
/// linker pulls in the object during the final link step. The file handle
/// is held open for the lifetime of the `ZirContext`.
///
/// Returns `error.LinkObjectFileNotReadable` for filesystem failures
/// (missing object, unreadable parent directory). Allocation failures
/// continue to propagate as `error.OutOfMemory`. The two failure modes
/// are distinct because the C-ABI export maps them to different return
/// codes so the Zap-side driver can surface a useful diagnostic.
fn addLinkObjectFileImpl(ctx: *ZirContext, obj_path: []const u8) !void {
    const ar = ctx.arena();
    const io = ctx.io();
    const cwd_dir = Dir.cwd();

    var file = cwd_dir.openFile(io, obj_path, .{}) catch |err| {
        logErr("object file not readable at '{s}': {s}", .{ obj_path, @errorName(err) });
        return error.LinkObjectFileNotReadable;
    };
    // The errdefer below releases `file` if any later step fails;
    // the success path transfers ownership into `ctx.compilation.link_inputs`.
    errdefer file.close(io);

    // Resolve a directory handle for the object's parent dir so the
    // linker can compute paths relative to it. We split on the last
    // separator; if the path is bare (no slash) we fall back to ".".
    const sep_idx = std.mem.lastIndexOfAny(u8, obj_path, "/\\");
    const dir_path: []const u8 = if (sep_idx) |idx| obj_path[0..idx] else ".";
    const sub_path: []const u8 = if (sep_idx) |idx| obj_path[idx + 1 ..] else obj_path;

    // No explicit `file.close` on this error path — the outer
    // `errdefer file.close(io)` above handles cleanup. Issuing a manual
    // close here in addition would double-close the handle.
    var dir = cwd_dir.openDir(io, dir_path, .{}) catch |err| {
        logErr("could not open object's directory '{s}': {s}", .{ dir_path, @errorName(err) });
        return error.LinkObjectFileNotReadable;
    };
    errdefer dir.close(io);

    const cache_path: Cache.Path = .{
        .root_dir = .{ .handle = dir, .path = ar.dupe(u8, dir_path) catch null },
        .sub_path = try ar.dupe(u8, sub_path),
    };

    const old = ctx.compilation.link_inputs;
    const new = try ar.alloc(link.Input, old.len + 1);
    @memcpy(new[0..old.len], old);
    new[old.len] = .{
        .object = .{
            .path = cache_path,
            .file = file,
            // `must_link = true` so the linker pulls in every symbol the
            // manager defines — including `zap_memory_section`, which the
            // runtime bootstrap discovers by walking the linked-in `.zapmem`
            // section. Without `must_link`, an unreferenced compositionally
            // marked symbol could be dropped on systems whose default link
            // policy is `--gc-sections`.
            .must_link = true,
            .hidden = false,
        },
    };
    ctx.compilation.link_inputs = new;
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zir_api: " ++ fmt ++ "\n", args);
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
    target_triple_opt: ?[]const u8,
    cpu_features_opt: ?[]const u8,
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
        .io_impl = undefined,
        .dirs = undefined,
        .compilation = undefined,
        .root_mod = undefined,
    };
    ctx.arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer ctx.arena_state.deinit();
    // Pair with the `arena_state.deinit()` reset on the happy path
    // (`zir_compilation_destroy`). If `createImpl` errors out partway,
    // the static tid pool may already hold a slice into our arena.
    errdefer Zcu.PerThread.Id.deinit();
    const ar = ctx.arena_state.allocator();

    // Initialize the Io.Threaded instance (replaces thread pool in 0.16).
    // `catch 2` (not 1) ensures the subsequent `Io.Limit.limited(N-1)`
    // call always sees a non-zero limit on platforms where `getCpuCount`
    // fails to report. With `catch 1` the limit collapses to
    // `.limited(0)`, which is at best a noop and risks tripping latent
    // assertions downstream.
    const thread_limit = @min(std.Thread.getCpuCount() catch 2, 4);
    ctx.io_impl = .init(gpa, .{
        .stack_size = 16 * 1024 * 1024,
    });
    // Match thread limits to keep InternPool's PerThread happy.
    // Main thread doesn't count, so limit = thread_limit - 1.
    const limit: Io.Limit = .limited(thread_limit - 1);
    ctx.io_impl.setAsyncLimit(limit);
    ctx.io_impl.concurrent_limit = limit;
    // Allocate per-thread IDs for the Zig compiler's concurrent work.
    // Reset first — sibling compiles (e.g. the manager-object compile
    // in `compileToObjectImpl`) may have populated the global pool with
    // a slice into an arena that has since been freed.
    // `compileToObjectImpl` also calls `deinit` on its own exit, but
    // belt-and-braces the reset here so callers in any order are
    // resilient.
    Zcu.PerThread.Id.deinit();
    Zcu.PerThread.Id.allocate(ar, @max(thread_limit, 2)) catch {
        logErr("failed to allocate PerThread IDs", .{});
        return error.OutOfMemory;
    };
    const io = ctx.io();

    // Open directory handles using the Io interface.
    const cwd = Dir.cwd();
    const zig_lib_handle = cwd.openDir(io, zig_lib_dir_path, .{}) catch |err| {
        logErr("openDir(zig_lib={s}) failed: {s}", .{ zig_lib_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };
    const local_cache_handle = cwd.openDir(io, local_cache_dir_path, .{}) catch |err| {
        logErr("openDir(local_cache={s}) failed: {s}", .{ local_cache_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };
    const global_cache_handle = cwd.openDir(io, global_cache_dir_path, .{}) catch |err| {
        logErr("openDir(global_cache={s}) failed: {s}", .{ global_cache_dir_path, @errorName(err) });
        return error.OutOfMemory;
    };

    ctx.dirs = .{
        .cwd = try introspect.getResolvedCwd(io, ar),
        .zig_lib = .{ .handle = zig_lib_handle, .path = try ar.dupe(u8, zig_lib_dir_path) },
        .local_cache = .{ .handle = local_cache_handle, .path = try ar.dupe(u8, local_cache_dir_path) },
        .global_cache = .{ .handle = global_cache_handle, .path = try ar.dupe(u8, global_cache_dir_path) },
    };

    // Target resolution — use explicit triple if provided, otherwise native.
    const arch_os_abi: []const u8 = if (target_triple_opt) |t|
        (if (mem.eql(u8, t, "native")) "native" else t)
    else
        "native";
    // Optional explicit CPU model/feature set (mirrors `zig build`'s
    // `-Dcpu=`). An empty string is treated as "unset" so callers can
    // pass `""` for "the target's default CPU" without a separate
    // sentinel. `std.Target.Query.ParseOptions.cpu_features` already
    // accepts exactly this form (e.g. "baseline", "apple_m1",
    // "x86_64_v3", or "<model>+feat-feat").
    const cpu_features: ?[]const u8 = if (cpu_features_opt) |c|
        (if (c.len == 0) null else c)
    else
        null;
    // Parse the target query GRACEFULLY. The user-binary path must not
    // use `parseTargetQueryOrReportFatalError`/`resolveTargetQueryOrFatal`:
    // those call `std.process.fatal`, aborting the whole Zap process and
    // bypassing Zap's diagnostic + non-zero-exit handling. An invalid
    // `-Dtarget=`/`-Dcpu=` must fail this primitive with a returned
    // error (surfaced as `CompilationCreateFailed`), exactly like the
    // manager-`.o` path, instead of a hard `std.process.fatal`.
    var query_diags: std.Target.Query.ParseOptions.Diagnostics = .{};
    const target_query = std.Target.Query.parse(.{
        .arch_os_abi = arch_os_abi,
        .cpu_features = cpu_features,
        .diagnostics = &query_diags,
    }) catch |parse_err| {
        logErr(
            "zap_fork: invalid target/cpu (target='{s}' cpu='{s}'): {s}",
            .{ arch_os_abi, cpu_features orelse "", @errorName(parse_err) },
        );
        return error.InvalidTargetQuery;
    };
    const resolved_result = std.zig.system.resolveTargetQuery(io, target_query) catch |resolve_err| {
        logErr(
            "zap_fork: unable to resolve target '{s}' (cpu='{s}'): {s}",
            .{ arch_os_abi, cpu_features orelse "", @errorName(resolve_err) },
        );
        return error.InvalidTargetQuery;
    };
    const resolved_target: Package.Module.ResolvedTarget = .{
        .result = resolved_result,
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

    // For WASM targets, disable libc linking (WASI provides its own).
    const effective_link_libc = if (resolved_result.os.tag == .wasi or resolved_result.os.tag == .freestanding)
        false
    else
        do_link_libc;

    // See LTO note on the manager-compile path above; LTO is unavailable
    // on Mach-O through Zig's Config.resolve.
    // Compilation config.
    const config = Compilation.Config.resolve(.{
        .output_mode = output_mode_enum,
        .resolved_target = resolved_target,
        .is_test = false,
        .have_zcu = true,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode_enum,
        .root_strip = true,
        .link_libc = effective_link_libc,
        .link_mode = if (output_mode_enum == .Lib and is_dynamic) .dynamic else null,
        .lto = .none,
        .use_llvm = build_options.have_llvm,
    }) catch |err| {
        logErr("Config.resolve failed: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Root struct.
    //
    // The synthetic root-module stub is written UNDER the caller-supplied
    // local cache directory (`local_cache_dir_path`), never a cwd-relative
    // literal. `Compilation.Path.fromUnresolved` (below) resolves this
    // directory against `dirs.cwd` and prefix-classifies the result
    // against `dirs.local_cache.path` / `dirs.global_cache.path` — which
    // `createImpl` set verbatim from the same C-ABI strings at the
    // `ctx.dirs = .{ ... }` assignment above. Routing the stub under
    // `local_cache_dir_path` therefore makes the stub land *inside* the
    // cache root for BOTH callers, so the resulting `Path` classifies as
    // `.local_cache`/`.global_cache` with a stable, cwd-independent
    // `digest`:
    //
    //   * Manifest path: the caller passes the cwd-relative project cache
    //     dir (`.zap-cache`). `{local_cache}/{root}.zig` is then exactly
    //     `.zap-cache/{root}.zig` — byte-identical to the previous
    //     hardcoded literal, so the on-disk location, the `Path` root
    //     classification, and `Path.digest` are all unchanged.
    //
    //   * Script path: the caller passes a process-private *absolute*
    //     cache dir (under the global script cache). The stub follows
    //     there instead of leaking a `.zap-cache/` directory next to the
    //     user's script, preserving the no-litter invariant.
    //
    // Struct-level imports are unaffected by the stub's directory: each
    // Zap struct module builds its own `Compilation.Path` independently
    // in `addStructImpl` (from the struct's own source dirname, or
    // `dirs.local_cache.path` in `addStructSourceImpl`) and structs are
    // wired through `root_mod.deps`, never via filesystem-relative
    // `@import` against the root stub. The on-disk stub exists only for
    // the root `File`'s identity/digest and `openInfo` readback; its ZIR
    // is injected in-memory in `addZirImpl`.
    const root_name_z = try ar.dupeZ(u8, root_name_str);
    const stub_dir = try std.fs.path.join(ar, &.{ local_cache_dir_path, try std.fmt.allocPrint(ar, "{s}.zig", .{root_name_str}) });
    const stub_src_name = try std.fmt.allocPrint(ar, "{s}.zig", .{root_name_str});

    // Builder mode uses a comptime stub since the entry point is custom (not main).
    // For executables, disable the Io.Threaded vtable to avoid compiling 113
    // unnecessary function pointers (socket, fork, pthread, etc.) that bloat
    // the binary. simple_panic works because ReleaseSmall disables runtime safety.
    const stub_source = if (ctx.is_builder)
        "comptime {}\n"
    else if (output_mode_enum == .Exe)
        "const std = @import(\"std\");\n" ++
            "pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;\n" ++
            "pub const std_options_debug_io: std.Io = std.Io.failing;\n" ++
            "pub const panic = struct {\n" ++
            "    pub fn call(msg: []const u8, _: ?usize) noreturn {\n" ++
            "        _ = std.c.write(2, msg.ptr, msg.len);\n" ++
            "        _ = std.c.write(2, \"\\n\", 1);\n" ++
            "        @trap();\n" ++
            "    }\n" ++
            "    pub fn sentinelMismatch(_: anytype, _: anytype) noreturn { @trap(); }\n" ++
            "    pub fn unwrapError(_: anyerror) noreturn { @trap(); }\n" ++
            "    pub fn outOfBounds(_: usize, _: usize) noreturn { @trap(); }\n" ++
            "    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn { @trap(); }\n" ++
            "    pub fn inactiveUnionField(_: anytype, _: anytype) noreturn { @trap(); }\n" ++
            "    pub fn sliceCastLenRemainder(_: usize) noreturn { @trap(); }\n" ++
            "    pub fn reachedUnreachable() noreturn { @trap(); }\n" ++
            "    pub fn unwrapNull() noreturn { @trap(); }\n" ++
            "    pub fn castToNull() noreturn { @trap(); }\n" ++
            "    pub fn incorrectAlignment() noreturn { @trap(); }\n" ++
            "    pub fn invalidErrorCode() noreturn { @trap(); }\n" ++
            "    pub fn integerOutOfBounds() noreturn { @trap(); }\n" ++
            "    pub fn integerOverflow() noreturn { @trap(); }\n" ++
            "    pub fn shlOverflow() noreturn { @trap(); }\n" ++
            "    pub fn shrOverflow() noreturn { @trap(); }\n" ++
            "    pub fn divideByZero() noreturn { @trap(); }\n" ++
            "    pub fn exactDivisionRemainder() noreturn { @trap(); }\n" ++
            "    pub fn integerPartOutOfBounds() noreturn { @trap(); }\n" ++
            "    pub fn corruptSwitch() noreturn { @trap(); }\n" ++
            "    pub fn shiftRhsTooBig() noreturn { @trap(); }\n" ++
            "    pub fn invalidEnumValue() noreturn { @trap(); }\n" ++
            "    pub fn forLenMismatch() noreturn { @trap(); }\n" ++
            "    pub fn copyLenMismatch() noreturn { @trap(); }\n" ++
            "    pub fn memcpyAlias() noreturn { @trap(); }\n" ++
            "    pub fn noreturnReturned() noreturn { @trap(); }\n" ++
            "};\n" ++
            "pub fn main() void {}\n"
    else
        "comptime {}\n";
    cwd.createDirPath(io, stub_dir) catch {};
    const stub_full = try std.fmt.allocPrint(ar, "{s}/{s}", .{ stub_dir, stub_src_name });
    // Only write stub if content changed (avoids redundant disk I/O on repeated builds)
    const needs_write = blk: {
        const existing = cwd.readFileAlloc(io, stub_full, ar, .limited(512)) catch break :blk true;
        break :blk !mem.eql(u8, existing, stub_source);
    };
    if (needs_write) {
        var file = cwd.createFile(io, stub_full, .{}) catch return error.OutOfMemory;
        defer file.close(io);
        file.writeStreamingAll(io, stub_source) catch return error.OutOfMemory;
    }

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
    // but it needs self_exe_path to find the lib/ directory.
    const self_exe_path: ?[]const u8 = if (build_options.have_llvm)
        (std.process.executablePathAlloc(io, ar) catch null)
    else
        null;

    // Set custom entry point for builder mode.
    const entry: Compilation.CreateOptions.Entry = if (ctx.builder_entry_mangled) |name|
        .{ .named = name }
    else
        .default;

    // Create an environment map for the compilation context.
    var environ_map = std.process.Environ.Map.init(ar);

    var create_diag: Compilation.CreateDiagnostic = undefined;
    ctx.compilation = Compilation.create(gpa, ar, io, &create_diag, .{
        .dirs = ctx.dirs,
        .thread_limit = thread_limit,
        .environ_map = &environ_map,
        .self_exe_path = self_exe_path,
        // The running executable is a library embedder (Zap), not the
        // Zig compiler, so LLD must run in-process. Without this, ELF
        // (and any other LLD-driven) targets would re-spawn the
        // embedder as `<self_exe> ld.lld ...`, which has no such
        // subcommand, silently producing no binary.
        .internal_tools_in_process = true,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name_z,
        .cache_mode = .none,
        .emit_bin = .{ .yes_path = output_path_duped },
        .skip_linker_dependencies = !build_options.have_llvm,
        .entry = entry,
    }) catch |err| {
        logErr("Compilation.create failed: {s}", .{@errorName(err)});
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
        const stub_source = if (ctx.is_builder)
            "comptime {}\n"
        else if (ctx.output_mode == .Exe)
            "const std = @import(\"std\");\n" ++
                "pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;\n" ++
                "pub const std_options_debug_io: std.Io = std.Io.failing;\n" ++
                "pub const panic = struct {\n" ++
                "    pub fn call(msg: []const u8, _: ?usize) noreturn {\n" ++
                "        _ = std.c.write(2, msg.ptr, msg.len);\n" ++
                "        _ = std.c.write(2, \"\\n\", 1);\n" ++
                "        @trap();\n" ++
                "    }\n" ++
                "    pub fn sentinelMismatch(_: anytype, _: anytype) noreturn { @trap(); }\n" ++
                "    pub fn unwrapError(_: anyerror) noreturn { @trap(); }\n" ++
                "    pub fn outOfBounds(_: usize, _: usize) noreturn { @trap(); }\n" ++
                "    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn { @trap(); }\n" ++
                "    pub fn inactiveUnionField(_: anytype, _: anytype) noreturn { @trap(); }\n" ++
                "    pub fn sliceCastLenRemainder(_: usize) noreturn { @trap(); }\n" ++
                "    pub fn reachedUnreachable() noreturn { @trap(); }\n" ++
                "    pub fn unwrapNull() noreturn { @trap(); }\n" ++
                "    pub fn castToNull() noreturn { @trap(); }\n" ++
                "    pub fn incorrectAlignment() noreturn { @trap(); }\n" ++
                "    pub fn invalidErrorCode() noreturn { @trap(); }\n" ++
                "    pub fn integerOutOfBounds() noreturn { @trap(); }\n" ++
                "    pub fn integerOverflow() noreturn { @trap(); }\n" ++
                "    pub fn shlOverflow() noreturn { @trap(); }\n" ++
                "    pub fn shrOverflow() noreturn { @trap(); }\n" ++
                "    pub fn divideByZero() noreturn { @trap(); }\n" ++
                "    pub fn exactDivisionRemainder() noreturn { @trap(); }\n" ++
                "    pub fn integerPartOutOfBounds() noreturn { @trap(); }\n" ++
                "    pub fn corruptSwitch() noreturn { @trap(); }\n" ++
                "    pub fn shiftRhsTooBig() noreturn { @trap(); }\n" ++
                "    pub fn invalidEnumValue() noreturn { @trap(); }\n" ++
                "    pub fn forLenMismatch() noreturn { @trap(); }\n" ++
                "    pub fn copyLenMismatch() noreturn { @trap(); }\n" ++
                "    pub fn memcpyAlias() noreturn { @trap(); }\n" ++
                "    pub fn noreturnReturned() noreturn { @trap(); }\n" ++
                "};\n" ++
                "pub fn main() void {}\n"
        else
            "comptime {}\n";
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

/// Inject finalized ZIR into a NAMED struct (not root).
///
/// If the struct has already been registered via
/// `addStructImpl`/`addStructSourceImpl` (the production Zap driver always
/// does this — it discovers every struct from `program.functions` /
/// `program.type_defs` and calls `zir_compilation_add_struct_source`
/// before `zir_builder_inject_struct`), this attaches the ZIR to the
/// existing struct module.
///
/// If the struct is NOT yet present in `root_mod.deps`, this primitive is
/// now self-completing: it registers the struct into the module /
/// dependency graph itself (the exact module + file + `module_roots` +
/// bidirectional-deps wiring `addStructImpl` performs), then attaches the
/// ZIR. Previously `addZirToStruct` hard-required a *separate* prior
/// `addStruct` call and failed with "struct '<name>' not found in deps"
/// otherwise — the primitive could not introduce a pure-ZIR struct that
/// was reachable only through an `anytype` callback chain when driven
/// directly (no source file on disk). `addStructImpl` performs no
/// filesystem read of its `source_path` (it only builds `Compilation.Path`
/// objects and creates a `Zcu.File` with `.source = null,
/// .status = .never_loaded`; the stub-source / tree / ZIR are filled in
/// below), so reusing it with the canonical synthetic pure-stub path
/// (`<local_cache>/zap_structs/<name>.zig`, the same convention
/// `addStructSourceImpl` uses) is exactly correct for a struct that exists
/// only as injected ZIR. This generalizes to N-struct `anytype` chains:
/// each injected struct self-registers on first injection.
fn addZirToStructImpl(ctx: *ZirContext, name: []const u8, data: *const ZirData) !void {
    const gpa = ctx.gpa;
    const zcu = ctx.compilation.zcu orelse {
        logErr("addZirToStruct: zcu is null", .{});
        return error.OutOfMemory;
    };

    // Find the named struct in root_mod.deps. If it is not registered yet
    // (e.g. a pure-ZIR struct introduced solely via this injection — the
    // bare primitive path, not the production Zap driver path), register
    // it now using the canonical synthetic pure-stub path so the rest of
    // this function can wire its file/ZIR exactly as for a pre-registered
    // struct. This makes the primitive self-completing instead of silently
    // depending on a separate prior `addStruct` call.
    if (!ctx.root_mod.deps.contains(name)) {
        const ar = ctx.arena();
        const cache_path = ctx.dirs.local_cache.path orelse return error.OutOfMemory;
        const synthetic_path = try std.fmt.allocPrintSentinel(
            ar,
            "{s}/zap_structs/{s}.zig",
            .{ cache_path, name },
            0,
        );
        try addStructImpl(ctx, name, synthetic_path);
    }

    const target_mod = ctx.root_mod.deps.get(name) orelse {
        logErr("addZirToStruct: struct '{s}' not found in deps", .{name});
        return error.OutOfMemory;
    };

    // Find its file in module_roots
    const file_opt = zcu.module_roots.get(target_mod) orelse
        return error.OutOfMemory;
    const file_index = file_opt.unwrap() orelse
        return error.OutOfMemory;
    const file = zcu.fileByIndex(file_index);

    // Build ZIR instructions using MultiArrayList
    const inst_len: usize = data.instructions_len;
    var mal: std.MultiArrayList(Zir.Inst) = .{};
    try mal.ensureTotalCapacity(gpa, inst_len);
    mal.len = inst_len;

    const slice = mal.slice();
    const tag_items = slice.items(.tag);
    @memcpy(
        @as([*]u8, @ptrCast(tag_items.ptr))[0..inst_len],
        data.instructions_tags[0..inst_len],
    );
    const data_items = slice.items(.data);
    const data_byte_len = inst_len * @sizeOf(Zir.Inst.Data);
    @memcpy(
        @as([*]u8, @ptrCast(data_items.ptr))[0..data_byte_len],
        data.instructions_data[0..data_byte_len],
    );

    const string_bytes = try gpa.dupe(u8, data.string_bytes[0..data.string_bytes_len]);
    errdefer gpa.free(string_bytes);
    const extra = try gpa.dupe(u32, data.extra[0..data.extra_len]);
    errdefer gpa.free(extra);

    const zir: Zir = .{
        .instructions = slice,
        .string_bytes = string_bytes,
        .extra = extra,
    };

    // Struct stubs always use "comptime {}\n" (not exe mode)
    if (file.source == null) {
        const stub_source = "comptime {}\n";
        const source = try gpa.allocSentinel(u8, stub_source.len, 0);
        @memcpy(source, stub_source);
        file.source = source;
        file.tree = try std.zig.Ast.parse(gpa, source, .zig);
    }

    if (file.zir) |*old_zir| old_zir.deinit(gpa);

    file.zir = zir;
    file.status = .success;
    file.zir_injected = true;

    if (file.mod == null) {
        file.mod = target_mod;
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

/// Configure fields on the file's root struct_decl.
///
/// `name_ptrs[i]` / `name_lens[i]` describe the i-th field's name as a
/// non-null-terminated UTF-8 byte slice. `type_refs[i]` is the
/// `@intFromEnum(Zir.Inst.Ref)` of the field's type (e.g. `i64_type`,
/// or a Ref produced by another builder helper).
///
/// All input arrays must have at least `count` elements. The strings and
/// arrays referenced here are duplicated into builder-owned storage; the
/// caller may free its inputs immediately after this call.
///
/// Calling this with `count == 0` clears any previously configured root
/// fields and restores the legacy decls-only encoding for the root
/// struct_decl.
///
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_root_fields(
    handle: ?*ZirBuilderHandle,
    name_ptrs: [*]const [*]const u8,
    name_lens: [*]const u32,
    type_refs: [*]const u32,
    count: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const gpa = b.gpa;

    if (count == 0) {
        b.setRootFields(&.{}, &.{}) catch return -1;
        return 0;
    }

    const names = gpa.alloc([]const u8, count) catch return -1;
    defer gpa.free(names);
    for (0..count) |i| names[i] = name_ptrs[i][0..name_lens[i]];

    const refs = gpa.alloc(Zir.Inst.Ref, count) catch return -1;
    defer gpa.free(refs);
    for (0..count) |i| refs[i] = @enumFromInt(type_refs[i]);

    b.setRootFields(names, refs) catch return -1;
    return 0;
}

/// Append one root field whose type body is a single static Ref
/// (e.g., a primitive `Zir.Inst.Ref.i64_type`). Streaming-API
/// alternative to the bulk `zir_builder_set_root_fields` for
/// callers that build their field list one entry at a time.
///
/// Multiple calls to the streaming API (this plus the body-recording
/// pair below) accumulate into a single root field list. Mix freely
/// — primitive fields go through this fast path, complex field
/// types (nominal struct, list, map, tuple, …) go through
/// `begin_root_field_body` / `end_root_field_body`.
///
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_root_field_static(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    type_ref: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const name = name_ptr[0..name_len];
    const ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    b.setRootFieldStatic(name, ref) catch return -1;
    return 0;
}

/// Begin recording the type body of a single root field. Pushes a
/// transient `FuncBody` onto the builder so any subsequent
/// `zir_builder_emit_*` calls capture into this field's body
/// instead of failing with "no active body."
///
/// The recorded instructions are emitted into the global ZIR stream
/// as they're called — Sema later analyzes them in the order they
/// appear in the field's body trailer (which is set up by
/// `finalize()`), with the struct_decl's namespace as their lookup
/// scope. That's why `decl_val "Body"` resolves correctly here:
/// the file's root struct owns every nested type decl, and the
/// field body's lookup happens in that scope.
///
/// Caller must finish with `zir_builder_end_root_field_body`.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_begin_root_field_body(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const name = name_ptr[0..name_len];
    _ = b.beginRootFieldBody(name) catch return -1;
    return 0;
}

/// Finish recording a root field's type body. `final_ref` is the
/// Ref that the body produces — the type expression's result, which
/// will become the operand of the synthesized `break_inline` at
/// the end of the field's body.
///
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_end_root_field_body(
    handle: ?*ZirBuilderHandle,
    final_ref: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const ref: Zir.Inst.Ref = @enumFromInt(final_ref);
    b.endRootFieldBody(body, ref) catch return -1;
    return 0;
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

/// Emit a typed integer literal: `@as(dest_type, value)`.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_int_typed(handle: ?*ZirBuilderHandle, value: i64, dest_type: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const int_ref = body.addInt(value) catch return 0xFFFFFFFF;
    const type_ref: Zir.Inst.Ref = @enumFromInt(dest_type);
    const ref = body.addAs(type_ref, int_ref) catch return 0xFFFFFFFF;
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

/// Emit an `unreachable` instruction, marking the current code path as dead.
/// Must be emitted after calls to noreturn functions (e.g., panic) so that
/// Sema and LLVM know the path never continues.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_unreachable(handle: ?*ZirBuilderHandle) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.addUnreachable() catch return -1;
    return 0;
}

/// Emit `@import("struct_name")`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
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
    const ref = body.addFieldPtrLoad(object_ref, field_ptr[0..field_len]) catch return 0xFFFFFFFF;
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

/// Emit optional payload extraction (unsafe, for use after is_non_null check).
pub export fn zir_builder_emit_optional_payload_unsafe(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addOptionalPayloadUnsafe(operand_ref) catch return 0xFFFFFFFF;
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

/// Emit a complete switch_block instruction in a single pass.
///
/// Prong data is packed as sequential entries:
///   [name_ptr, name_len, has_capture, body_insts_len, body_result, body_inst_0, body_inst_1, ...]
///
/// Each prong:
///   - name_ptr/name_len: variant name string (e.g., "Ok", "Error")
///   - has_capture: 1 for payload capture, 0 for none
///   - body_insts_len: number of pre-emitted body instruction indices
///   - body_result: Ref for the prong's result value
///   - body_inst_0..N: the pre-emitted instruction indices
///
/// Returns packed u64: lower 32 = switch_block Ref, upper 32 = switch_block inst index.
/// Body instructions that reference the switch_block Ref get the captured payload.
/// Returns 0xFFFFFFFFFFFFFFFF on error.
pub export fn zir_builder_add_switch_block(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    prong_names_ptrs: [*]const [*]const u8,
    prong_names_lens: [*]const u32,
    prong_captures: [*]const u32,
    prong_body_lens: [*]const u32,
    prong_body_results: [*]const u32,
    prong_body_insts: [*]const u32,
    num_prongs: u32,
) callconv(.c) u64 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFFFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFFFFFFFFFF;
    const gpa = b.gpa;

    const ZirBuilder = @import("zir_builder.zig");
    const prongs = gpa.alloc(ZirBuilder.FuncBody.SwitchProng, num_prongs) catch return 0xFFFFFFFFFFFFFFFF;
    defer gpa.free(prongs);

    var body_offset: u32 = 0;
    for (0..num_prongs) |i| {
        const body_len = prong_body_lens[i];
        prongs[i] = .{
            .item_name = prong_names_ptrs[i][0..prong_names_lens[i]],
            .has_capture = (prong_captures[i] & 1) != 0,
            .body_insts = prong_body_insts[body_offset .. body_offset + body_len],
            .body_result = @enumFromInt(prong_body_results[i]),
            .use_capture_as_result = (prong_captures[i] & 2) != 0,
        };
        body_offset += body_len;
    }

    const ref = body.addSwitchBlock(@enumFromInt(operand), prongs) catch return 0xFFFFFFFFFFFFFFFF;
    const ref_u32: u32 = @intFromEnum(ref);
    // The instruction index is ref minus the Ref.static_len offset
    const inst_idx: u32 = ref_u32 - @as(u32, @intCast(Zir.Inst.Ref.static_len));
    return @as(u64, ref_u32) | (@as(u64, inst_idx) << 32);
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

    // Create a string literal for the field name (Sema expects resolveConstStringIntern)
    const field_name = field_name_ptr[0..field_name_len];
    const field_name_ref = body.addStr(field_name) catch return 0xFFFFFFFF;

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

/// Begin capturing would-be-body instruction indices. Disables body tracking
/// and directs top-level instruction indices into an internal capture buffer.
/// Supports nesting: each begin_capture pushes a new capture level.
/// Call `zir_builder_end_capture` to retrieve the collected indices and
/// restore the previous capture state.
pub export fn zir_builder_begin_capture(
    handle: ?*ZirBuilderHandle,
) callconv(.c) void {
    const b = getBuilder(handle) orelse return;
    const body = b.active_body orelse return;
    if (b.capture_depth >= b.capture_bufs.len) return;
    // Save current state at this depth
    b.capture_saved_tracking[b.capture_depth] = body.body_tracking;
    b.capture_saved_non_body[b.capture_depth] = body.non_body_capture;
    // Start fresh capture at this depth
    b.capture_bufs[b.capture_depth].clearRetainingCapacity();
    body.body_tracking = false;
    body.non_body_capture = &b.capture_bufs[b.capture_depth];
    b.capture_depth += 1;
}

/// End capture mode: restores the previous capture state and returns a
/// pointer to the captured instruction indices. The returned pointer is
/// valid until the next call to `zir_builder_begin_capture` at this depth.
/// `out_len` receives the number of captured indices.
pub export fn zir_builder_end_capture(
    handle: ?*ZirBuilderHandle,
    out_len: *u32,
) callconv(.c) [*]const u32 {
    const b = getBuilder(handle) orelse {
        out_len.* = 0;
        // Return a valid pointer to empty data
        return @as([*]const u32, @ptrCast(&[_]u32{}));
    };
    if (b.capture_depth == 0) {
        out_len.* = 0;
        return @as([*]const u32, @ptrCast(&b.capture_bufs[0].items));
    }
    const body = b.active_body orelse {
        out_len.* = 0;
        b.capture_depth -= 1;
        return b.capture_bufs[b.capture_depth].items.ptr;
    };
    b.capture_depth -= 1;
    // Restore previous capture state
    body.body_tracking = b.capture_saved_tracking[b.capture_depth];
    body.non_body_capture = b.capture_saved_non_body[b.capture_depth];
    out_len.* = @intCast(b.capture_bufs[b.capture_depth].items.len);
    return b.capture_bufs[b.capture_depth].items.ptr;
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

/// Emit a block_inline + condbr_inline with full instruction bodies.
/// The then-branch body should end with a ret instruction (function dispatch).
/// The else-branch body continues execution past the block.
/// Unlike emit_if_else_bodies (which uses runtime block/condbr and requires
/// matching branch result types), this uses inline variants that properly
/// handle branches where one path returns from the function.
pub export fn zir_builder_emit_cond_branch_with_bodies(
    handle: ?*ZirBuilderHandle,
    condition: u32,
    then_insts_ptr: [*]const u32,
    then_insts_len: u32,
    else_insts_ptr: [*]const u32,
    else_insts_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const cond_ref: Zir.Inst.Ref = @enumFromInt(condition);
    body.addCondBranchWithBodies(
        cond_ref,
        then_insts_ptr[0..then_insts_len],
        else_insts_ptr[0..else_insts_len],
    ) catch return -1;
    return 0;
}

/// Return the number of instruction indices currently tracked on the active
/// body. Pairs with `zir_builder_pop_body_inst` to let callers capture a
/// range of instructions (call get_body_inst_count → emit some instructions
/// → call get_body_inst_count again → pop the difference). Used by the Zap
/// frontend to harvest the supporting type-construction instructions for a
/// tuple return type so they can be moved into the function's ret_ty body
/// instead of leaking into the declaration body.
pub export fn zir_builder_get_body_inst_count(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    if (body.body_tracking) {
        return @intCast(body.body_inst_indices.items.len);
    } else if (body.non_body_capture) |capture| {
        return @intCast(capture.items.len);
    }
    return 0;
}

/// Pop the last instruction index from the active instruction list and return it.
/// When body_tracking is active, pops from body_inst_indices.
/// When inside a capture (body_tracking off), pops from the active capture buffer.
/// Used when chaining nested if-else blocks: the inner block must
/// be removed from the current body/capture and placed inside the outer
/// condbr's else branch instead.
/// Returns the popped instruction index, or 0xFFFFFFFF if empty.
pub export fn zir_builder_pop_body_inst(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    if (body.body_tracking) {
        // Normal mode: pop from function body
        if (body.body_inst_indices.items.len == 0) return 0xFFFFFFFF;
        const idx = body.body_inst_indices.items[body.body_inst_indices.items.len - 1];
        body.body_inst_indices.items.len -= 1;
        return idx;
    } else if (body.non_body_capture) |capture| {
        // Capture mode: pop from the active capture buffer
        if (capture.items.len == 0) return 0xFFFFFFFF;
        const idx = capture.items[capture.items.len - 1];
        capture.items.len -= 1;
        return idx;
    }
    return 0xFFFFFFFF;
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

/// Access a tuple/array element by immediate index.
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

/// Emit `operand catch catch_value` — unwrap error union, using catch_value on error.
pub export fn zir_builder_emit_catch(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    catch_value: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const catch_ref: Zir.Inst.Ref = @enumFromInt(catch_value);
    const ref = body.addCatch(operand_ref, catch_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `is_non_err(operand)` — check if an error union is not an error.
/// Returns a bool Ref (true if operand is a success value).
pub export fn zir_builder_emit_is_non_err(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addIsNonErr(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `err_union_payload_unsafe(operand)` — extract the payload from an error union.
/// Only valid when the operand is known to be a success value (not an error).
pub export fn zir_builder_emit_err_union_payload_unsafe(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addErrUnionPayloadUnsafe(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@setRuntimeSafety(enabled)` — controls whether safety checks
/// (overflow, bounds, null) are active in the current scope.
/// Pass bool_true (0x34) for enabled, bool_false (0x35) for disabled.
/// Returns `true` on success, `false` if the builder is unavailable or
/// the instruction failed to emit. (Previously returned u32 with sentinel
/// 0xFFFFFFFF for error, which masqueraded as a Zir.Inst.Ref index and
/// silently broke callers that checked `>= 0`.)
pub export fn zir_builder_emit_set_runtime_safety(
    handle: ?*ZirBuilderHandle,
    enabled: u32,
) callconv(.c) bool {
    const b = getBuilder(handle) orelse return false;
    const body = b.active_body orelse return false;
    const enabled_ref: Zir.Inst.Ref = @enumFromInt(enabled);
    _ = body.emitBodyInst(.set_runtime_safety, .{ .un_node = .{
        .src_node = .zero,
        .operand = enabled_ref,
    } }) catch return false;
    return true;
}

/// Emit an inline if-else expression using block_inline/condbr_inline.
pub export fn zir_builder_emit_if_else_inline(
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
    const ref = body.addIfElseInline(cond_ref, then_ref, else_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Set the call modifier for the next addCall.
/// 0=auto, 2=never_inline, 3=no_optimizations
pub export fn zir_builder_set_call_modifier(
    handle: ?*ZirBuilderHandle,
    modifier: u32,
) callconv(.c) void {
    const b = getBuilder(handle) orelse return;
    const body = b.active_body orelse return;
    body.call_modifier = @intCast(modifier);
}

/// Emit `operand orelse fallback` using inline block/condbr/break.
/// Matches AstGen's exact encoding for the orelse operator.
pub export fn zir_builder_emit_orelse(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    fallback: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const op_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const fb_ref: Zir.Inst.Ref = @enumFromInt(fallback);
    const ref = body.addOrelse(op_ref, fb_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Set the current function's return type to `?T` (optional).
pub export fn zir_builder_set_optional_return_type(
    handle: ?*ZirBuilderHandle,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.setOptionalReturnType() catch return -1;
    return 0;
}

/// Emit `return null` from a function with optional return type.
pub export fn zir_builder_emit_ret_null(
    handle: ?*ZirBuilderHandle,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.addReturnNull() catch return -1;
    return 0;
}

/// Emit `if (condition) return value;` as a bare condbr (no block wrapper).
/// Matches AstGen's encoding for if-statements. Falls through when false.
pub export fn zir_builder_emit_cond_return(
    handle: ?*ZirBuilderHandle,
    condition: u32,
    value: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const cond_ref: Zir.Inst.Ref = @enumFromInt(condition);
    const val_ref: Zir.Inst.Ref = @enumFromInt(value);
    body.addCondReturn(cond_ref, val_ref) catch return -1;
    return 0;
}

/// Emit `return error.<name>` — returns an error value from the current function.
pub export fn zir_builder_emit_ret_error(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const name = name_ptr[0..name_len];
    body.addReturnError(name) catch return -1;
    return 0;
}

/// Set the current function's return type to generic (inferred from body).
/// This allows Zig to deduce error unions from mixed return/error paths.
pub export fn zir_builder_set_generic_return_type(
    handle: ?*ZirBuilderHandle,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.clearReturnTypeState();
    body.is_generic_return = true;
    return 0;
}

/// Set the current function's return type to `anyerror!T` where T is
/// the current return type. Must be called before emitting body instructions.
pub export fn zir_builder_set_error_union_return_type(
    handle: ?*ZirBuilderHandle,
    error_name_ptr: [*]const u8,
    error_name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const name = error_name_ptr[0..error_name_len];
    body.setErrorUnionReturnType(name) catch return -1;
    return 0;
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

/// Emit a tuple_decl WITHOUT appending to any tracked body list. Used by
/// the Zap frontend when constructing nested tuple element types for a
/// return type — the resulting Ref is referenced from a higher-level
/// `tuple_decl` (or supporting-instruction list) that the caller routes
/// into the ret_ty body via `zir_builder_set_tuple_return_type_with_body`.
/// Without this untracked path, the inner tuple_decl ends up in
/// `param_inst_indices` and Sema's generic param-type resolver hits an
/// `unreachable` because the param body now has a `.extended` instruction
/// where it expects only `.param*` tags.
pub export fn zir_builder_emit_tuple_decl_untracked(
    handle: ?*ZirBuilderHandle,
    types_ptr: [*]const u32,
    types_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const gpa = b.gpa;

    const fields_len: u16 = @intCast(types_len);
    const tuple_payload_idx: u32 = @intCast(b.extra.items.len);
    b.extra.append(gpa, 0) catch return 0xFFFFFFFF; // src_node
    for (0..types_len) |i| {
        b.extra.append(gpa, types_ptr[i]) catch return 0xFFFFFFFF;
        b.extra.append(gpa, @intFromEnum(Zir.Inst.Ref.none)) catch return 0xFFFFFFFF;
    }
    const idx = b.addInst(
        .extended,
        zir_builder.Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.tuple_decl), fields_len, tuple_payload_idx),
    ) catch return 0xFFFFFFFF;

    return @intFromEnum(zir_builder.Builder.instRef(idx));
}

/// Get the raw instruction index from a Ref returned by an `emit_*_untracked`
/// function. Lets the frontend collect raw indices for `support_inst_indices`
/// without re-implementing the Ref→index mapping.
pub export fn zir_builder_ref_to_inst_index(_: ?*ZirBuilderHandle, ref: u32) callconv(.c) u32 {
    // Refs above the first-non-builtin threshold encode `inst_index +
    // first_inst_ref`. Use the same conversion as Builder.refToInstIndex.
    const r: Zir.Inst.Ref = @enumFromInt(ref);
    if (r.toIndex()) |i| return @intFromEnum(i);
    return 0xFFFFFFFF;
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

/// Set a tuple return type with supporting instructions in the ret_ty body.
/// `inst_indices_ptr` lists the raw instruction indices that compute the
/// tuple's element type refs (e.g. `import` / `field_val` / `call_ref` /
/// `typeof` chains for `struct_ref` / `map` / `list` / nested-tuple
/// elements). Those instructions must already exist in the active body —
/// the caller is expected to capture them via
/// `zir_builder_get_body_inst_count` + `zir_builder_pop_body_inst`.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_tuple_return_type_with_body(
    handle: ?*ZirBuilderHandle,
    inst_indices_ptr: [*]const u32,
    inst_indices_len: u32,
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

    body.setTupleReturnTypeWithBody(inst_indices_ptr[0..inst_indices_len], refs) catch return -1;
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

// ---------------------------------------------------------------------------
// Type reification C-ABI exports
// ---------------------------------------------------------------------------

/// Emit `@Int(signedness, bit_count)` — create an integer type via type reification.
/// `signedness_ref` is a Ref to a comptime signedness enum value.
/// `bit_count_ref` is a Ref to a comptime u16 bit count value.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_int(
    handle: ?*ZirBuilderHandle,
    signedness_ref: u32,
    bit_count_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const sign_ref: Zir.Inst.Ref = @enumFromInt(signedness_ref);
    const bits_ref: Zir.Inst.Ref = @enumFromInt(bit_count_ref);
    const ref = body.addReifyInt(sign_ref, bits_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@Struct(layout, backing_ty, field_names, field_types, field_attrs)` —
/// create a struct type via type reification.
/// All parameters are Refs to comptime-resolved values:
///   `layout_ref` — container layout enum value
///   `backing_ty_ref` — optional backing integer type (use `none` for no backing type)
///   `field_names_ref` — `[]const []const u8` of field names
///   `field_types_ref` — `[]const type` of field types
///   `field_attrs_ref` — `[]const StructFieldAttrs` of field attributes
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_struct(
    handle: ?*ZirBuilderHandle,
    layout_ref: u32,
    backing_ty_ref: u32,
    field_names_ref: u32,
    field_types_ref: u32,
    field_attrs_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const layout: Zir.Inst.Ref = @enumFromInt(layout_ref);
    const backing_ty: Zir.Inst.Ref = @enumFromInt(backing_ty_ref);
    const field_names: Zir.Inst.Ref = @enumFromInt(field_names_ref);
    const field_types: Zir.Inst.Ref = @enumFromInt(field_types_ref);
    const field_attrs: Zir.Inst.Ref = @enumFromInt(field_attrs_ref);
    const ref = body.addReifyStruct(layout, backing_ty, field_names, field_types, field_attrs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@Enum(tag_ty, mode, field_names, field_values)` —
/// create an enum type via type reification.
/// All parameters are Refs to comptime-resolved values:
///   `tag_ty_ref` — integer tag type
///   `mode_ref` — enum mode value
///   `field_names_ref` — `[]const []const u8` of field names
///   `field_values_ref` — `[]const TagInt` of explicit field values
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_enum(
    handle: ?*ZirBuilderHandle,
    tag_ty_ref: u32,
    mode_ref: u32,
    field_names_ref: u32,
    field_values_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const tag_ty: Zir.Inst.Ref = @enumFromInt(tag_ty_ref);
    const mode: Zir.Inst.Ref = @enumFromInt(mode_ref);
    const field_names: Zir.Inst.Ref = @enumFromInt(field_names_ref);
    const field_values: Zir.Inst.Ref = @enumFromInt(field_values_ref);
    const ref = body.addReifyEnum(tag_ty, mode, field_names, field_values) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@Union(layout, arg_ty, field_names, field_types, field_attrs)` —
/// create a union type via type reification.
/// All parameters are Refs to comptime-resolved values:
///   `layout_ref` — container layout enum value
///   `arg_ty_ref` — optional tag type (use `none` for auto)
///   `field_names_ref` — `[]const []const u8` of field names
///   `field_types_ref` — `[]const type` of field types
///   `field_attrs_ref` — `[]const UnionFieldAttrs` of field attributes
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_union(
    handle: ?*ZirBuilderHandle,
    layout_ref: u32,
    arg_ty_ref: u32,
    field_names_ref: u32,
    field_types_ref: u32,
    field_attrs_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const layout: Zir.Inst.Ref = @enumFromInt(layout_ref);
    const arg_ty: Zir.Inst.Ref = @enumFromInt(arg_ty_ref);
    const field_names: Zir.Inst.Ref = @enumFromInt(field_names_ref);
    const field_types: Zir.Inst.Ref = @enumFromInt(field_types_ref);
    const field_attrs: Zir.Inst.Ref = @enumFromInt(field_attrs_ref);
    const ref = body.addReifyUnion(layout, arg_ty, field_names, field_types, field_attrs) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@Pointer(size, attrs, elem_ty, sentinel)` —
/// create a pointer type via type reification.
/// All parameters are Refs to comptime-resolved values:
///   `size_ref` — pointer size enum value
///   `attrs_ref` — pointer attributes struct value
///   `elem_ty_ref` — element type
///   `sentinel_ref` — sentinel value (use `none` for no sentinel)
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_pointer(
    handle: ?*ZirBuilderHandle,
    size_ref: u32,
    attrs_ref: u32,
    elem_ty_ref: u32,
    sentinel_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const size: Zir.Inst.Ref = @enumFromInt(size_ref);
    const attrs: Zir.Inst.Ref = @enumFromInt(attrs_ref);
    const elem_ty: Zir.Inst.Ref = @enumFromInt(elem_ty_ref);
    const sentinel: Zir.Inst.Ref = @enumFromInt(sentinel_ref);
    const ref = body.addReifyPointer(size, attrs, elem_ty, sentinel) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@Tuple(field_types)` — create a tuple type via type reification.
/// `field_types_ref` is a Ref to a comptime-resolved `[]const type` slice.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_reify_tuple(
    handle: ?*ZirBuilderHandle,
    field_types_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const field_types: Zir.Inst.Ref = @enumFromInt(field_types_ref);
    const ref = body.addReifyTuple(field_types) catch return 0xFFFFFFFF;
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

/// Inject finalized ZIR into a named struct (not root).
/// The struct must have been registered first via zir_compilation_add_struct or
/// zir_compilation_add_struct_source. The builder handle is consumed.
pub export fn zir_builder_inject_struct(
    builder_handle: ?*ZirBuilderHandle,
    compilation_handle: ?*ZirContext,
    struct_name: [*:0]const u8,
) callconv(.c) i32 {
    const b = getBuilder(builder_handle) orelse return -1;
    const ctx = compilation_handle orelse return -1;

    const fzir = b.finalize() catch return -1;
    const zir_data = ZirData{
        .instructions_tags = @constCast(fzir.instructions_tags.ptr),
        .instructions_data = @constCast(fzir.instructions_data.ptr),
        .instructions_len = fzir.instructions_len,
        .string_bytes = @constCast(fzir.string_bytes.ptr),
        .string_bytes_len = fzir.string_bytes_len,
        .extra = @constCast(fzir.extra.ptr),
        .extra_len = fzir.extra_len,
    };
    addZirToStructImpl(ctx, std.mem.sliceTo(struct_name, 0), &zir_data) catch return -1;

    b.deinit();
    std.heap.page_allocator.destroy(b);

    return 0;
}

/// Emit a `decl_ref` instruction that yields a reference to a named declaration.
/// Used to get a function Ref without calling it (for use with call_ref inside branches).
pub export fn zir_builder_emit_decl_ref(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const name = name_ptr[0..name_len];
    const ref = body.addDeclRef(name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

pub export fn zir_builder_emit_decl_val(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const name = name_ptr[0..name_len];
    const ref = body.addDeclVal(name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a `ret_type` instruction that yields the current function's return type.
/// Returns the Ref as u32, or 0 if the function has no union return type.
/// Use this as the type argument to `zir_builder_emit_union_init`.
pub export fn zir_builder_get_union_ret_type_ref(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    if (body.union_ret_type_inst == null) return 0;
    const ref = body.addRetType() catch return 0;
    return @intFromEnum(ref);
}

/// Emit a `ret_type` instruction that yields the current function's tuple return type.
/// Returns the Ref as u32, or 0 if the function has no tuple return type.
/// Use this as the type argument to `zir_builder_emit_struct_init_typed`.
pub export fn zir_builder_get_tuple_ret_type_ref(
    handle: ?*ZirBuilderHandle,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0;
    const body = b.active_body orelse return 0;
    if (body.tuple_ret_type_inst == null) return 0;
    const ref = body.addRetType() catch return 0;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is @import(struct_name).field_name.
/// Returns the param Ref or 0xFFFFFFFF on error.
pub export fn zir_builder_emit_param_imported_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
    struct_name_ptr: [*]const u8,
    struct_name_len: u32,
    field_name_ptr: [*]const u8,
    field_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const param_name = param_name_ptr[0..param_name_len];
    const struct_name = struct_name_ptr[0..struct_name_len];
    const field_name = field_name_ptr[0..field_name_len];
    const ref = body.addParamImportedType(param_name, struct_name, field_name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is the root struct of an imported file —
/// `@import(import_name)` directly, with no nested decl access. The
/// import + break_inline land INSIDE the param's type body so Sema can
/// resolve the break operand against an inst it actually walked.
/// Required for the file-IS-the-struct emission model where the file
/// itself is the canonical type (matches Zig stdlib's `Uri.zig` /
/// `Build.zig` pattern).
pub export fn zir_builder_emit_param_imported_root_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
    import_name_ptr: [*]const u8,
    import_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const param_name = param_name_ptr[0..param_name_len];
    const import_name = import_name_ptr[0..import_name_len];
    const ref = body.addParamImportedRootType(param_name, import_name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is `@This()` — a self-reference to the
/// current file's root struct. Used when a method declared inside a
/// Zap struct takes that struct as a parameter; the file IS the
/// struct, and `@import(self)` is rejected by Zig's build module
/// system, so `@This()` is the canonical self-reference.
pub export fn zir_builder_emit_param_this_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const param_name = param_name_ptr[0..param_name_len];
    const ref = body.addParamThisType(param_name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a type ref for `@This()`.
///
/// Use this when a self type appears inside another type expression
/// that is already being emitted into the correct body, for example a
/// tuple return element.
pub export fn zir_builder_emit_this_type(handle: ?*ZirBuilderHandle) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addThisTypeRef() catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Set the function's return type to `@import(import_name)` — the
/// imported file's root struct directly, with no field access. The
/// file-IS-the-struct counterpart of `set_imported_return_type`.
pub export fn zir_builder_set_imported_root_return_type(
    handle: ?*ZirBuilderHandle,
    import_name_ptr: [*]const u8,
    import_name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const import_name = import_name_ptr[0..import_name_len];
    body.setImportedRootReturnType(import_name) catch return -1;
    return 0;
}

/// Set the function's return type to `@This()` — a self-reference
/// to the current file's root struct. Used when a method returns
/// its own enclosing Zap struct.
pub export fn zir_builder_set_this_return_type(handle: ?*ZirBuilderHandle) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.setThisReturnType() catch return -1;
    return 0;
}

/// Set the current function's return type to @import(struct_name).field_name.
/// Must be called after beginFunction and before body instructions.
pub export fn zir_builder_set_imported_return_type(
    handle: ?*ZirBuilderHandle,
    struct_name_ptr: [*]const u8,
    struct_name_len: u32,
    field_name_ptr: [*]const u8,
    field_name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    const struct_name = struct_name_ptr[0..struct_name_len];
    const field_name = field_name_ptr[0..field_name_len];
    body.setImportedReturnType(struct_name, field_name) catch return -1;
    return 0;
}

/// Emit `?T` (optional type). Returns a Ref for the optional type.
pub export fn zir_builder_emit_optional_type(
    handle: ?*ZirBuilderHandle,
    child_type: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const child_ref: Zir.Inst.Ref = @enumFromInt(child_type);
    const ref = body.addOptionalType(child_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `*const T` — a single-element, immutable, address-space-
/// default pointer with no sentinel or alignment metadata. Used by
/// the Zap recursive-struct storage strategy to break layout
/// cycles: a field declared `:: ?Tree` whose enclosing struct
/// transitively reaches itself is lowered as `?*const Tree`,
/// inserting a hidden pointer indirection that source-level code
/// never sees. Returns a Ref to the pointer type.
pub export fn zir_builder_emit_single_const_ptr_type(
    handle: ?*ZirBuilderHandle,
    pointee: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const pointee_ref: Zir.Inst.Ref = @enumFromInt(pointee);
    const ref = body.addSingleConstPtrType(pointee_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Set the return type from arbitrary ZIR instruction indices.
/// The instructions compute the type (e.g., via generic container instantiation).
/// `result_inst` is the instruction index whose ref is the final type.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_custom_return_type(
    handle: ?*ZirBuilderHandle,
    inst_indices_ptr: [*]const u32,
    inst_indices_len: u32,
    result_inst: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.setCustomReturnType(inst_indices_ptr[0..inst_indices_len], result_inst) catch return -1;
    return 0;
}

/// Emit a short-circuit boolean AND (`bool_br_and`).
/// If `lhs` is true, evaluates the rhs body and returns its result; otherwise
/// returns false.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bool_br_and(
    handle: ?*ZirBuilderHandle,
    lhs: u32,
    rhs_body_ptr: [*]const u32,
    rhs_body_len: u32,
    rhs_result: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_result_ref: Zir.Inst.Ref = @enumFromInt(rhs_result);
    const ref = body.addBoolBrAnd(
        lhs_ref,
        rhs_body_ptr[0..rhs_body_len],
        rhs_result_ref,
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a short-circuit boolean OR (`bool_br_or`).
/// If `lhs` is false, evaluates the rhs body and returns its result; otherwise
/// returns true.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bool_br_or(
    handle: ?*ZirBuilderHandle,
    lhs: u32,
    rhs_body_ptr: [*]const u32,
    rhs_body_len: u32,
    rhs_result: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_result_ref: Zir.Inst.Ref = @enumFromInt(rhs_result);
    const ref = body.addBoolBrOr(
        lhs_ref,
        rhs_body_ptr[0..rhs_body_len],
        rhs_result_ref,
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an `alloc` instruction (immutable allocation of stack space for a type).
/// After storing a value, `zir_builder_emit_make_ptr_const` should be called.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_alloc(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addAlloc(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit an `alloc_mut` instruction (mutable allocation of stack space).
/// Unlike `alloc`, does not require `make_ptr_const` afterward.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_alloc_mut(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addAllocMut(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a `load` instruction: dereference a pointer to get its pointee value.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_load(
    handle: ?*ZirBuilderHandle,
    ptr_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const p_ref: Zir.Inst.Ref = @enumFromInt(ptr_ref);
    const ref = body.addLoad(p_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a `make_ptr_const` instruction: freeze an `alloc` pointer into
/// a constant pointer after the value has been stored.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_make_ptr_const(
    handle: ?*ZirBuilderHandle,
    alloc_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const a_ref: Zir.Inst.Ref = @enumFromInt(alloc_ref);
    const ref = body.addMakePtrConst(a_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a `loop` instruction: an infinite loop containing the given body.
/// The body should include a `repeat` instruction to jump back and a
/// conditional break to exit.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_loop(
    handle: ?*ZirBuilderHandle,
    body_ptr: [*]const u32,
    body_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addLoop(body_ptr[0..body_len]) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a `repeat` instruction: jump back to the beginning of the enclosing
/// `loop` block.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_emit_repeat(
    handle: ?*ZirBuilderHandle,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.addRepeat() catch return -1;
    return 0;
}

// ---------------------------------------------------------------------------
// Math builtins (unary operations on floats)
// ---------------------------------------------------------------------------

/// Emit `@sqrt(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_sqrt(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addSqrt(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@sin(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_sin(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addSin(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@cos(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_cos(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addCos(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@exp(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_exp(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addExp(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@exp2(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_exp2(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addExp2(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@log(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_log(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addLog(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@log2(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_log2(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addLog2(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@log10(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_log10(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addLog10(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@abs(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_abs(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addAbs(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@floor(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_floor(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addFloor(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@ceil(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_ceil(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addCeil(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@round(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_round(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addRound(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@trunc(operand)` (float truncation toward zero).
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_trunc_float(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addTruncFloat(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// Saturating arithmetic (binary operations)
// ---------------------------------------------------------------------------

/// Emit saturating addition (`+|`). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_add_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addAddSat(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit saturating subtraction (`-|`). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_sub_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addSubSat(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit saturating multiplication (`*|`). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_mul_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addMulSat(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit saturating shift-left (`<<|`). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_shl_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addShlSat(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// Overflow-detecting arithmetic (returns struct {result, overflow_bit})
// ---------------------------------------------------------------------------

/// Emit `@addWithOverflow(lhs, rhs)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_add_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addAddWithOverflow(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@subWithOverflow(lhs, rhs)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_sub_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addSubWithOverflow(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@mulWithOverflow(lhs, rhs)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_mul_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const lhs_ref: Zir.Inst.Ref = @enumFromInt(lhs);
    const rhs_ref: Zir.Inst.Ref = @enumFromInt(rhs);
    const ref = body.addMulWithOverflow(lhs_ref, rhs_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// Bit manipulation (unary operations)
// ---------------------------------------------------------------------------

/// Emit `@clz(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_clz(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addClz(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@ctz(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_ctz(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addCtz(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@popCount(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_pop_count(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addPopCount(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@byteSwap(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_byte_swap(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addByteSwap(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@bitReverse(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bit_reverse(handle: ?*ZirBuilderHandle, operand: u32) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addBitReverse(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: SIMD/Vector Operations
// ---------------------------------------------------------------------------

/// Emit `@Vector(len, elem_type)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_vector_type(
    handle: ?*ZirBuilderHandle,
    len: u32,
    elem_type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const len_ref: Zir.Inst.Ref = @enumFromInt(len);
    const elem_ref: Zir.Inst.Ref = @enumFromInt(elem_type_ref);
    const ref = body.addVectorType(len_ref, elem_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@splat(scalar, len)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_splat(
    handle: ?*ZirBuilderHandle,
    scalar: u32,
    len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const len_ref: Zir.Inst.Ref = @enumFromInt(len);
    const scalar_ref: Zir.Inst.Ref = @enumFromInt(scalar);
    const ref = body.addSplat(len_ref, scalar_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@shuffle(a, b, mask)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
/// `a` and `b` are vector operands, `mask` is the shuffle mask.
pub export fn zir_builder_emit_shuffle(
    handle: ?*ZirBuilderHandle,
    a: u32,
    b: u32,
    mask: u32,
) callconv(.c) u32 {
    const b_ = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b_.active_body orelse return 0xFFFFFFFF;
    const a_ref: Zir.Inst.Ref = @enumFromInt(a);
    const b_ref: Zir.Inst.Ref = @enumFromInt(b);
    const mask_ref: Zir.Inst.Ref = @enumFromInt(mask);
    // elem_type is .none — Sema infers it from the operands.
    const ref = body.addShuffle(.none, a_ref, b_ref, mask_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@reduce(operand, operation)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
/// `operation` is an enum value (0=.And, 1=.Or, 2=.Xor, 3=.Min, 4=.Max, 5=.Add, 6=.Mul).
pub export fn zir_builder_emit_reduce(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    operation: u8,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    // The operation is passed as an enum_literal Ref in ZIR's Bin payload.
    const op_name: []const u8 = switch (operation) {
        0 => "And",
        1 => "Or",
        2 => "Xor",
        3 => "Min",
        4 => "Max",
        5 => "Add",
        6 => "Mul",
        else => return 0xFFFFFFFF,
    };
    const op_ref = body.addEnumLiteral(op_name) catch return 0xFFFFFFFF;
    const ref = body.addReduce(op_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Slice Operations
// ---------------------------------------------------------------------------

/// Emit `operand[start..]` (slice with no end). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_slice_start(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    start: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const start_ref: Zir.Inst.Ref = @enumFromInt(start);
    const ref = body.addSliceStart(operand_ref, start_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `operand[start..end]` (slice with end). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_slice_end(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    start: u32,
    end: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const start_ref: Zir.Inst.Ref = @enumFromInt(start);
    const end_ref: Zir.Inst.Ref = @enumFromInt(end);
    const ref = body.addSliceEnd(operand_ref, start_ref, end_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `operand[start..][0..length]` (slice with length). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_slice_length(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    start: u32,
    length: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const start_ref: Zir.Inst.Ref = @enumFromInt(start);
    const length_ref: Zir.Inst.Ref = @enumFromInt(length);
    const ref = body.addSliceLength(operand_ref, start_ref, length_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Error Handling Extensions
// ---------------------------------------------------------------------------

/// Emit `E!T` (error union type). Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_error_union_type(
    handle: ?*ZirBuilderHandle,
    error_set: u32,
    payload: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const error_set_ref: Zir.Inst.Ref = @enumFromInt(error_set);
    const payload_ref: Zir.Inst.Ref = @enumFromInt(payload);
    const ref = body.addErrorUnionType(error_set_ref, payload_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `err_union_code(operand)` — extract error code from error union.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_err_union_code(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addErrUnionCode(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@intFromError(operand)` — convert error to integer.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_int_from_error(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addIntFromError(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@errorFromInt(operand)` — convert integer to error.
/// Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_error_from_int(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addErrorFromInt(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Type Introspection
// ---------------------------------------------------------------------------

/// Emit `@sizeOf(type_ref)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_size_of(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addSizeOf(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@alignOf(type_ref)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_align_of(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addAlignOf(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@bitSizeOf(type_ref)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_bit_size_of(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addBitSizeOf(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@offsetOf(type_ref, field_name)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_offset_of(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
    field_name: [*:0]const u8,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addOffsetOf(t_ref, mem.sliceTo(field_name, 0)) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Type Naming
// ---------------------------------------------------------------------------

/// Emit `@tagName(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_tag_name(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addTagName(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@typeName(type_ref)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_type_name(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addTypeName(t_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Pointer/Int Conversions
// ---------------------------------------------------------------------------

/// Emit `@intFromPtr(operand)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_int_from_ptr(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addIntFromPtr(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@ptrFromInt(operand, type_ref)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_int_from_enum(
    handle: ?*ZirBuilderHandle,
    operand: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addIntFromEnum(operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

pub export fn zir_builder_emit_enum_from_int(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addEnumFromInt(t_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

pub export fn zir_builder_emit_ptr_from_int(
    handle: ?*ZirBuilderHandle,
    operand: u32,
    type_ref: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const operand_ref: Zir.Inst.Ref = @enumFromInt(operand);
    const ref = body.addPtrFromInt(t_ref, operand_ref) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

// ---------------------------------------------------------------------------
// C-ABI exports: Type Checking
// ---------------------------------------------------------------------------

/// Emit `@hasDecl(type_ref, name)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_has_decl(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
    name: [*:0]const u8,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addHasDecl(t_ref, mem.sliceTo(name, 0)) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit `@hasField(type_ref, name)`. Returns `@intFromEnum(Ref)` or `0xFFFFFFFF` on error.
pub export fn zir_builder_emit_has_field(
    handle: ?*ZirBuilderHandle,
    type_ref: u32,
    name: [*:0]const u8,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const t_ref: Zir.Inst.Ref = @enumFromInt(type_ref);
    const ref = body.addHasField(t_ref, mem.sliceTo(name, 0)) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is a named declaration in the current struct.
/// Uses decl_val to reference the type (e.g., a struct type).
/// Returns the param Ref or 0xFFFFFFFF on error.
pub export fn zir_builder_emit_param_decl_val_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
    type_name_ptr: [*]const u8,
    type_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addParamDeclValType(
        param_name_ptr[0..param_name_len],
        type_name_ptr[0..type_name_len],
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is `?T` where `T` is a sibling decl
/// in the current struct (resolved via `decl_val(type_name)`). Used by
/// Zap's `f(nil) / f(t :: T)` optional-dispatch lowering.
pub export fn zir_builder_emit_param_optional_decl_val_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
    type_name_ptr: [*]const u8,
    type_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addParamOptionalDeclValType(
        param_name_ptr[0..param_name_len],
        type_name_ptr[0..type_name_len],
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is `?@This()` — optional of the file's
/// root struct. Companion to `emit_param_optional_decl_val_type` for
/// the case where the optional inner type is the current file itself.
pub export fn zir_builder_emit_param_optional_this_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const ref = body.addParamOptionalThisType(
        param_name_ptr[0..param_name_len],
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Emit a parameter whose type is resolved by an inline type body.
/// `type_body_inst_indices` are raw instruction indices that must all be
/// included in the parameter type body before the final break_inline.
pub export fn zir_builder_emit_param_type_body(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8,
    param_name_len: u32,
    type_body_inst_indices_ptr: [*]const u32,
    type_body_inst_indices_len: u32,
    type_result: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;
    const type_body_inst_indices = type_body_inst_indices_ptr[0..type_body_inst_indices_len];
    const ref = body.addParamTypeBody(
        param_name_ptr[0..param_name_len],
        type_body_inst_indices,
        @enumFromInt(type_result),
    ) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}

/// Set the return type to a named type declared in the current struct.
/// Emits a decl_val instruction for the ret_ty body.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_set_decl_val_return_type(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const body = b.active_body orelse return -1;
    body.setDeclValReturnType(name_ptr[0..name_len]) catch return -1;
    return 0;
}

/// Add a named struct type declaration to the struct.
/// Field names, types, and optional defaults are passed as parallel arrays.
/// Each type is a u32 well-known ZIR Ref (e.g., i64_type).
/// Each default is a u32 ZIR Ref (0 = no default).
/// default_refs may be null if no fields have defaults.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_add_struct_type(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    field_names_ptrs: [*]const [*]const u8,
    field_names_lens: [*]const u32,
    field_type_refs: [*]const u32,
    field_default_refs: ?[*]const u32,
    fields_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const gpa = b.gpa;

    const name = name_ptr[0..name_len];

    const names = gpa.alloc([]const u8, fields_len) catch return -1;
    defer gpa.free(names);
    for (0..fields_len) |i| {
        names[i] = field_names_ptrs[i][0..field_names_lens[i]];
    }

    const type_refs = gpa.alloc(Zir.Inst.Ref, fields_len) catch return -1;
    defer gpa.free(type_refs);
    for (0..fields_len) |i| {
        type_refs[i] = @enumFromInt(field_type_refs[i]);
    }

    const defaults: ?[]const Zir.Inst.Ref = if (field_default_refs) |d| blk: {
        const defs = gpa.alloc(Zir.Inst.Ref, fields_len) catch return -1;
        for (0..fields_len) |i| {
            defs[i] = @enumFromInt(d[i]);
        }
        break :blk defs;
    } else null;
    defer if (defaults) |d| gpa.free(d);

    b.addStructTypeDecl(name, names, type_refs, defaults) catch return -1;
    return 0;
}

/// Begin a struct declaration scope with fields. Between this call and
/// the matching `zir_builder_end_struct_decl`, any functions emitted via
/// `zir_builder_begin_func`/`zir_builder_end_func` become declarations
/// (methods) of the struct rather than of the parent scope.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_begin_struct_decl(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    field_name_ptrs: [*]const [*]const u8,
    field_name_lens: [*]const u32,
    field_type_refs: [*]const u32,
    field_count: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const gpa = b.gpa;

    const name = name_ptr[0..name_len];

    const names = gpa.alloc([]const u8, field_count) catch return -1;
    defer gpa.free(names);
    for (0..field_count) |i| {
        names[i] = field_name_ptrs[i][0..field_name_lens[i]];
    }

    const type_refs = gpa.alloc(Zir.Inst.Ref, field_count) catch return -1;
    defer gpa.free(type_refs);
    for (0..field_count) |i| {
        type_refs[i] = @enumFromInt(field_type_refs[i]);
    }

    b.beginStructDecl(name, names, type_refs, field_count) catch return -1;
    return 0;
}

/// End a struct declaration scope. Emits the struct_decl instruction with
/// both fields and any function declarations emitted since the matching
/// `zir_builder_begin_struct_decl`. Restores the parent scope.
/// Returns 0 on success, -1 on error.
pub export fn zir_builder_end_struct_decl(handle: ?*ZirBuilderHandle) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    b.endStructDecl() catch return -1;
    return 0;
}

pub export fn zir_builder_add_enum_type(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
    variant_names_ptrs: [*]const [*]const u8,
    variant_names_lens: [*]const u32,
    variants_len: u32,
) callconv(.c) i32 {
    const b = getBuilder(handle) orelse return -1;
    const gpa = b.gpa;

    const name = name_ptr[0..name_len];

    const names = gpa.alloc([]const u8, variants_len) catch return -1;
    defer gpa.free(names);
    for (0..variants_len) |i| {
        names[i] = variant_names_ptrs[i][0..variant_names_lens[i]];
    }

    b.addEnumTypeDecl(name, names) catch return -1;
    return 0;
}

fn injectStructZir(ctx: *ZirContext, name: []const u8, fzir: zir_builder.FinalizedZir) !void {
    const data = ZirData{
        .instructions_tags = @constCast(fzir.instructions_tags.ptr),
        .instructions_data = @constCast(fzir.instructions_data.ptr),
        .instructions_len = fzir.instructions_len,
        .string_bytes = @constCast(fzir.string_bytes.ptr),
        .string_bytes_len = fzir.string_bytes_len,
        .extra = @constCast(fzir.extra.ptr),
        .extra_len = fzir.extra_len,
    };
    try addZirToStructImpl(ctx, name, &data);
}

/// Resolve the repo `lib/` directory for tests. MUST return the
/// sentinel-inclusive `[:0]u8` that `realPathFileAlloc` actually
/// allocates (`dupeZ` allocates `len+1` bytes for the trailing NUL).
/// Returning a plain `[]u8` here silently dropped the sentinel from
/// the type, so callers' `allocator.free(...)` reported the slice
/// length (`n`) as the free size while the allocation was `n+1` —
/// tripping the DebugAllocator "Allocation size N does not match free
/// size N-1" check in every test that resolved the lib dir. Keeping
/// the `[:0]u8` type lets `free` see the true allocation size.
fn testRepoLibDir(allocator: Allocator, io: Io) ![:0]u8 {
    const cwd = Dir.cwd();
    return cwd.realPathFileAlloc(io, "lib", allocator) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const src_dir = std.fs.path.dirname(@src().file) orelse break :blk error.FileNotFound;
            const lib_path = try std.fs.path.join(allocator, &.{ src_dir, "..", "lib" });
            defer allocator.free(lib_path);
            break :blk cwd.realPathFileAlloc(io, lib_path, allocator);
        },
        else => err,
    };
}

fn testExpectSegmentVmaddrOrder(file_path: []const u8, allocator: Allocator) !void {
    const cwd = Dir.cwd();
    const io = std.testing.io;
    const bytes = try cwd.readFileAlloc(io, file_path, allocator, .limited(16 * 1024 * 1024));
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
    const io = std.testing.io;
    const cwd = Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "local-cache");
    try tmp.dir.createDirPath(io, "global-cache");

    const zig_lib_dir = try testRepoLibDir(allocator, io);
    defer allocator.free(zig_lib_dir);

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Change to temp dir for the test, restore on exit.
    const tmp_dir = try cwd.openDir(io, tmp_path, .{});
    const orig_dir = try cwd.openDir(io, ".", .{});
    try std.process.setCurrentDir(io, tmp_dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

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
        null,
        null,
    );
    defer zir_compilation_destroy(ctx);

    try addStructSourceImpl(ctx, "zap_runtime", "pub fn noop() void {}\n");

    var builder = try zir_builder.Builder.init(allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("main", .void);
    try builder.endFunction(body);

    const fzir = try builder.finalize();
    try addZirFromFinalized(ctx, fzir);

    try std.testing.expectEqual(@as(i32, 0), zir_compilation_update(ctx));

    const file = try cwd.openFile(io, output_path, .{});
    defer file.close(io);

    try testExpectSegmentVmaddrOrder(output_path, allocator);
}

test "zir_api: function value passed as callback argument" {
    // Replicates the Zap pattern: apply(41, add_one) where add_one is
    // passed as a function value callback.
    //
    // Equivalent Zig:
    //   fn add_one(x: i64) i64 { return x + 1; }
    //   fn apply(value: i64, callback: anytype) i64 { return callback(value); }
    //   pub fn main() void { _ = apply(41, add_one); }

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "local-cache");
    try tmp.dir.createDirPath(io, "global-cache");

    const zig_lib_dir = try testRepoLibDir(allocator, io);
    defer allocator.free(zig_lib_dir);

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const tmp_dir = try cwd.openDir(io, tmp_path, .{});
    const orig_dir = try cwd.openDir(io, ".", .{});
    try std.process.setCurrentDir(io, tmp_dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    const local_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "local-cache" });
    defer allocator.free(local_cache_dir);
    const global_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "global-cache" });
    defer allocator.free(global_cache_dir);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "callback-test" });
    defer allocator.free(output_path);

    const ctx = try createImpl(
        zig_lib_dir,
        local_cache_dir,
        global_cache_dir,
        output_path,
        "callback_test",
        0, // exe
        0, // debug
        false,
        true,
        null,
        null,
    );
    defer zir_compilation_destroy(ctx);

    // No runtime needed for this test.
    try addStructSourceImpl(ctx, "zap_runtime", "pub fn noop() void {}\n");

    var builder = try zir_builder.Builder.init(allocator);
    defer builder.deinit();

    // --- fn add_one(x: i64) i64 { return x + 1; }
    {
        const body = try builder.beginFunction("add_one", .i64_type);
        const param_x = try body.addParam("x", .i64_type);
        const one = try body.addInt(1);
        const result = try body.addBinOp(.add, param_x, one);
        try body.addRetNode(result);
        try builder.endFunction(body);
    }

    // --- fn apply(value: i64, callback: anytype) i64 { return callback(value); }
    {
        const body = try builder.beginFunction("apply", .i64_type);
        const param_value = try body.addParam("value", .i64_type);
        const param_callback = try body.addParam("callback", .none); // anytype
        const result = try body.addCallRef(param_callback, &.{param_value});
        try body.addRetNode(result);
        try builder.endFunction(body);
    }

    // --- pub fn main() void { _ = apply(41, add_one); }
    {
        const body = try builder.beginFunction("main", .void);
        const forty_one = try body.addInt(41);
        const add_one_ref = try body.addDeclVal("add_one");
        _ = try body.addCall("apply", &.{ forty_one, add_one_ref });
        try body.addRetImplicit();
        try builder.endFunction(body);
    }

    const fzir = try builder.finalize();
    try addZirFromFinalized(ctx, fzir);

    // The key assertion: compilation should succeed with no errors.
    // If function values are handled correctly, Zig's Sema will
    // monomorphize callback:anytype to *const fn(i64) i64 and
    // the call_ref inside apply will work.
    try std.testing.expectEqual(@as(i32, 0), zir_compilation_update(ctx));
}

test "zir_api: cross-struct callback via anytype" {
    // Replicates the Zap test failure: Struct A has apply(value, callback:anytype),
    // Struct B calls A.apply(41, add_one) where add_one is in Struct B.
    // This tests whether anytype monomorphization works across injected ZIR structs.

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "local-cache");
    try tmp.dir.createDirPath(io, "global-cache");

    const zig_lib_dir = try testRepoLibDir(allocator, io);
    defer allocator.free(zig_lib_dir);

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const tmp_dir = try cwd.openDir(io, tmp_path, .{});
    const orig_dir = try cwd.openDir(io, ".", .{});
    try std.process.setCurrentDir(io, tmp_dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    const local_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "local-cache" });
    defer allocator.free(local_cache_dir);
    const global_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "global-cache" });
    defer allocator.free(global_cache_dir);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "cross-callback-test" });
    defer allocator.free(output_path);

    const ctx = try createImpl(
        zig_lib_dir,
        local_cache_dir,
        global_cache_dir,
        output_path,
        "cross_callback_test",
        0,
        0,
        false,
        true,
        null,
        null,
    );
    defer zir_compilation_destroy(ctx);

    try addStructSourceImpl(ctx, "zap_runtime", "pub fn noop() void {}\n");

    // --- Struct "Helper": has apply(value, callback: anytype) ---
    {
        var builder = try zir_builder.Builder.init(allocator);

        const body = try builder.beginFunction("apply", .i64_type);
        const param_value = try body.addParam("value", .i64_type);
        const param_callback = try body.addParam("callback", .none); // anytype
        const result = try body.addCallRef(param_callback, &.{param_value});
        try body.addRetNode(result);
        try builder.endFunction(body);

        const fzir = try builder.finalize();
        try injectStructZir(ctx, "Helper", fzir);
        builder.deinit();
    }

    // --- Root struct: calls @import("Helper").apply(41, add_one) ---
    {
        var builder = try zir_builder.Builder.init(allocator);

        // fn add_one(x: i64) i64 { return x + 1; }
        const add_one_body = try builder.beginFunction("add_one", .i64_type);
        const param_x = try add_one_body.addParam("x", .i64_type);
        const one = try add_one_body.addInt(1);
        const sum = try add_one_body.addBinOp(.add, param_x, one);
        try add_one_body.addRetNode(sum);
        try builder.endFunction(add_one_body);

        // pub fn main() void {
        //     const add_one_ref = @declRef("add_one");
        //     _ = @import("Helper").apply(41, add_one_ref);
        // }
        const main_body = try builder.beginFunction("main", .void);
        const forty_one = try main_body.addInt(41);
        const add_one_ref = try main_body.addDeclVal("add_one");

        // @import("Helper").apply(41, add_one_ref)
        const helper_import = try main_body.addImport("Helper");
        const apply_ref = try main_body.addFieldPtrLoad(helper_import, "apply");
        _ = try main_body.addCallRef(apply_ref, &.{ forty_one, add_one_ref });
        try main_body.addRetImplicit();
        try builder.endFunction(main_body);

        const fzir = try builder.finalize();
        try addZirFromFinalized(ctx, fzir);
        builder.deinit();
    }

    // If cross-struct anytype monomorphization works, this succeeds.
    // If it fails, the callback parameter in Helper.apply resolves to void.
    const update_result = zir_compilation_update(ctx);
    if (update_result != 0) {
        zir_compilation_print_errors(ctx);
    }
    try std.testing.expectEqual(@as(i32, 0), update_result);
}

test "zir_api: three-struct anytype chain (caller -> wrapper -> inner)" {
    // Replicates the Zap failure: caller -> Enum.map(callback:anytype) -> runtime.mapFn(callback:anytype)
    // Three separate ZIR structs where anytype must propagate through two struct boundaries.

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "local-cache");
    try tmp.dir.createDirPath(io, "global-cache");

    const zig_lib_dir = try testRepoLibDir(allocator, io);
    defer allocator.free(zig_lib_dir);

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const tmp_dir = try cwd.openDir(io, tmp_path, .{});
    const orig_dir = try cwd.openDir(io, ".", .{});
    try std.process.setCurrentDir(io, tmp_dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    const local_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "local-cache" });
    defer allocator.free(local_cache_dir);
    const global_cache_dir = try std.fs.path.join(allocator, &.{ tmp_path, "global-cache" });
    defer allocator.free(global_cache_dir);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "three-chain-test" });
    defer allocator.free(output_path);

    const ctx = try createImpl(
        zig_lib_dir,
        local_cache_dir,
        global_cache_dir,
        output_path,
        "three_chain_test",
        0,
        0,
        false,
        true,
        null,
        null,
    );
    defer zir_compilation_destroy(ctx);

    try addStructSourceImpl(ctx, "zap_runtime", "pub fn noop() void {}\n");

    // --- Struct "Inner": has invoke(value: i64, callback: anytype) -> i64
    {
        var builder = try zir_builder.Builder.init(allocator);
        const body = try builder.beginFunction("invoke", .i64_type);
        const param_value = try body.addParam("value", .i64_type);
        const param_callback = try body.addParam("callback", .none); // anytype
        const result = try body.addCallRef(param_callback, &.{param_value});
        try body.addRetNode(result);
        try builder.endFunction(body);
        const fzir = try builder.finalize();
        try injectStructZir(ctx, "Inner", fzir);
        builder.deinit();
    }

    // --- Struct "Wrapper": has wrap(value: i64, callback: anytype) -> i64
    //     calls @import("Inner").invoke(value, callback)
    {
        var builder = try zir_builder.Builder.init(allocator);
        const body = try builder.beginFunction("wrap", .i64_type);
        const param_value = try body.addParam("value", .i64_type);
        const param_callback = try body.addParam("callback", .none); // anytype
        // @import("Inner").invoke(value, callback)
        const inner_import = try body.addImport("Inner");
        const invoke_ref = try body.addFieldPtrLoad(inner_import, "invoke");
        const result = try body.addCallRef(invoke_ref, &.{ param_value, param_callback });
        try body.addRetNode(result);
        try builder.endFunction(body);
        const fzir = try builder.finalize();
        try injectStructZir(ctx, "Wrapper", fzir);
        builder.deinit();
    }

    // --- Root struct: calls @import("Wrapper").wrap(41, add_one)
    {
        var builder = try zir_builder.Builder.init(allocator);

        const add_one_body = try builder.beginFunction("add_one", .i64_type);
        const param_x = try add_one_body.addParam("x", .i64_type);
        const one = try add_one_body.addInt(1);
        const sum = try add_one_body.addBinOp(.add, param_x, one);
        try add_one_body.addRetNode(sum);
        try builder.endFunction(add_one_body);

        const main_body = try builder.beginFunction("main", .void);
        const forty_one = try main_body.addInt(41);
        const add_one_ref = try main_body.addDeclVal("add_one");
        const wrapper_import = try main_body.addImport("Wrapper");
        const wrap_ref = try main_body.addFieldPtrLoad(wrapper_import, "wrap");
        _ = try main_body.addCallRef(wrap_ref, &.{ forty_one, add_one_ref });
        try main_body.addRetImplicit();
        try builder.endFunction(main_body);

        const fzir = try builder.finalize();
        try addZirFromFinalized(ctx, fzir);
        builder.deinit();
    }

    const update_result = zir_compilation_update(ctx);
    if (update_result != 0) {
        zir_compilation_print_errors(ctx);
    }
    try std.testing.expectEqual(@as(i32, 0), update_result);
}
