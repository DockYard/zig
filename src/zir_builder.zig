const std = @import("std");
const Zir = std.zig.Zir;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// Numeric field names for tuple struct fields ("0", "1", "2", ...).
const index_field_names = [_][]const u8{
    "0", "1", "2",  "3",  "4",  "5",  "6",  "7",
    "8", "9", "10", "11", "12", "13", "14", "15",
};

pub const Builder = struct {
    gpa: Allocator,
    tags: std.ArrayListUnmanaged(u8),
    data: std.ArrayListUnmanaged(Zir.Inst.Data),
    extra: std.ArrayListUnmanaged(u32),
    string_bytes: std.ArrayListUnmanaged(u8),

    /// Indices of declaration instructions for the root struct_decl
    decl_indices: std.ArrayListUnmanaged(u32),

    /// Active function body, if any
    active_body: ?*FuncBody,

    /// Nestable capture stack used by begin_capture / end_capture.
    /// Supports nested case/cond expressions that require inner captures
    /// while an outer capture is still active.
    capture_bufs: [16]std.ArrayListUnmanaged(u32) = [_]std.ArrayListUnmanaged(u32){.empty} ** 16,
    capture_saved_tracking: [16]bool = [_]bool{true} ** 16,
    capture_saved_non_body: [16]?*std.ArrayListUnmanaged(u32) = [_]?*std.ArrayListUnmanaged(u32){null} ** 16,
    capture_depth: u32 = 0,

    pub fn init(gpa: Allocator) !Builder {
        var self = Builder{
            .gpa = gpa,
            .tags = .empty,
            .data = .empty,
            .extra = .empty,
            .string_bytes = .empty,
            .decl_indices = .empty,
            .active_body = null,
        };

        // Reserve extra[0..1] for compile_errors and imports
        try self.extra.append(gpa, 0); // compile_errors
        try self.extra.append(gpa, 0); // imports

        // Reserve string_bytes[0] as sentinel
        try self.string_bytes.append(gpa, 0);

        // Emit placeholder instruction 0: extended(struct_decl)
        // Will be fixed up in finalize()
        try self.tags.append(gpa, @intFromEnum(Zir.Inst.Tag.extended));
        try self.data.append(gpa, encodeExtended(0, 0, 0));

        return self;
    }

    pub fn deinit(self: *Builder) void {
        self.tags.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.string_bytes.deinit(self.gpa);
        self.decl_indices.deinit(self.gpa);
        for (&self.capture_bufs) |*buf| {
            buf.deinit(self.gpa);
        }
        if (self.active_body) |body| {
            body.body_inst_indices.deinit(self.gpa);
            body.param_inst_indices.deinit(self.gpa);
            self.gpa.destroy(body);
        }
    }

    /// Intern a null-terminated string in string_bytes. Returns the index.
    pub fn internString(self: *Builder, str: []const u8) !u32 {
        const start: u32 = @intCast(self.string_bytes.items.len);
        try self.string_bytes.appendSlice(self.gpa, str);
        try self.string_bytes.append(self.gpa, 0);
        return start;
    }

    /// Convert an instruction index to a Zir.Inst.Ref.
    /// Named refs (void_value, bool_true, etc.) occupy indices 0..123.
    /// Instruction refs are offset by Ref.static_len from instruction indices.
    pub fn instRef(index: u32) Zir.Inst.Ref {
        return @enumFromInt(@as(u32, @intCast(Zir.Inst.Ref.static_len)) + index);
    }

    /// Append a single instruction, return its index.
    pub fn addInst(self: *Builder, tag: Zir.Inst.Tag, inst_data: Zir.Inst.Data) !u32 {
        const index: u32 = @intCast(self.tags.items.len);
        try self.tags.append(self.gpa, @intFromEnum(tag));
        try self.data.append(self.gpa, inst_data);
        return index;
    }

    /// Append one u32 to extra, return its index.
    pub fn addExtra(self: *Builder, value: u32) !u32 {
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.append(self.gpa, value);
        return index;
    }

    /// Append a slice of u32 to extra, return the start index.
    pub fn addExtraSlice(self: *Builder, values: []const u32) !u32 {
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.gpa, values);
        return index;
    }

    /// Begin building a function. Returns a FuncBody for adding body instructions.
    ///
    /// The approach: we emit the declaration instruction immediately as a placeholder,
    /// then emit restore_err_ret_index_unconditional. Body instructions are emitted
    /// eagerly into the builder's instruction arrays so that we can return valid Refs.
    /// endFunction then emits func, break_inline, and the extra payloads.
    pub fn beginFunction(self: *Builder, name: []const u8, ret_type: ReturnType) !*FuncBody {
        std.debug.assert(self.active_body == null);

        // Emit placeholder declaration instruction (fix up in endFunction)
        const decl_inst = try self.addInst(.declaration, encodeDeclaration(0, 0));

        // Emit restore_err_ret_index_unconditional as first body instruction
        const restore_inst = try self.addInst(
            .restore_err_ret_index_unconditional,
            encodeUnNode(.zero, .void_value),
        );

        const body = try self.gpa.create(FuncBody);
        body.* = FuncBody{
            .builder = self,
            .body_inst_indices = .empty,
            .param_inst_indices = .empty,
            .name = name,
            .decl_inst = decl_inst,
            .restore_inst = restore_inst,
            .has_explicit_return = false,
            .ret_type = ret_type,
        };

        // Track restore_err_ret as first body instruction
        try body.body_inst_indices.append(self.gpa, restore_inst);

        self.active_body = body;
        return body;
    }

    /// End building a function. Emits func, break_inline, and all extra payloads.
    pub fn endFunction(self: *Builder, body: *FuncBody) !void {
        std.debug.assert(self.active_body == body);

        const decl_inst = body.decl_inst;

        // If no explicit return was added, emit ret_implicit
        if (!body.has_explicit_return) {
            const ret_inst = try self.addInst(.ret_implicit, encodeUnTok(.zero, .void_value));
            try body.body_inst_indices.append(self.gpa, ret_inst);
        }

        const body_len: u32 = @intCast(body.body_inst_indices.items.len);

        // For union return types, we need to emit a ret_ty body containing
        // [union_decl, break_inline(func, union_decl)]. The break_inline
        // targets the func instruction, so we must predict the func index.
        // We emit the break_inline instruction FIRST, then build the func
        // payload referencing both instructions in the ret_ty body.
        var ret_break_inline_idx: u32 = undefined;
        if (body.error_union_ret_type_inst) |eu_inst_idx| {
            // Same pattern as union return type: emit break_inline for ret_ty body
            ret_break_inline_idx = @intCast(self.tags.items.len);
            const func_inst_predicted: u32 = ret_break_inline_idx + 1;

            const brk_payload_idx: u32 = @intCast(self.extra.items.len);
            try self.extra.append(self.gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
            try self.extra.append(self.gpa, func_inst_predicted);

            const eu_ref = instRef(eu_inst_idx);
            _ = try self.addInst(.break_inline, encodeBreak(eu_ref, brk_payload_idx));
        } else if (body.imported_ret_type_inst) |imported_inst_idx| {
            ret_break_inline_idx = @intCast(self.tags.items.len);
            const func_inst_predicted: u32 = ret_break_inline_idx + 1;

            const brk_payload_idx: u32 = @intCast(self.extra.items.len);
            try self.extra.append(self.gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
            try self.extra.append(self.gpa, func_inst_predicted);

            const imported_ref = instRef(imported_inst_idx);
            _ = try self.addInst(.break_inline, encodeBreak(imported_ref, brk_payload_idx));
        } else if (body.union_ret_type_inst) |union_decl_idx| {
            // The next instruction we emit is the break_inline for ret_ty body.
            // After that comes the func instruction.
            ret_break_inline_idx = @intCast(self.tags.items.len);
            const func_inst_predicted: u32 = ret_break_inline_idx + 1;

            // Break payload: { operand_src_node: none, block_inst: func_inst }
            const brk_payload_idx: u32 = @intCast(self.extra.items.len);
            try self.extra.append(self.gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
            try self.extra.append(self.gpa, func_inst_predicted); // block_inst = func instruction

            // Emit break_inline: operand = union_decl Ref, payload = break payload
            const union_decl_ref = instRef(union_decl_idx);
            _ = try self.addInst(.break_inline, encodeBreak(union_decl_ref, brk_payload_idx));
        }

        // Build Func payload in extra
        // Func struct: ret_ty (u32), param_block (Index), body_len (u32)
        // Trailing: [return type body or Ref], body indices, SrcLocs (3 u32s), proto_hash (4 u32s)
        const func_payload_idx: u32 = @intCast(self.extra.items.len);

        // ret_ty: packed RetTy { body_len: u31, is_generic: bool }
        if (body.is_generic_return) {
            // is_generic=true, body_len=0 → Zig infers return type from body
            try self.extra.append(self.gpa, @as(u32, 1) << 31); // is_generic bit set, body_len=0
        } else if (body.error_union_ret_type_inst != null) {
            // ret_ty body has 2 instructions: [error_union_type, break_inline(func, error_union_type)]
            try self.extra.append(self.gpa, 2);
        } else if (body.imported_ret_type_inst != null) {
            // ret_ty body has 3 instructions: [import, field_ptr_load, break_inline]
            try self.extra.append(self.gpa, 3);
        } else if (body.union_ret_type_inst != null) {
            // ret_ty body has 2 instructions: [union_decl, break_inline(func, union_decl)]
            try self.extra.append(self.gpa, 2);
        } else if (body.tuple_ret_types.items.len > 0) {
            // body_len=1 with the tuple_decl instruction Ref
            try self.extra.append(self.gpa, 1);
        } else if (body.ret_type == .void) {
            // body_len=0 means void, is_generic=false → u32 value 0
            try self.extra.append(self.gpa, 0);
        } else {
            // body_len=1 means simple Ref, is_generic=false → u32 value 1
            try self.extra.append(self.gpa, 1);
        }
        // param_block: the declaration instruction
        try self.extra.append(self.gpa, decl_inst);
        // body_len
        try self.extra.append(self.gpa, body_len);

        // Trailing return type body or Ref
        if (body.error_union_ret_type_inst) |eu_inst_idx| {
            // ret_ty body: [error_union_type instruction, break_inline instruction]
            try self.extra.append(self.gpa, eu_inst_idx);
            try self.extra.append(self.gpa, ret_break_inline_idx);
        } else if (body.imported_ret_type_inst) |imported_inst_idx| {
            // ret_ty body: [import, field_ptr_load, break_inline]
            try self.extra.append(self.gpa, body.imported_ret_import_inst.?);
            try self.extra.append(self.gpa, imported_inst_idx);
            try self.extra.append(self.gpa, ret_break_inline_idx);
        } else if (body.union_ret_type_inst) |union_decl_idx| {
            // ret_ty body: [union_decl instruction index, break_inline instruction index]
            try self.extra.append(self.gpa, union_decl_idx);
            try self.extra.append(self.gpa, ret_break_inline_idx);
        } else if (body.tuple_ret_types.items.len > 0) {
            try self.extra.append(self.gpa, @intFromEnum(body.tuple_ret_types.items[0]));
        } else if (body.ret_type != .void) {
            try self.extra.append(self.gpa, @intFromEnum(body.ret_type));
        }

        // body instruction indices
        for (body.body_inst_indices.items) |idx| {
            try self.extra.append(self.gpa, idx);
        }

        // SrcLocs (3 u32s, all zero for synthetic ZIR)
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);

        // proto_hash (4 u32s, all zero for synthetic ZIR)
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);

        // Emit func instruction
        const func_inst = try self.addInst(.func, encodePlNode(.zero, func_payload_idx));

        // Build Break payload in extra
        const break_payload_idx: u32 = @intCast(self.extra.items.len);
        // Break struct: operand_src_node (OptionalOffset.none), block_inst (declaration)
        try self.extra.append(self.gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try self.extra.append(self.gpa, decl_inst);

        // Emit break_inline instruction
        const func_ref = instRef(func_inst);
        const break_inst = try self.addInst(.break_inline, encodeBreak(func_ref, break_payload_idx));

        // Build Declaration payload in extra
        const decl_payload_idx: u32 = @intCast(self.extra.items.len);

        // src_hash (4 u32s, all zero)
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);

        // flags (packed u64 as 2 u32s)
        // Flags packed struct(u64): src_line: u30, src_column: u29, id: Id(u5)
        // For pub_const_simple(7) with src_line=0, src_column=0:
        // id=7 occupies the top 5 bits of the u64
        // flags_0 = 0, flags_1 = 7 << 27 = 0x38000000
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0x38000000);

        // Trailing for pub_const_simple:
        // name: NullTerminatedString
        const name_idx = try self.internString(body.name);
        try self.extra.append(self.gpa, name_idx);

        // value_body_len: num_params + 2 (params... + func + break_inline)
        const num_params: u32 = @intCast(body.param_inst_indices.items.len);
        try self.extra.append(self.gpa, num_params + 2);

        // value_body: param instructions first, then func and break_inline
        for (body.param_inst_indices.items) |param_idx| {
            try self.extra.append(self.gpa, param_idx);
        }

        // value_body[num_params]: func instruction index
        try self.extra.append(self.gpa, func_inst);

        // value_body[num_params+1]: break_inline instruction index
        try self.extra.append(self.gpa, break_inst);

        // Fix up declaration instruction with real payload index
        self.data.items[decl_inst] = encodeDeclaration(0, decl_payload_idx);

        // Track this declaration for the root struct_decl
        try self.decl_indices.append(self.gpa, decl_inst);

        // Clean up
        body.body_inst_indices.deinit(self.gpa);
        body.param_inst_indices.deinit(self.gpa);
        body.tuple_ret_types.deinit(self.gpa);
        body.tuple_element_type_refs.deinit(self.gpa);
        self.gpa.destroy(body);
        self.active_body = null;
    }

    /// Finalize the ZIR. Builds the root struct_decl and returns the result.
    pub fn finalize(self: *Builder) !FinalizedZir {
        // Build StructDecl payload in extra
        const struct_payload_idx: u32 = @intCast(self.extra.items.len);

        // fields_hash (4 u32s, all zero)
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);
        try self.extra.append(self.gpa, 0);

        // src_line
        try self.extra.append(self.gpa, 0);

        // src_node (Ast.Node.Index)
        try self.extra.append(self.gpa, 0);

        // Trailing for has_decls_len:
        // decls_len
        try self.extra.append(self.gpa, @as(u32, @intCast(self.decl_indices.items.len)));

        // decl indices
        for (self.decl_indices.items) |decl_idx| {
            try self.extra.append(self.gpa, decl_idx);
        }

        // Fix up instruction 0 (struct_decl) with real extended data
        const small: u16 = 0x0002; // StructDecl.Small with has_decls_len = true (bit 1 in 0.16)
        self.data.items[0] = encodeExtended(
            @intFromEnum(Zir.Inst.Extended.struct_decl),
            small,
            struct_payload_idx,
        );

        const inst_count: u32 = @intCast(self.tags.items.len);

        return FinalizedZir{
            .instructions_len = inst_count,
            .instructions_tags = self.tags.items,
            .instructions_data = std.mem.sliceAsBytes(self.data.items),
            .string_bytes = self.string_bytes.items,
            .string_bytes_len = @intCast(self.string_bytes.items.len),
            .extra = self.extra.items,
            .extra_len = @intCast(self.extra.items.len),
        };
    }

    // ---- Data encoding helpers ----

    fn encodeUnNode(src_node: Ast.Node.Offset, operand: Zir.Inst.Ref) Zir.Inst.Data {
        return .{ .un_node = .{
            .src_node = src_node,
            .operand = operand,
        } };
    }

    fn encodeUnTok(src_tok: Ast.TokenOffset, operand: Zir.Inst.Ref) Zir.Inst.Data {
        return .{ .un_tok = .{
            .src_tok = src_tok,
            .operand = operand,
        } };
    }

    fn encodePlNode(src_node: Ast.Node.Offset, payload_index: u32) Zir.Inst.Data {
        return .{ .pl_node = .{
            .src_node = src_node,
            .payload_index = payload_index,
        } };
    }

    fn encodeBreak(operand: Zir.Inst.Ref, payload_index: u32) Zir.Inst.Data {
        return .{ .@"break" = .{
            .operand = operand,
            .payload_index = payload_index,
        } };
    }

    fn encodeInt(value: u64) Zir.Inst.Data {
        return .{ .int = value };
    }

    fn encodeFloat(value: f64) Zir.Inst.Data {
        return .{ .float = value };
    }

    fn encodeStr(start: u32, len: u32) Zir.Inst.Data {
        return .{ .str = .{
            .start = @enumFromInt(start),
            .len = len,
        } };
    }

    fn encodeStrTok(start: u32, src_tok: Ast.TokenOffset) Zir.Inst.Data {
        return .{ .str_tok = .{
            .start = @enumFromInt(start),
            .src_tok = src_tok,
        } };
    }

    fn encodePlTok(src_tok: Ast.TokenOffset, payload_index: u32) Zir.Inst.Data {
        return .{ .pl_tok = .{
            .src_tok = src_tok,
            .payload_index = payload_index,
        } };
    }

    pub fn encodeExtended(opcode: u16, small: u16, operand: u32) Zir.Inst.Data {
        return .{ .extended = .{
            .opcode = @enumFromInt(opcode),
            .small = small,
            .operand = operand,
        } };
    }

    fn encodeDeclaration(src_node: u32, payload_index: u32) Zir.Inst.Data {
        return .{ .declaration = .{
            .src_node = @enumFromInt(src_node),
            .payload_index = payload_index,
        } };
    }
};

/// Return type for a function, mapping to Zir.Inst.Ref values.
/// The void variant uses body_len=0 encoding; all others use body_len=1
/// with a trailing Ref.
pub const ReturnType = enum(u32) {
    void = 0,
    bool_type = @intFromEnum(Zir.Inst.Ref.bool_type),
    u8_type = @intFromEnum(Zir.Inst.Ref.u8_type),
    i8_type = @intFromEnum(Zir.Inst.Ref.i8_type),
    u16_type = @intFromEnum(Zir.Inst.Ref.u16_type),
    i16_type = @intFromEnum(Zir.Inst.Ref.i16_type),
    u32_type = @intFromEnum(Zir.Inst.Ref.u32_type),
    i32_type = @intFromEnum(Zir.Inst.Ref.i32_type),
    u64_type = @intFromEnum(Zir.Inst.Ref.u64_type),
    i64_type = @intFromEnum(Zir.Inst.Ref.i64_type),
    usize_type = @intFromEnum(Zir.Inst.Ref.usize_type),
    isize_type = @intFromEnum(Zir.Inst.Ref.isize_type),
    f16_type = @intFromEnum(Zir.Inst.Ref.f16_type),
    f32_type = @intFromEnum(Zir.Inst.Ref.f32_type),
    f64_type = @intFromEnum(Zir.Inst.Ref.f64_type),
    slice_const_u8_type = @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
    _,
};

/// Accumulates function body instructions. Instructions are emitted eagerly
/// into the Builder's instruction arrays so that valid Refs can be returned
/// for use by subsequent instructions.
pub const FuncBody = struct {
    builder: *Builder,
    /// Tracks which instruction indices belong to this function's body
    body_inst_indices: std.ArrayListUnmanaged(u32),
    /// Tracks param instruction indices for the declaration value body
    param_inst_indices: std.ArrayListUnmanaged(u32),
    name: []const u8,
    decl_inst: u32,
    restore_inst: u32,
    has_explicit_return: bool,
    ret_type: ReturnType,
    /// When non-empty, the function returns a tuple type. endFunction will
    /// emit a ret_ty body that computes the struct type from these element
    /// type Refs (e.g., .i64_type, .slice_const_u8_type).
    tuple_ret_types: std.ArrayListUnmanaged(Zir.Inst.Ref) = .empty,
    /// When set, the function returns a union type declared inline.
    /// endFunction will emit a ret_ty body containing this union_decl
    /// instruction and a break_inline, matching AstGen's encoding for
    /// inline return type declarations.
    union_ret_type_inst: ?u32 = null,
    /// When set, the function returns an error union type (anyerror!T).
    /// endFunction will emit a ret_ty body containing the error_union_type
    /// instruction and a break_inline.
    error_union_ret_type_inst: ?u32 = null,
    /// When set, the function returns a type resolved via @import + field access.
    /// endFunction will emit a ret_ty body containing [import, field_ptr_load, break_inline].
    imported_ret_type_inst: ?u32 = null,
    imported_ret_import_inst: ?u32 = null,
    /// When true, the function has a generic (inferred) return type.
    /// ret_ty = { body_len: 0, is_generic: true } = 0x80000000
    is_generic_return: bool = false,
    /// The individual element type Refs for the tuple return type.
    tuple_element_type_refs: std.ArrayListUnmanaged(Zir.Inst.Ref) = .empty,
    /// When false, emitBodyInst/emitBodyInstVoid still emit instructions via
    /// addInst but do NOT append the index to body_inst_indices. This allows
    /// emitting instructions that live inside sub-bodies (e.g. condbr branches)
    /// without polluting the function's main body.
    body_tracking: bool = true,
    /// Call modifier for the next addCall (reset to 0 after use).
    /// 0=auto, 1=never_tail, 2=never_inline, 3=no_suspend, 4=always_tail, 5=always_inline, 6=compile_time
    call_modifier: u3 = 0,

    /// When non-null AND body_tracking is false, "would-be body" instruction
    /// indices are captured here instead of being discarded. This lets callers
    /// collect exactly the top-level instructions for a branch body, excluding
    /// internal sub-body instructions (e.g. call arg bodies).
    non_body_capture: ?*std.ArrayListUnmanaged(u32) = null,

    /// Emit an instruction into the builder and track it as a body instruction
    /// (unless body_tracking is false, in which case it may be captured via
    /// non_body_capture).
    /// Returns the Ref pointing to this instruction.
    pub fn emitBodyInst(self: *FuncBody, tag: Zir.Inst.Tag, inst_data: Zir.Inst.Data) !Zir.Inst.Ref {
        const idx = try self.builder.addInst(tag, inst_data);
        if (self.body_tracking) {
            try self.body_inst_indices.append(self.builder.gpa, idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(self.builder.gpa, idx);
        }
        return Builder.instRef(idx);
    }

    /// Emit an instruction into the builder body but don't return a Ref (for void ops).
    /// Respects body_tracking flag and non_body_capture.
    fn emitBodyInstVoid(self: *FuncBody, tag: Zir.Inst.Tag, inst_data: Zir.Inst.Data) !void {
        const idx = try self.builder.addInst(tag, inst_data);
        if (self.body_tracking) {
            try self.body_inst_indices.append(self.builder.gpa, idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(self.builder.gpa, idx);
        }
    }

    /// Add an integer literal instruction. Returns a Ref to the result.
    pub fn addInt(self: *FuncBody, value: i64) !Zir.Inst.Ref {
        return self.emitBodyInst(.int, Builder.encodeInt(@bitCast(value)));
    }

    /// Add a float literal instruction. Returns a Ref to the result.
    pub fn addFloat(self: *FuncBody, value: f64) !Zir.Inst.Ref {
        return self.emitBodyInst(.float, Builder.encodeFloat(value));
    }

    /// Add a string literal instruction. Returns a Ref to the result.
    pub fn addStr(self: *FuncBody, value: []const u8) !Zir.Inst.Ref {
        const start = try self.builder.internString(value);
        return self.emitBodyInst(.str, Builder.encodeStr(start, @intCast(value.len)));
    }

    /// Return a reference to boolean true (no instruction needed).
    pub fn addBoolTrue(self: *FuncBody) Zir.Inst.Ref {
        _ = self;
        return .bool_true;
    }

    /// Return a reference to boolean false (no instruction needed).
    pub fn addBoolFalse(self: *FuncBody) Zir.Inst.Ref {
        _ = self;
        return .bool_false;
    }

    /// Return a reference to void value (no instruction needed).
    pub fn addVoidValue(self: *FuncBody) Zir.Inst.Ref {
        _ = self;
        return .void_value;
    }

    /// Add a function parameter declaration. This emits a `.param` instruction
    /// that is tracked separately from body instructions — it will be placed
    /// in the declaration value body (before `func` + `break_inline`).
    ///
    /// `name` is the parameter name (e.g. "a").
    /// `type_ref` is a `Zir.Inst.Ref` for the parameter type (e.g. `.i64_type`).
    ///   Use `.none` or `.generic_poison` for anytype.
    /// Returns a Ref to the param instruction, which can be used in the function body.
    pub fn addParam(self: *FuncBody, name: []const u8, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const name_idx = try b.internString(name);

        if (type_ref == .none) {
            // Anytype parameter: use .param_anytype tag with .str_tok data
            // Data: { start: NullTerminatedString (name), src_tok: TokenOffset }
            const idx = try b.addInst(.param_anytype, Builder.encodeStrTok(name_idx, .zero));

            // Track as a param instruction (goes in declaration value body, not function body)
            try self.param_inst_indices.append(b.gpa, idx);
            return Builder.instRef(idx);
        }

        // Typed parameter: use .param tag with .pl_tok data.
        //
        // The type body is a list of instruction indices that Sema analyzes inline
        // to produce the type. For a simple built-in type like i64, we emit a single
        // break_inline instruction that yields the type Ref.
        //
        // We pre-compute the param instruction index (it will be emitted after the
        // break_inline) so the break_inline can reference it.
        const param_inst_idx: u32 = @intCast(b.tags.items.len + 1); // +1 for the break_inline we emit first

        // Emit the break_inline that yields the type ref.
        // Break payload in extra: { operand_src_node: OptionalOffset, block_inst: Index }
        const break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(b.gpa, param_inst_idx); // block_inst = the param instruction
        const break_idx = try b.addInst(.break_inline, Builder.encodeBreak(type_ref, break_payload_idx));

        // Param payload in extra:
        //   name: NullTerminatedString
        //   type: Param.Type = packed struct(u32) { body_len: u31, is_generic: bool }
        //   [trailing instruction indices for the type body]
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, name_idx); // name
        try b.extra.append(b.gpa, 1); // type: body_len=1, is_generic=false
        try b.extra.append(b.gpa, break_idx); // body[0] = break_inline instruction index

        // .param uses .pl_tok data
        const idx = try b.addInst(.param, Builder.encodePlTok(.zero, payload_idx));
        std.debug.assert(idx == param_inst_idx);

        // Track as a param instruction (goes in declaration value body, not function body)
        try self.param_inst_indices.append(b.gpa, idx);

        return Builder.instRef(idx);
    }

    /// Add an enum literal instruction. Returns a Ref to the result.
    pub fn addEnumLiteral(self: *FuncBody, name: []const u8) !Zir.Inst.Ref {
        const start = try self.builder.internString(name);
        return self.emitBodyInst(.enum_literal, Builder.encodeStrTok(start, .zero));
    }

    /// Add a binary operation (add, sub, mul, etc.). Returns a Ref to the result.
    /// The tag must be one that uses pl_node with Bin payload.
    pub fn addBinOp(self: *FuncBody, tag: Zir.Inst.Tag, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        // Bin payload in extra: { lhs: Ref, rhs: Ref }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(lhs));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(rhs));
        return self.emitBodyInst(tag, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Add arithmetic negation. Returns a Ref to the result.
    pub fn addNegate(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.negate, Builder.encodeUnNode(.zero, operand));
    }

    /// Add boolean NOT. Returns a Ref to the result.
    pub fn addBoolNot(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.bool_not, Builder.encodeUnNode(.zero, operand));
    }

    /// Add a parameter whose type is @import(module_name).field_name.
    /// The type body contains [import, field_ptr_load, break_inline].
    pub fn addParamImportedType(self: *FuncBody, name: []const u8, module_name: []const u8, field_name: []const u8) !Zir.Inst.Ref {
        const b = self.builder;
        const name_idx = try b.internString(name);

        // Pre-compute the param instruction index: it follows 3 instructions
        // (import, field_ptr_load, break_inline)
        const param_inst_idx: u32 = @intCast(b.tags.items.len + 3);

        // 1. Emit import instruction
        const path_idx = try b.internString(module_name);
        const import_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @intFromEnum(Zir.Inst.Ref.none));
        try b.extra.append(b.gpa, path_idx);
        const import_inst = try b.addInst(.import, Builder.encodePlTok(.zero, import_payload_idx));
        const import_ref = Builder.instRef(import_inst);

        // 2. Emit field_ptr_load instruction (Sema's fieldPtrLoad handles non-pointer
        //    operands by falling through to fieldVal for comptime namespace access)
        const field_name_idx = try b.internString(field_name);
        const field_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @intFromEnum(import_ref));
        try b.extra.append(b.gpa, field_name_idx);
        const field_inst = try b.addInst(.field_ptr_load, Builder.encodePlNode(.zero, field_payload_idx));
        const field_ref = Builder.instRef(field_inst);

        // 3. Emit break_inline
        const break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(b.gpa, param_inst_idx);
        const break_idx = try b.addInst(.break_inline, Builder.encodeBreak(field_ref, break_payload_idx));

        // Param payload
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, name_idx);
        try b.extra.append(b.gpa, 3); // body_len=3, is_generic=false
        try b.extra.append(b.gpa, import_inst);
        try b.extra.append(b.gpa, field_inst);
        try b.extra.append(b.gpa, break_idx);

        const idx = try b.addInst(.param, Builder.encodePlTok(.zero, payload_idx));
        std.debug.assert(idx == param_inst_idx);

        try self.param_inst_indices.append(b.gpa, idx);
        return Builder.instRef(idx);
    }

    /// Emit `?T` (optional type). Returns a Ref to the optional type.
    pub fn addOptionalType(self: *FuncBody, child_type: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.optional_type, Builder.encodeUnNode(.zero, child_type));
    }

    /// Emit `@as(dest_type, operand)`. Returns a Ref to the coerced value.
    pub fn addAs(self: *FuncBody, dest_type: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(dest_type));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        return self.emitBodyInst(.as_node, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `@ptrCast(dest_type, operand)`. Returns a Ref to the casted value.
    pub fn addPtrCast(self: *FuncBody, dest_type: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.ptr_cast, dest_type, operand);
    }

    /// Emit a full pointer cast with nested flags such as `@alignCast`.
    pub fn addFullPtrCast(self: *FuncBody, flags: Zir.Inst.FullPtrCastFlags, dest_type: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, 0); // Ast.Node.Offset synthetic node
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(dest_type));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(
                @intFromEnum(Zir.Inst.Extended.ptr_cast_full),
                @bitCast(@as(u16, @intCast(@as(u5, @bitCast(flags))))),
                payload_idx,
            ),
        );
    }

    /// Emit `@alignCast(dest_type, operand)`. Returns a Ref to the casted value.
    pub fn addAlignCast(self: *FuncBody, dest_type: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addFullPtrCast(.{ .align_cast = true }, dest_type, operand);
    }

    /// Emit @TypeOf(operand). Returns a Ref to the type.
    /// ZIR tag: .typeof, data field: .un_node
    pub fn addTypeOf(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.typeof, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@import("module_name")`. Returns a Ref to the imported module.
    /// Uses the `.import` instruction with `.pl_tok` data and `Import` payload.
    pub fn addImport(self: *FuncBody, module_name: []const u8) !Zir.Inst.Ref {
        const path_idx = try self.builder.internString(module_name);
        // Import payload in extra: { res_ty: Ref, path: NullTerminatedString }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(Zir.Inst.Ref.none)); // res_ty = .none
        try self.builder.extra.append(self.builder.gpa, path_idx); // path
        return self.emitBodyInst(.import, Builder.encodePlTok(.zero, payload_idx));
    }

    /// Emit field access on an object (a.b syntax). Returns a Ref to the field value.
    /// Uses the `.field_ptr_load` instruction with `.pl_node` data and `Field` payload.
    /// In 0.16, Sema's fieldPtrLoad handles non-pointer operands by delegating to
    /// fieldVal for comptime namespace access (fork modification in Sema.zig).
    pub fn addFieldPtrLoad(self: *FuncBody, object: Zir.Inst.Ref, field_name: []const u8) !Zir.Inst.Ref {
        const name_idx = try self.builder.internString(field_name);
        // Field payload in extra: { lhs: Ref, field_name_start: NullTerminatedString }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(object));
        try self.builder.extra.append(self.builder.gpa, name_idx);
        return self.emitBodyInst(.field_ptr_load, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit field pointer access on an object (get a pointer to a.b). Returns a Ref to the field pointer.
    /// Uses the `.field_ptr` instruction with `.pl_node` data and `Field` payload.
    pub fn addFieldPtr(self: *FuncBody, object: Zir.Inst.Ref, field_name: []const u8) !Zir.Inst.Ref {
        const name_idx = try self.builder.internString(field_name);
        // Field payload in extra: { lhs: Ref, field_name_start: NullTerminatedString }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(object));
        try self.builder.extra.append(self.builder.gpa, name_idx);
        return self.emitBodyInst(.field_ptr, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit a store through a pointer. Stores value into the location pointed to by ptr.
    /// Uses the `.store_node` instruction with `.pl_node` data and `Bin` payload.
    /// This is a void operation (no result value).
    pub fn addStore(self: *FuncBody, ptr: Zir.Inst.Ref, value: Zir.Inst.Ref) !void {
        // Bin payload in extra: { lhs: Ref (ptr), rhs: Ref (value) }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(ptr));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(value));
        try self.emitBodyInstVoid(.store_node, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit is_non_null check on an optional value. Returns a bool Ref.
    /// `x != null` — returns true if the optional has a payload.
    /// Uses the `.is_non_null` instruction with `.un_node` data.
    pub fn addIsNonNull(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.is_non_null, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit optional payload extraction with safety check. `?T => T`.
    /// Given an optional value, returns the payload value with a safety check
    /// that the value is non-null. Used for `orelse`, `if`, and `while`.
    /// Uses the `.optional_payload_safe` instruction with `.un_node` data.
    pub fn addOptionalPayloadSafe(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.optional_payload_safe, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit an anonymous struct initialization (for building aggregates/tuples).
    /// `field_names` and `field_values` must have the same length.
    /// Uses the `.struct_init_anon` instruction with `.pl_node` data and `StructInitAnon` payload.
    pub fn addStructInitAnon(self: *FuncBody, field_names: []const []const u8, field_values: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        std.debug.assert(field_names.len == field_values.len);
        const fields_len: u32 = @intCast(field_names.len);

        // StructInitAnon payload in extra: { abs_node: Ast.Node.Index, abs_line: u32, fields_len: u32 }
        // Trailing: for each field: { field_name: NullTerminatedString, init: Ref }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, 0); // abs_node = 0
        try self.builder.extra.append(self.builder.gpa, 0); // abs_line = 0
        try self.builder.extra.append(self.builder.gpa, fields_len);

        // Trailing items: { field_name: NullTerminatedString, init: Ref } per field
        for (0..field_names.len) |i| {
            const name_idx = try self.builder.internString(field_names[i]);
            try self.builder.extra.append(self.builder.gpa, name_idx);
            try self.builder.extra.append(self.builder.gpa, @intFromEnum(field_values[i]));
        }

        return self.emitBodyInst(.struct_init_anon, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit a `decl_ref` instruction that yields a reference to a named declaration.
    /// Used to get a function Ref without calling it (for use with call_ref inside branches).
    pub fn addDeclRef(self: *FuncBody, name: []const u8) !Zir.Inst.Ref {
        const start = try self.builder.internString(name);
        return self.emitBodyInst(.decl_ref, Builder.encodeStrTok(start, .zero));
    }

    pub fn addDeclVal(self: *FuncBody, name: []const u8) !Zir.Inst.Ref {
        const start = try self.builder.internString(name);
        return self.emitBodyInst(.decl_val, Builder.encodeStrTok(start, .zero));
    }

    /// Emit a `ret_type` instruction that yields the current function's return type.
    /// Used to reference the return type inside the function body (e.g., for @unionInit).
    pub fn addRetType(self: *FuncBody) !Zir.Inst.Ref {
        return self.emitBodyInst(.ret_type, .{ .node = .zero });
    }

    /// Emit a union initialization: @unionInit(union_type, field_name, init_value)
    /// union_type: Ref to the union type
    /// field_name: Ref to an enum_literal for the field name
    /// init_value: Ref to the initial value
    pub fn addUnionInit(
        self: *FuncBody,
        union_type: Zir.Inst.Ref,
        field_name: Zir.Inst.Ref,
        init_value: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(union_type));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(field_name));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(init_value));

        return self.emitBodyInst(.union_init, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit a call using a Ref as the callee (e.g. from import + field access).
    /// Returns a Ref to the result.
    ///
    /// Each arg body is a single break_inline instruction that yields the arg
    /// value. The break_inline targets the call instruction.
    pub fn addCallRef(self: *FuncBody, callee: Zir.Inst.Ref, args: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // Pre-compute call instruction index
        const predicted = @as(u32, @intCast(b.tags.items.len)) + @as(u32, @intCast(args.len)) + 1;
        const call_inst_idx: u32 = predicted;

        var arg_inst_indices = std.ArrayListUnmanaged(u32).empty;
        defer arg_inst_indices.deinit(gpa);

        for (args) |arg| {
            const brk_payload_idx: u32 = @intCast(b.extra.items.len);
            try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
            try b.extra.append(gpa, call_inst_idx);
            const brk_idx = try b.addInst(.break_inline, Builder.encodeBreak(arg, brk_payload_idx));
            try arg_inst_indices.append(gpa, brk_idx);
        }

        try self.emitBodyInstVoid(.dbg_stmt, .{ .dbg_stmt = .{ .line = 0, .column = 0 } });

        const payload_idx: u32 = @intCast(b.extra.items.len);
        const args_len: u32 = @intCast(args.len);
        const call_mod: u32 = @as(u32, self.call_modifier) & 0x7;
        const flags: u32 = (args_len << 5) | (1 << 4) | call_mod;
        self.call_modifier = 0; // reset after use
        try b.extra.append(gpa, flags);
        try b.extra.append(gpa, @intFromEnum(callee));

        for (0..args.len) |i| {
            try b.extra.append(gpa, @as(u32, @intCast(args_len + (i + 1))));
        }

        for (arg_inst_indices.items) |idx| {
            try b.extra.append(gpa, idx);
        }

        return self.emitBodyInst(.call, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Add a function call by name. Returns a Ref to the result.
    pub fn addCall(self: *FuncBody, callee_name: []const u8, args: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // Resolve callee via decl_val
        const name_start = try b.internString(callee_name);
        const callee_ref = try self.emitBodyInst(.decl_val, Builder.encodeStrTok(name_start, .zero));

        // Reserve the call instruction (will be patched after args are processed).
        // This matches AstGen's approach: pre-allocate, then fill in.
        const call_inst_idx: u32 = @intCast(b.tags.items.len);
        _ = try b.addInst(undefined, undefined); // placeholder

        // Emit break_inline for each arg body (targeting the reserved call instruction)
        const args_len: u32 = @intCast(args.len);
        var arg_body_indices = std.ArrayListUnmanaged(u32).empty;
        defer arg_body_indices.deinit(gpa);

        for (args) |arg| {
            const brk_payload_idx: u32 = @intCast(b.extra.items.len);
            try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
            try b.extra.append(gpa, call_inst_idx); // block_inst = call instruction
            const brk_idx = try b.addInst(.break_inline, Builder.encodeBreak(arg, brk_payload_idx));
            try arg_body_indices.append(gpa, brk_idx);
        }

        // Sema requires dbg_stmt immediately before the call instruction body.
        try self.emitBodyInstVoid(.dbg_stmt, .{ .dbg_stmt = .{ .line = 0, .column = 0 } });

        // Build Call payload matching AstGen's exact format:
        // [flags(u32), callee(Ref), arg_0_end, arg_1_end, ..., body_inst_0, body_inst_1, ...]
        const payload_idx: u32 = @intCast(b.extra.items.len);

        // Flags layout: [packed_modifier:3][ensure_result_used:1][pop_error_return_trace:1][args_len:27]
        const modifier: u32 = @as(u32, self.call_modifier) & 0x7;
        const flags: u32 = (args_len << 5) | (1 << 4) | modifier;
        self.call_modifier = 0; // reset after use
        try b.extra.append(gpa, flags);
        try b.extra.append(gpa, @intFromEnum(callee_ref));

        // arg_end values: cumulative offsets into the body array
        // arg_0_start = args_len (implicit). Each arg has 1 body instruction (break_inline).
        for (0..args.len) |i| {
            try b.extra.append(gpa, @as(u32, @intCast(args_len + (i + 1))));
        }

        // Body instructions (break_inline indices)
        for (arg_body_indices.items) |idx| {
            try b.extra.append(gpa, idx);
        }

        // Patch the reserved call instruction
        b.tags.items[call_inst_idx] = @intFromEnum(Zir.Inst.Tag.call);
        b.data.items[call_inst_idx] = Builder.encodePlNode(.zero, payload_idx);

        // Track call as a body instruction
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, call_inst_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, call_inst_idx);
        }

        return Builder.instRef(call_inst_idx);
    }

    /// Emit @typeInfo(operand). Returns a Ref to the type info value.
    /// ZIR tag: .type_info, data field: .un_node
    pub fn addTypeInfo(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.type_info, Builder.encodeUnNode(.zero, operand));
    }

    /// Add an anonymous array initialization (creates a tuple type).
    /// ZIR tag: `.array_init_anon`, data: `pl_node`, payload: `MultiOp` + trailing Refs.
    pub fn addArrayInitAnon(self: *FuncBody, elements: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // MultiOp payload: { operands_len: u32 }
        // Trailing: operand Refs (as u32)
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intCast(elements.len)); // operands_len

        // Trailing operand Refs
        for (elements) |elem| {
            try b.extra.append(gpa, @intFromEnum(elem));
        }

        return self.emitBodyInst(.array_init_anon, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Access an element of a tuple/array by immediate index.
    /// ZIR tag: `.elem_val_imm`, data field: `elem_val_imm`.
    pub fn addElemValImm(self: *FuncBody, operand: Zir.Inst.Ref, index: u32) !Zir.Inst.Ref {
        return self.emitBodyInst(.elem_val_imm, .{ .elem_val_imm = .{
            .operand = operand,
            .idx = index,
        } });
    }

    /// Emit `is_non_err(operand)` — check if an error union value is not an error.
    /// Returns a bool Ref.
    pub fn addIsNonErr(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.is_non_err, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `err_union_payload_unsafe(operand)` — extract payload from error union.
    /// Caller must ensure operand is not an error.
    pub fn addErrUnionPayloadUnsafe(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.err_union_payload_unsafe, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `optional_payload_unsafe(operand)` — extract payload from optional.
    /// Caller must ensure operand is non-null.
    pub fn addOptionalPayloadUnsafe(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.optional_payload_unsafe, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `operand orelse fallback` using inline block/condbr/break.
    /// Matches AstGen's exact encoding for the `orelse` operator.
    pub fn addOrelse(self: *FuncBody, operand: Zir.Inst.Ref, fallback: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // block_inline with placeholder payload
        // body_len = 2: [is_non_null, condbr_inline]
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 2); // body_len = 2
        const block_body_slot_0: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for is_non_null
        const block_body_slot_1: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for condbr_inline

        const block_idx = try b.addInst(.block_inline, Builder.encodePlNode(.zero, block_payload_idx));
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }

        // is_non_null check (block body instruction)
        const is_non_null_inst = try b.addInst(.is_non_null, Builder.encodeUnNode(.zero, operand));

        // Then branch: unwrap payload + break_inline
        const payload_inst = try b.addInst(.optional_payload_unsafe, Builder.encodeUnNode(.zero, operand));
        const then_break_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(gpa, block_idx);
        const then_break = try b.addInst(.break_inline, Builder.encodeBreak(Builder.instRef(payload_inst), then_break_payload));

        // Else branch: break_inline with fallback
        const else_break_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(gpa, block_idx);
        const else_break = try b.addInst(.break_inline, Builder.encodeBreak(fallback, else_break_payload));

        // condbr_inline
        const condbr_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(Builder.instRef(is_non_null_inst)));
        try b.extra.append(gpa, 2); // then_body_len (payload + break)
        try b.extra.append(gpa, 1); // else_body_len (break)
        try b.extra.append(gpa, payload_inst);
        try b.extra.append(gpa, then_break);
        try b.extra.append(gpa, else_break);
        const condbr_inst = try b.addInst(.condbr_inline, Builder.encodePlNode(.zero, condbr_payload));

        // Fix up block body: [is_non_null, condbr_inline]
        b.extra.items[block_body_slot_0] = is_non_null_inst;
        b.extra.items[block_body_slot_1] = condbr_inst;

        return Builder.instRef(block_idx);
    }

    /// Mark a value as used (prevents "result not used" compile error for void calls).
    /// ZIR tag: `.ensure_result_used`, data field: `un_node`.
    pub fn addEnsureResultUsed(self: *FuncBody, operand: Zir.Inst.Ref) !void {
        try self.emitBodyInstVoid(.ensure_result_used, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `if (condition) return value;` — conditional early return.
    /// Uses block_inline + condbr_inline for proper comptime evaluation:
    ///   block_inline { condbr_inline(cond, then: [ret_node(value)], else: [break_inline(block, void)]) }
    pub fn addCondReturn(self: *FuncBody, condition: Zir.Inst.Ref, value: Zir.Inst.Ref) !void {
        const b = self.builder;
        const gpa = b.gpa;

        // block_inline with placeholder
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 1); // body_len = 1 (condbr_inline)
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder

        const block_idx = try b.addInst(.block_inline, Builder.encodePlNode(.zero, block_payload_idx));

        // ret_node for then branch
        const ret_idx = try b.addInst(.ret_node, Builder.encodeUnNode(.zero, value));

        // break_inline(block, void) for else branch
        const break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(gpa, block_idx);
        const break_idx = try b.addInst(.break_inline, Builder.encodeBreak(.void_value, break_payload_idx));

        // condbr_inline
        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition));
        try b.extra.append(gpa, 1); // then_body_len
        try b.extra.append(gpa, 1); // else_body_len
        try b.extra.append(gpa, ret_idx);
        try b.extra.append(gpa, break_idx);
        const condbr_idx = try b.addInst(.condbr_inline, Builder.encodePlNode(.zero, condbr_payload_idx));

        // Fix up block body
        b.extra.items[block_body_slot] = condbr_idx;

        // Track block
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }
    }

    /// Add a debug statement with line/column info.
    /// ZIR tag: `.dbg_stmt`, data field: `dbg_stmt` (LineColumn).
    pub fn addDbgStmt(self: *FuncBody, line: u32, column: u32) !void {
        try self.emitBodyInstVoid(.dbg_stmt, .{ .dbg_stmt = .{
            .line = line,
            .column = column,
        } });
    }

    /// Add explicit ret_node (return with a value).
    pub fn addRetNode(self: *FuncBody, operand: Zir.Inst.Ref) !void {
        try self.emitBodyInstVoid(.ret_node, Builder.encodeUnNode(.zero, operand));
        self.has_explicit_return = true;
    }

    /// Add implicit void return.
    pub fn addRetImplicit(self: *FuncBody) !void {
        try self.emitBodyInstVoid(.ret_implicit, Builder.encodeUnTok(.zero, .void_value));
        self.has_explicit_return = true;
    }

    /// Add an inline if-then-else expression using block_inline/condbr_inline.
    /// For comptime evaluation, only the taken branch is analyzed.
    pub fn addIfElseInline(
        self: *FuncBody,
        condition: Zir.Inst.Ref,
        then_value: Zir.Inst.Ref,
        else_value: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 1); // body_len = 1
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder

        const block_idx = try b.addInst(.block_inline, Builder.encodePlNode(.zero, block_payload_idx));
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }

        const then_brk_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(gpa, block_idx);
        const then_brk = try b.addInst(.break_inline, Builder.encodeBreak(then_value, then_brk_payload));

        const else_brk_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
        try b.extra.append(gpa, block_idx);
        const else_brk = try b.addInst(.break_inline, Builder.encodeBreak(else_value, else_brk_payload));

        const condbr_payload: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition));
        try b.extra.append(gpa, 1);
        try b.extra.append(gpa, 1);
        try b.extra.append(gpa, then_brk);
        try b.extra.append(gpa, else_brk);
        const condbr_idx = try b.addInst(.condbr_inline, Builder.encodePlNode(.zero, condbr_payload));

        b.extra.items[block_body_slot] = condbr_idx;

        return Builder.instRef(block_idx);
    }

    /// Add an if-then-else expression. Both branches must produce a value.
    /// Returns a Ref to the result of whichever branch is taken.
    ///
    /// Emits the ZIR pattern:
    ///   %block = block_inline(body_len=1) {
    ///       condbr_inline(condition, then_body_len=1, else_body_len=1)
    ///           then: [break_inline(%block, then_value)]
    ///           else: [break_inline(%block, else_value)]
    ///   }
    pub fn addIfElse(
        self: *FuncBody,
        condition: Zir.Inst.Ref,
        then_value: Zir.Inst.Ref,
        else_value: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // 1. Emit block with a placeholder payload (fix up below).
        // Using non-inline block+condbr+break so conditions can be runtime values.
        // Payload format is identical between inline and non-inline variants.
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 1); // body_len = 1 (the condbr)
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for condbr index

        const block_idx = try b.addInst(.block, Builder.encodePlNode(.zero, block_payload_idx));
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }

        // 2. Emit the two break instructions (NOT body instructions).
        const break_then_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst
        const break_then_idx = try b.addInst(.@"break", Builder.encodeBreak(then_value, break_then_payload_idx));

        const break_else_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst
        const break_else_idx = try b.addInst(.@"break", Builder.encodeBreak(else_value, break_else_payload_idx));

        // 3. Emit condbr (NOT a body instruction).
        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition)); // condition
        try b.extra.append(gpa, 1); // then_body_len = 1
        try b.extra.append(gpa, 1); // else_body_len = 1
        try b.extra.append(gpa, break_then_idx); // then body[0]
        try b.extra.append(gpa, break_else_idx); // else body[0]
        const condbr_idx = try b.addInst(.condbr, Builder.encodePlNode(.zero, condbr_payload_idx));

        // 4. Fix up block's body to point to condbr.
        b.extra.items[block_body_slot] = condbr_idx;

        return Builder.instRef(block_idx);
    }

    /// Add an if-then-else expression with full branch bodies.
    /// Unlike addIfElse which only takes final values, this method accepts
    /// instruction index ranges for each branch. Those instructions are placed
    /// INSIDE the condbr_inline's then/else bodies so that only the taken
    /// branch is analyzed by Sema (and thus only the taken branch executes).
    ///
    /// `then_insts` / `else_insts` are raw instruction indices (from addInst)
    /// that were emitted with body_tracking=false. They are NOT in the
    /// function's body_inst_indices and will only be referenced from within
    /// the condbr_inline payload.
    pub fn addIfElseWithBodies(
        self: *FuncBody,
        condition: Zir.Inst.Ref,
        then_insts: []const u32,
        then_result: Zir.Inst.Ref,
        else_insts: []const u32,
        else_result: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // then body = then_insts... + break_inline(block, then_result)
        // else body = else_insts... + break_inline(block, else_result)
        const then_body_len: u32 = @intCast(then_insts.len + 1);
        const else_body_len: u32 = @intCast(else_insts.len + 1);

        // 1. Emit block with placeholder payload.
        // Using non-inline block+condbr+break so conditions can be runtime values.
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 1); // body_len = 1 (the condbr)
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for condbr index

        // block IS a body instruction of the function — but only when
        // body_tracking is active. When tracking is off, the block goes
        // into the capture buffer so it can be nested inside an outer condbr's
        // branch body (used by switch/case chaining).
        const block_idx = try b.addInst(.block, Builder.encodePlNode(.zero, block_payload_idx));
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }

        // 2. Emit break for then branch (NOT a body instruction).
        const break_then_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst
        const break_then_idx = try b.addInst(.@"break", Builder.encodeBreak(then_result, break_then_payload_idx));

        // 3. Emit break for else branch (NOT a body instruction).
        const break_else_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst
        const break_else_idx = try b.addInst(.@"break", Builder.encodeBreak(else_result, break_else_payload_idx));

        // 4. Emit condbr with full branch bodies.
        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition)); // condition
        try b.extra.append(gpa, then_body_len); // then_body_len
        try b.extra.append(gpa, else_body_len); // else_body_len
        // then body: branch instructions + break
        for (then_insts) |idx| {
            try b.extra.append(gpa, idx);
        }
        try b.extra.append(gpa, break_then_idx);
        // else body: branch instructions + break
        for (else_insts) |idx| {
            try b.extra.append(gpa, idx);
        }
        try b.extra.append(gpa, break_else_idx);
        const condbr_idx = try b.addInst(.condbr, Builder.encodePlNode(.zero, condbr_payload_idx));

        // 5. Fix up block's body to point to condbr.
        b.extra.items[block_body_slot] = condbr_idx;

        return Builder.instRef(block_idx);
    }

    /// Emit a block_inline + condbr where the then-branch contains full
    /// instruction bodies ending with ret. Uses block_inline (no runtime
    /// block scope) with runtime condbr (runtime condition evaluation).
    /// The then-branch should end with a ret or unreachable — no break is added.
    /// The else-branch gets a break_inline(void) appended so execution continues.
    pub fn addCondBranchWithBodies(
        self: *FuncBody,
        condition: Zir.Inst.Ref,
        then_insts: []const u32,
        else_insts: []const u32,
    ) !void {
        const b = self.builder;
        const gpa = b.gpa;

        // block_inline wrapping the condbr
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 1); // body_len = 1 (the condbr)
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for condbr index

        const block_idx = try b.addInst(.block_inline, Builder.encodePlNode(.zero, block_payload_idx));

        // break_inline for the else branch — continues past the block
        const break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // src_node = none
        try b.extra.append(gpa, block_idx);
        const break_idx = try b.addInst(.break_inline, Builder.encodeBreak(.void_value, break_payload_idx));

        // Runtime condbr with full bodies
        // then_body = then_insts (ending with ret — no break needed)
        // else_body = else_insts + break(void)
        const then_body_len: u32 = @intCast(then_insts.len);
        const else_body_len: u32 = @intCast(else_insts.len + 1); // +1 for break

        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition));
        try b.extra.append(gpa, then_body_len);
        try b.extra.append(gpa, else_body_len);
        for (then_insts) |idx| {
            try b.extra.append(gpa, idx);
        }
        for (else_insts) |idx| {
            try b.extra.append(gpa, idx);
        }
        try b.extra.append(gpa, break_idx);
        const condbr_idx = try b.addInst(.condbr, Builder.encodePlNode(.zero, condbr_payload_idx));

        // Fix up block body
        b.extra.items[block_body_slot] = condbr_idx;

        // Track block as body instruction
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_idx);
        }
    }

    /// Return the current instruction count in the builder.
    /// Used by callers to track instruction index ranges for branch bodies.
    pub fn getInstCount(self: *FuncBody) u32 {
        return @intCast(self.builder.tags.items.len);
    }

    /// Emit a struct_init for a known tuple type.
    /// Emits a tuple_decl INSIDE the function body so Sema can resolve it,
    /// then uses struct_init with struct_init_field_type to create a typed init.
    pub fn addStructInitTyped(
        self: *FuncBody,
        struct_type: Zir.Inst.Ref,
        field_names: []const []const u8,
        field_values: []const Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        std.debug.assert(field_names.len == field_values.len);
        const b = self.builder;
        const gpa = b.gpa;
        const fields_len: u32 = @intCast(field_names.len);

        // Emit a tuple_decl in the function body so Sema can resolve the type
        // from within this scope. Use the element types from the stored tuple_ret_types.
        // Use the caller-provided struct_type directly. The caller is responsible
        // for emitting body-local tuple_decl instructions (including nested ones).
        const body_tuple_ref = struct_type;

        // validate_struct_init_result_ty with the body-local tuple type
        try self.emitBodyInstVoid(.validate_struct_init_result_ty, Builder.encodeUnNode(.zero, body_tuple_ref));

        // struct_init_field_type per field
        var field_type_indices = std.ArrayListUnmanaged(u32).empty;
        defer field_type_indices.deinit(gpa);
        for (field_names) |name| {
            const name_idx = try b.internString(name);
            const ft_payload_idx: u32 = @intCast(b.extra.items.len);
            try b.extra.append(gpa, @intFromEnum(body_tuple_ref));
            try b.extra.append(gpa, name_idx);
            const ft_idx = try b.addInst(.struct_init_field_type, Builder.encodePlNode(.zero, ft_payload_idx));
            try field_type_indices.append(gpa, ft_idx);
        }

        // struct_init
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // abs_node
        try b.extra.append(gpa, 0); // abs_line
        try b.extra.append(gpa, fields_len);
        for (field_type_indices.items, field_values) |ft_idx, init_ref| {
            try b.extra.append(gpa, ft_idx);
            try b.extra.append(gpa, @intFromEnum(init_ref));
        }

        return self.emitBodyInst(.struct_init, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Set a tuple return type from element type Refs.
    /// Emits a `tuple_decl` extended instruction in the declaration value body
    /// and stores its Ref for use by `endFunction`.
    pub fn setTupleReturnType(self: *FuncBody, types: []const Zir.Inst.Ref) !void {
        const b = self.builder;
        const fields_len: u16 = @intCast(types.len);

        // TupleDecl payload: { src_node: Ast.Node.Offset }
        const tuple_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // src_node = 0

        // Trailing: per field { type: Ref, init: Ref }
        for (types) |elem_type| {
            try b.extra.append(b.gpa, @intFromEnum(elem_type));
            try b.extra.append(b.gpa, @intFromEnum(Zir.Inst.Ref.none)); // no default init
        }

        const tuple_decl_idx = try b.addInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.tuple_decl), fields_len, tuple_payload_idx),
        );

        // Track as a param instruction so it's in the declaration value body
        try self.param_inst_indices.append(b.gpa, tuple_decl_idx);

        // Store the Ref for endFunction to use as the return type
        self.tuple_ret_types.clearRetainingCapacity();
        try self.tuple_ret_types.append(b.gpa, Builder.instRef(tuple_decl_idx));

        // Store element types for addStructInitTyped to re-emit tuple_decl in function body
        self.tuple_element_type_refs.clearRetainingCapacity();
        try self.tuple_element_type_refs.appendSlice(b.gpa, types);
    }

    /// Prong descriptor for addSwitchBlock.
    pub const SwitchProng = struct {
        /// Variant name string (will be interned as an enum_literal instruction).
        item_name: []const u8,
        /// Whether this prong captures the payload: `.Ok => |val| ...`
        has_capture: bool,
        /// Pre-emitted ZIR instruction indices for the prong body.
        body_insts: []const u32,
        /// The result value of this prong.
        body_result: Zir.Inst.Ref,
        /// If true, the break operand will be the switch_block's own Ref
        /// (which Sema resolves to the captured payload via inst_map).
        /// This is used for the Ok prong where the result IS the captured payload.
        use_capture_as_result: bool = false,
    };

    /// Emit a complete switch_block instruction in a single pass.
    ///
    /// All prong body instructions must be pre-emitted by the caller
    /// (with body_tracking OFF). This function atomically emits:
    ///   1. enum_literal instructions for each prong item (body_tracking ON)
    ///   2. break instructions for each prong (via addInst, no body tracking)
    ///   3. dbg_stmt (body_tracking ON)
    ///   4. switch_block instruction (body_tracking ON)
    ///   5. Contiguous SwitchBlock extra data
    ///
    /// Returns the switch_block Ref. Body instructions that reference this
    /// Ref will receive the captured union payload at runtime (Sema maps
    /// it via inst_map).
    ///
    /// Follows the addStructInitAnon pattern: all data known upfront,
    /// single atomic emission, no implicit state mutation.
    pub fn addSwitchBlock(
        self: *FuncBody,
        operand: Zir.Inst.Ref,
        prongs: []const SwitchProng,
    ) !Zir.Inst.Ref {
        const b = self.builder;

        // ---- Phase 1: Emit enum_literal instructions (body_tracking ON) ----
        // These are visible in the function body and can be referenced by Sema.
        var item_refs = try b.gpa.alloc(Zir.Inst.Ref, prongs.len);
        defer b.gpa.free(item_refs);
        for (prongs, 0..) |p, pi| {
            item_refs[pi] = try self.addEnumLiteral(p.item_name);
        }

        // ---- Phase 2: Emit break instructions (via addInst, not body) ----
        // We need to know the future switch_block index for break targets.
        // breaks + dbg_stmt are emitted first, then the switch_block.
        // Future switch index = current + num_breaks + 1 (dbg_stmt).
        // NOTE: We use .break (not .break_inline) because break_inline
        // triggers ComptimeBreak which creates post-hoc blocks that don't
        // integrate properly with switch_block's Sema handling. Regular
        // .break is what AstGen uses for switch prong exits.
        const future_switch_idx: u32 = @intCast(b.tags.items.len + prongs.len + 1);

        const switch_ref = Builder.instRef(future_switch_idx);

        var break_indices = try b.gpa.alloc(u32, prongs.len);
        defer b.gpa.free(break_indices);
        for (prongs, 0..) |p, pi| {
            const break_payload_idx: u32 = @intCast(b.extra.items.len);
            try b.extra.append(b.gpa, 0); // Break.operand_src_node = 0
            try b.extra.append(b.gpa, future_switch_idx); // Break.block_inst

            // For capture prongs with void_value as body_result, use the
            // switch_block's own Ref. Sema resolves this through inst_map
            // to the captured payload value.
            const result = if (p.use_capture_as_result)
                switch_ref
            else
                p.body_result;

            break_indices[pi] = try b.addInst(.@"break", .{ .@"break" = .{
                .operand = result,
                .payload_index = break_payload_idx,
            } });
        }

        // ---- Phase 3: Emit dbg_stmt + switch_block (body_tracking ON) ----
        try self.emitBodyInstVoid(.dbg_stmt, .{ .dbg_stmt = .{
            .line = 0,
            .column = 0,
        } });

        const switch_idx: u32 = @intCast(b.tags.items.len);
        std.debug.assert(switch_idx == future_switch_idx);
        try b.tags.append(b.gpa, @intFromEnum(Zir.Inst.Tag.switch_block));
        try b.data.append(b.gpa, .{ .pl_node = .{ .src_node = .zero, .payload_index = 0 } });
        if (self.body_tracking) {
            try self.body_inst_indices.append(b.gpa, switch_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(b.gpa, switch_idx);
        }

        // ---- Phase 4: Write SwitchBlock extra data (contiguous) ----
        var any_non_inline_capture = false;
        for (prongs) |p| {
            if (p.has_capture) any_non_inline_capture = true;
        }

        const payload_idx: u32 = @intCast(b.extra.items.len);

        // SwitchBlock header
        try b.extra.append(b.gpa, @intFromEnum(operand));
        try b.extra.append(b.gpa, @bitCast(Zir.Inst.SwitchBlock.Bits{
            .has_multi_cases = false,
            .any_ranges = false,
            .has_else = false,
            .has_under = false,
            .has_continue = false,
            .any_maybe_runtime_capture = any_non_inline_capture,
            .payload_capture_inst_is_placeholder = false,
            .tag_capture_inst_is_placeholder = false,
            .scalar_cases_len = @intCast(prongs.len),
        }));

        // Scalar cases
        for (prongs, 0..) |p, pi| {
            // Item: enum literal Ref
            try b.extra.append(b.gpa, @intFromEnum(item_refs[pi]));

            // ProngInfo
            try b.extra.append(b.gpa, @bitCast(Zir.Inst.SwitchBlock.ProngInfo{
                .body_len = @intCast(p.body_insts.len + 1), // +1 for break
                .capture = if (p.has_capture) .by_val else .none,
                .is_inline = false,
                .has_tag_capture = false,
                .is_comptime_unreach = false,
            }));

            // Body instruction indices
            for (p.body_insts) |inst_i| {
                try b.extra.append(b.gpa, inst_i);
            }

            // break (last body instruction)
            try b.extra.append(b.gpa, break_indices[pi]);
        }

        // Patch switch_block instruction's payload_index
        b.data.items[switch_idx] = .{ .pl_node = .{
            .src_node = .zero,
            .payload_index = payload_idx,
        } };

        return Builder.instRef(switch_idx);
    }

    /// Emit a tagged union(enum) type declaration and store it as the return type.
    /// `variant_names` and `variant_types` are parallel arrays.
    /// A variant_type of `.none` means a void/unit variant.
    ///
    /// The union_decl ZIR extended instruction has this exact layout:
    ///   Extra[operand+0..5]: UnionDecl { fields_hash_0..3, src_line, src_node }
    ///   Trailing (ordered by Small flags):
    ///     [tag_type: Ref]          if has_tag_type
    ///     [captures_len: u32]      if has_captures_len
    ///     [body_len: u32]          if has_body_len
    ///     [fields_len: u32]        if has_fields_len
    ///     [decls_len: u32]         if has_decls_len
    ///     [captures...]            2 u32 per capture
    ///     [decls...]               1 u32 per decl
    ///     [body...]                1 u32 per body inst
    ///     [bit_bags...]            1 u32 per 8 fields (4 bits per field)
    ///     [field_data...]          per field: name + conditional type/align/tag
    pub fn setUnionReturnType(self: *FuncBody, variant_names: []const []const u8, variant_types: []const Zir.Inst.Ref) !void {
        std.debug.assert(variant_names.len == variant_types.len);
        const b = self.builder;
        const fields_len: u32 = @intCast(variant_names.len);

        // --- UnionDecl fixed payload (6 u32s) ---
        const union_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // fields_hash_0
        try b.extra.append(b.gpa, 0); // fields_hash_1
        try b.extra.append(b.gpa, 0); // fields_hash_2
        try b.extra.append(b.gpa, 0); // fields_hash_3
        try b.extra.append(b.gpa, 0); // src_line = 0
        try b.extra.append(b.gpa, 0); // src_node = 0

        const small: Zir.Inst.UnionDecl.Small = .{
            .has_captures_len = false,
            .has_decls_len = false,
            .has_fields_len = true,
            .name_strategy = .anon,
            .kind = .tagged_enum, // union(enum)
            .any_field_aligns = false,
            .any_field_values = false,
        };

        // --- Trailing conditional fields (ordered by flag bits) ---
        // has_captures_len=false → skip
        // has_decls_len=false → skip
        // has_fields_len=true → emit fields_len
        try b.extra.append(b.gpa, fields_len);
        // no more trailing fields

        // --- Captures (none) ---
        // --- Decls (none) ---
        // --- Body (none) ---

        // --- Bit bags: 4 bits per field, 8 fields per u32 ---
        // For each field: bit 0 = has_type, bit 1 = has_align, bit 2 = has_tag, bit 3 = unused
        // All our variants have types, no alignment, no explicit tag value.
        const num_bit_bags = (fields_len + 7) / 8;
        for (0..num_bit_bags) |bag_i| {
            var bit_bag: u32 = 0;
            const fields_in_bag = @min(fields_len - @as(u32, @intCast(bag_i)) * 8, 8);
            for (0..fields_in_bag) |field_in_bag| {
                const has_type: u32 = if (variant_types[bag_i * 8 + field_in_bag] != .none) 1 else 0;
                // has_align=0, has_tag=0, unused=0
                bit_bag |= has_type << @intCast(field_in_bag * 4);
            }
            try b.extra.append(b.gpa, bit_bag);
        }

        // --- Per-field data ---
        for (0..variant_names.len) |i| {
            // Field name (NullTerminatedString index)
            const name_idx = try b.internString(variant_names[i]);
            try b.extra.append(b.gpa, name_idx);
            // Field type (only if has_type bit is set)
            if (variant_types[i] != .none) {
                try b.extra.append(b.gpa, @intFromEnum(variant_types[i]));
            }
            // No align, no tag_value
        }

        const union_decl_idx = try b.addInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.union_decl), @bitCast(small), union_payload_idx),
        );

        // Store union_decl instruction index for the ret_ty body.
        // Unlike tuple_ret_types (which uses ret_ty.body_len=1 with a simple Ref),
        // union types must use ret_ty.body_len=2 with a body of
        // [union_decl, break_inline(func, union_decl)] to match AstGen's encoding.
        // The union_decl must NOT go in param_inst_indices because Sema reads
        // param_body[0..param_count] expecting param instructions there.
        self.union_ret_type_inst = union_decl_idx;
    }

    /// Emit `try operand` — unwrap an error union, panicking on error.
    /// Equivalent to `operand catch unreachable`.
    ///
    /// Emits a ZIR `.@"try"` instruction whose error body contains a single
    /// `@"unreachable"` instruction. The result is the unwrapped payload value.
    pub fn addTry(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // Emit unreachable instruction for the error body (NOT a body instruction).
        // The .@"unreachable" tag uses .@"unreachable" data: { src_node: Node.Offset }
        const unreachable_idx = try b.addInst(.@"unreachable", .{ .@"unreachable" = .{ .src_node = .zero } });

        // Try payload in extra: { operand: Ref, body_len: u32 }, trailing: [body_len] inst indices
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(operand)); // operand
        try b.extra.append(gpa, 1); // body_len = 1
        try b.extra.append(gpa, unreachable_idx); // body[0] = unreachable

        return self.emitBodyInst(.@"try", Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `operand catch catch_value` — unwrap an error union, using catch_value on error.
    ///
    /// Encodes: block { is_non_err check, condbr(then: unwrap+break, else: break catch_value) }
    pub fn addCatch(self: *FuncBody, operand: Zir.Inst.Ref, catch_value: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // Step 1: Reserve the block instruction index (we need it for breaks)
        const block_inst_idx: u32 = @intCast(b.tags.items.len);
        const block_inst = try b.addInst(.block, .{ .pl_node = .{ .src_node = .zero, .payload_index = 0 } });

        // Step 2: Emit is_non_err check (body instruction of the block)
        const is_non_err_inst = try b.addInst(.is_non_err, Builder.encodeUnNode(.zero, operand));

        // Step 3: Emit the "then" branch body: unwrap payload + break to block
        const payload_inst = try b.addInst(.err_union_payload_unsafe, Builder.encodeUnNode(.zero, operand));
        const then_break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @as(u32, @bitCast(@intFromEnum(Ast.Node.OptionalOffset.none))));
        try b.extra.append(gpa, block_inst_idx);
        const then_break = try b.addInst(.@"break", Builder.encodeBreak(Builder.instRef(payload_inst), then_break_payload_idx));

        // Step 4: Emit the "else" branch body: break to block with catch_value
        const else_break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @as(u32, @bitCast(@intFromEnum(Ast.Node.OptionalOffset.none))));
        try b.extra.append(gpa, block_inst_idx);
        const else_break = try b.addInst(.@"break", Builder.encodeBreak(catch_value, else_break_payload_idx));

        // Step 5: Emit condbr instruction
        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(Builder.instRef(is_non_err_inst)));
        try b.extra.append(gpa, 2); // then_body_len
        try b.extra.append(gpa, 1); // else_body_len
        try b.extra.append(gpa, payload_inst);
        try b.extra.append(gpa, then_break);
        try b.extra.append(gpa, else_break);
        const condbr_inst = try b.addInst(.condbr, Builder.encodePlNode(.zero, condbr_payload_idx));

        // Step 6: Fix up the block payload
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 2); // body_len = 2 (is_non_err + condbr)
        try b.extra.append(gpa, is_non_err_inst);
        try b.extra.append(gpa, condbr_inst);
        b.data.items[block_inst_idx] = .{ .pl_node = .{ .src_node = .zero, .payload_index = block_payload_idx } };

        // Add block to body/capture instructions
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, block_inst);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, block_inst);
        }

        return Builder.instRef(block_inst);
    }

    /// Emit `error.name` — an error value from an inferred error set.
    ///
    /// Emits a ZIR `.error_value` instruction with the given error name.
    pub fn addErrorValue(self: *FuncBody, name: []const u8) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // .error_value uses .str_tok data: { start: u32, tok: Token.Index }
        // start is the offset into string_bytes where the error name is stored.
        const str_start: u32 = @intCast(b.string_bytes.items.len);
        try b.string_bytes.appendSlice(gpa, name);
        try b.string_bytes.append(gpa, 0); // null terminator

        return self.emitBodyInst(.error_value, .{ .str_tok = .{
            .start = @enumFromInt(str_start),
            .src_tok = .zero,
        } });
    }

    /// Emit `return error.name` — returns an error value from the current function.
    ///
    /// Combines addErrorValue + addRetNode to return an error from a function
    /// whose return type is an error union.
    pub fn addReturnError(self: *FuncBody, name: []const u8) !void {
        const err_ref = try self.addErrorValue(name);
        try self.addRetNode(err_ref);
    }

    /// Mark this function as returning an optional type: `?T`
    /// where T is the current ret_type. Emits an optional_type instruction
    /// and stores it for the ret_ty body.
    pub fn setOptionalReturnType(self: *FuncBody) !void {
        const b = self.builder;
        const payload_type_ref: Zir.Inst.Ref = @enumFromInt(@intFromEnum(self.ret_type));

        // Emit optional_type instruction: .optional_type uses .un_node data
        const opt_type_inst = try b.addInst(.optional_type, Builder.encodeUnNode(.zero, payload_type_ref));
        self.error_union_ret_type_inst = opt_type_inst;
    }

    /// Set the return type to @import(module_name).field_name.
    /// Used for list types: @import("zap_runtime").ListType.
    pub fn setImportedReturnType(self: *FuncBody, module_name: []const u8, field_name: []const u8) !void {
        const b = self.builder;
        // Emit @import(module_name)
        const path_idx = try b.internString(module_name);
        const import_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @intFromEnum(Zir.Inst.Ref.none));
        try b.extra.append(b.gpa, path_idx);
        const import_inst = try b.addInst(.import, Builder.encodePlTok(.zero, import_payload_idx));
        const import_ref = Builder.instRef(import_inst);
        // Emit field_ptr_load(import, field_name)
        const field_name_idx = try b.internString(field_name);
        const field_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @intFromEnum(import_ref));
        try b.extra.append(b.gpa, field_name_idx);
        const field_inst = try b.addInst(.field_ptr_load, Builder.encodePlNode(.zero, field_payload_idx));
        self.imported_ret_import_inst = import_inst;
        self.imported_ret_type_inst = field_inst;
    }

    /// Emit `return null` — returns null from a function with optional return type.
    pub fn addReturnNull(self: *FuncBody) !void {
        try self.addRetNode(.null_value);
    }

    /// Mark this function as returning an error union type: `error{name}!T`
    /// where T is the current ret_type. Emits instructions for the error set
    /// and error union type, and stores them as a ret_ty body.
    ///
    /// Must be called after beginFunction but before any body instructions
    /// that depend on the return type.
    pub fn setErrorUnionReturnType(self: *FuncBody, _: []const u8) !void {
        const b = self.builder;
        const gpa = b.gpa;

        // Make the ret_ty body produce `anyerror!T` using anyerror_type Ref
        // and an error_union_type instruction. Zig will infer the specific
        // error set from the error_value returns in the function body.
        const payload_type_ref: Zir.Inst.Ref = @enumFromInt(@intFromEnum(self.ret_type));
        const anyerror_ref = Zir.Inst.Ref.anyerror_type;

        // Build the error_union_type: pl_node with Bin payload {lhs: error_set, rhs: payload_type}
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(anyerror_ref)); // lhs = anyerror
        try b.extra.append(gpa, @intFromEnum(payload_type_ref)); // rhs = payload type
        const error_union_inst = try b.addInst(.error_union_type, Builder.encodePlNode(.zero, payload_idx));

        // Store for endFunction to use in ret_ty body
        self.error_union_ret_type_inst = error_union_inst;
    }

    /// Emit a short-circuit boolean AND: if `lhs` is true, evaluate the rhs
    /// body and return its result; otherwise return false.
    ///
    /// Layout in extra:
    ///   BoolBr { .lhs = lhs, .body_len = rhs_insts.len + 1 }
    ///   followed by body_len instruction indices (rhs body + break_inline)
    ///
    /// The `bool_br_and` instruction itself acts as an implicit block; the
    /// break_inline targets it to deliver the rhs result.
    pub fn addBoolBrAnd(
        self: *FuncBody,
        lhs: Zir.Inst.Ref,
        rhs_insts: []const u32,
        rhs_result: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        return self.addBoolBrImpl(.bool_br_and, lhs, rhs_insts, rhs_result);
    }

    /// Emit a short-circuit boolean OR: if `lhs` is false, evaluate the rhs
    /// body and return its result; otherwise return true.
    ///
    /// Same payload layout as `addBoolBrAnd` but uses `.bool_br_or`.
    pub fn addBoolBrOr(
        self: *FuncBody,
        lhs: Zir.Inst.Ref,
        rhs_insts: []const u32,
        rhs_result: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        return self.addBoolBrImpl(.bool_br_or, lhs, rhs_insts, rhs_result);
    }

    /// Shared implementation for `addBoolBrAnd` and `addBoolBrOr`.
    fn addBoolBrImpl(
        self: *FuncBody,
        tag: Zir.Inst.Tag,
        lhs: Zir.Inst.Ref,
        rhs_insts: []const u32,
        rhs_result: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        const body_len: u32 = @intCast(rhs_insts.len + 1); // +1 for break_inline

        // 1. Emit the bool_br instruction with a placeholder payload index.
        //    We need its instruction index so the break_inline can reference it.
        const bool_br_idx = try b.addInst(tag, Builder.encodePlNode(.zero, 0)); // payload patched below

        // 2. Emit break_inline targeting the bool_br instruction.
        //    Break payload: { operand_src_node: i32(maxInt) = none, block_inst: bool_br_idx }
        const break_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, bool_br_idx); // block_inst = the bool_br itself
        const break_idx = try b.addInst(.break_inline, Builder.encodeBreak(rhs_result, break_payload_idx));

        // 3. Build the BoolBr payload in extra.
        const real_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(lhs)); // BoolBr.lhs
        try b.extra.append(gpa, body_len); // BoolBr.body_len

        // 4. Trailing body: rhs instruction indices followed by break_inline.
        for (rhs_insts) |idx| {
            try b.extra.append(gpa, idx);
        }
        try b.extra.append(gpa, break_idx);

        // 5. Patch the bool_br instruction's payload index to point to our BoolBr.
        b.data.items[bool_br_idx] = Builder.encodePlNode(.zero, real_payload_idx);

        // 6. Track the bool_br as a body instruction.
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, bool_br_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, bool_br_idx);
        }

        return Builder.instRef(bool_br_idx);
    }

    /// Emit an `alloc` instruction (immutable allocation).
    /// Allocates stack space for a value of the given type. After storing
    /// a value, `addMakePtrConst` should be called to freeze the pointer.
    /// Uses `un_node` field; operand is the type Ref.
    pub fn addAlloc(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.alloc, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit an `alloc_mut` instruction (mutable allocation).
    /// Same as `addAlloc` but the resulting pointer is mutable and does not
    /// require `make_ptr_const`.
    /// Uses `un_node` field; operand is the type Ref.
    pub fn addAllocMut(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.alloc_mut, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit a `load` instruction: dereference a pointer to get its value.
    /// Uses `un_node` field; operand is the pointer Ref.
    pub fn addLoad(self: *FuncBody, ptr_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.load, Builder.encodeUnNode(.zero, ptr_ref));
    }

    /// Emit a `make_ptr_const` instruction: freeze an `alloc` pointer into
    /// a constant pointer. Must be called after the value has been stored.
    /// Uses `un_node` field; operand is the alloc Ref.
    pub fn addMakePtrConst(self: *FuncBody, alloc_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.make_ptr_const, Builder.encodeUnNode(.zero, alloc_ref));
    }

    /// Emit `@Vector(len, elem_type)`. Returns a Ref to the vector type.
    /// ZIR tag: `.vector_type`, data: `pl_node`, payload: `Bin` { lhs=len, rhs=elem_type }.
    pub fn addVectorType(self: *FuncBody, len: Zir.Inst.Ref, elem_type: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.vector_type, len, elem_type);
    }

    /// Emit `@splat(dest_type, scalar)`. Returns a Ref to the splatted vector.
    /// ZIR tag: `.splat`, data: `pl_node`, payload: `Bin` { lhs=dest_type, rhs=scalar }.
    pub fn addSplat(self: *FuncBody, dest_type: Zir.Inst.Ref, scalar: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.splat, dest_type, scalar);
    }

    /// Emit `@shuffle(elem_type, a, b, mask)`. Returns a Ref to the shuffled vector.
    /// ZIR tag: `.shuffle`, data: `pl_node`, payload: `Shuffle`.
    pub fn addShuffle(self: *FuncBody, elem_type: Zir.Inst.Ref, a: Zir.Inst.Ref, b: Zir.Inst.Ref, mask: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(elem_type));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(a));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(b));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(mask));
        return self.emitBodyInst(.shuffle, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `@reduce(operation, operand)`. Returns a Ref to the reduced scalar.
    /// ZIR tag: `.reduce`, data: `pl_node`, payload: `Bin` { lhs=operation, rhs=operand }.
    pub fn addReduce(self: *FuncBody, operation: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.reduce, operation, operand);
    }

    /// Emit `operand[start..]` (slice with no end). Returns a Ref to the subslice.
    /// ZIR tag: `.slice_start`, data: `pl_node`, payload: `SliceStart`.
    pub fn addSliceStart(self: *FuncBody, operand: Zir.Inst.Ref, start: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(start));
        return self.emitBodyInst(.slice_start, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `operand[start..end]` (slice with end). Returns a Ref to the subslice.
    /// ZIR tag: `.slice_end`, data: `pl_node`, payload: `SliceEnd`.
    pub fn addSliceEnd(self: *FuncBody, operand: Zir.Inst.Ref, start: Zir.Inst.Ref, end: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(start));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(end));
        return self.emitBodyInst(.slice_end, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `operand[start..][0..length]` (slice with length). Returns a Ref to the subslice.
    /// ZIR tag: `.slice_length`, data: `pl_node`, payload: `SliceLength`.
    pub fn addSliceLength(self: *FuncBody, operand: Zir.Inst.Ref, start: Zir.Inst.Ref, length: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(start));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(length));
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(Zir.Inst.Ref.none)); // sentinel = none
        try self.builder.extra.append(self.builder.gpa, 0); // start_src_node_offset = 0
        return self.emitBodyInst(.slice_length, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Emit `E!T` (error union type). Returns a Ref to the error union type.
    /// ZIR tag: `.error_union_type`, data: `pl_node`, payload: `Bin` { lhs=error_set, rhs=payload }.
    pub fn addErrorUnionType(self: *FuncBody, error_set: Zir.Inst.Ref, payload: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.error_union_type, error_set, payload);
    }

    /// Emit `err_union_code(operand)` — extract the error code from an error union.
    /// ZIR tag: `.err_union_code`, data: `un_node`.
    pub fn addErrUnionCode(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.err_union_code, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@intFromError(operand)` — convert an error to its integer representation.
    /// Extended instruction: `.int_from_error`, operand is payload index to `UnNode`.
    pub fn addIntFromError(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, 0); // node = 0
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.int_from_error), 0, payload_idx),
        );
    }

    /// Emit `@errorFromInt(operand)` — convert an integer to an error value.
    /// Extended instruction: `.error_from_int`, operand is payload index to `UnNode`.
    pub fn addErrorFromInt(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, 0); // node = 0
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(operand));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.error_from_int), 0, payload_idx),
        );
    }

    /// Emit `@sizeOf(type_ref)`. Returns a Ref to the size value.
    /// ZIR tag: `.size_of`, data: `un_node`.
    pub fn addSizeOf(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.size_of, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit `@alignOf(type_ref)`. Returns a Ref to the alignment value.
    /// ZIR tag: `.align_of`, data: `un_node`.
    pub fn addAlignOf(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.align_of, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit `@bitSizeOf(type_ref)`. Returns a Ref to the bit size value.
    /// ZIR tag: `.bit_size_of`, data: `un_node`.
    pub fn addBitSizeOf(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.bit_size_of, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit `@offsetOf(type_ref, field_name)`. Returns a Ref to the offset value.
    /// ZIR tag: `.offset_of`, data: `pl_node`, payload: `Bin` { lhs=type, rhs=field_name_str }.
    pub fn addOffsetOf(self: *FuncBody, type_ref: Zir.Inst.Ref, field_name: []const u8) !Zir.Inst.Ref {
        const field_name_ref = try self.addStr(field_name);
        return self.addBinOp(.offset_of, type_ref, field_name_ref);
    }

    /// Emit `@tagName(operand)`. Returns a Ref to the tag name string.
    /// ZIR tag: `.tag_name`, data: `un_node`.
    pub fn addTagName(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.tag_name, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@typeName(type_ref)`. Returns a Ref to the type name string.
    /// ZIR tag: `.type_name`, data: `un_node`.
    pub fn addTypeName(self: *FuncBody, type_ref: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.type_name, Builder.encodeUnNode(.zero, type_ref));
    }

    /// Emit `@intFromPtr(operand)`. Returns a Ref to the usize integer.
    /// ZIR tag: `.int_from_ptr`, data: `un_node`.
    pub fn addIntFromPtr(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.int_from_ptr, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@ptrFromInt(type_ref, operand)`. Returns a Ref to the pointer.
    /// ZIR tag: `.ptr_from_int`, data: `pl_node`, payload: `Bin` { lhs=dest_type, rhs=operand }.
    pub fn addPtrFromInt(self: *FuncBody, dest_type: Zir.Inst.Ref, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.ptr_from_int, dest_type, operand);
    }

    /// Emit `@hasDecl(type_ref, name)`. Returns a bool Ref.
    /// ZIR tag: `.has_decl`, data: `pl_node`, payload: `Bin` { lhs=type, rhs=name_str }.
    pub fn addHasDecl(self: *FuncBody, type_ref: Zir.Inst.Ref, name: []const u8) !Zir.Inst.Ref {
        const name_ref = try self.addStr(name);
        return self.addBinOp(.has_decl, type_ref, name_ref);
    }

    /// Emit `@hasField(type_ref, name)`. Returns a bool Ref.
    /// ZIR tag: `.has_field`, data: `pl_node`, payload: `Bin` { lhs=type, rhs=name_str }.
    pub fn addHasField(self: *FuncBody, type_ref: Zir.Inst.Ref, name: []const u8) !Zir.Inst.Ref {
        const name_ref = try self.addStr(name);
        return self.addBinOp(.has_field, type_ref, name_ref);
    }

    /// Emit a `loop` instruction: an infinite loop whose body is the given
    /// instruction sequence. The body should contain a `repeat` instruction
    /// to jump back to the top, and a conditional break to exit.
    ///
    /// Layout in extra:
    ///   Block { .body_len = body_insts.len }
    ///   followed by body_len instruction indices
    pub fn addLoop(self: *FuncBody, body_insts: []const u32) !Zir.Inst.Ref {
        const b = self.builder;
        const gpa = b.gpa;

        // Build Block payload in extra: { body_len } followed by body indices.
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @as(u32, @intCast(body_insts.len))); // Block.body_len
        for (body_insts) |idx| {
            try b.extra.append(gpa, idx);
        }

        // Emit the loop instruction.
        const loop_idx = try b.addInst(.loop, Builder.encodePlNode(.zero, payload_idx));

        // Track as body instruction.
        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, loop_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, loop_idx);
        }

        return Builder.instRef(loop_idx);
    }

    /// Emit a `repeat` instruction: jump back to the beginning of the
    /// enclosing `loop` block. Uses the `node` field.
    pub fn addRepeat(self: *FuncBody) !void {
        const b = self.builder;
        const gpa = b.gpa;
        const repeat_idx = try b.addInst(.repeat, .{ .node = .zero });

        if (self.body_tracking) {
            try self.body_inst_indices.append(gpa, repeat_idx);
        } else if (self.non_body_capture) |capture| {
            try capture.append(gpa, repeat_idx);
        }
    }

    // ---- Math builtins (unary, un_node encoding) ----

    /// Emit `@sqrt(operand)`. Uses `un_node`.
    pub fn addSqrt(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.sqrt, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@sin(operand)`. Uses `un_node`.
    pub fn addSin(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.sin, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@cos(operand)`. Uses `un_node`.
    pub fn addCos(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.cos, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@exp(operand)`. Uses `un_node`.
    pub fn addExp(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.exp, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@exp2(operand)`. Uses `un_node`.
    pub fn addExp2(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.exp2, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@log(operand)`. Uses `un_node`.
    pub fn addLog(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.log, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@log2(operand)`. Uses `un_node`.
    pub fn addLog2(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.log2, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@log10(operand)`. Uses `un_node`.
    pub fn addLog10(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.log10, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@abs(operand)`. Uses `un_node`.
    pub fn addAbs(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.abs, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@floor(operand)`. Uses `un_node`.
    pub fn addFloor(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.floor, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@ceil(operand)`. Uses `un_node`.
    pub fn addCeil(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.ceil, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@round(operand)`. Uses `un_node`.
    pub fn addRound(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.round, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@trunc(operand)` (float truncation toward zero). Uses `un_node`.
    pub fn addTruncFloat(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.trunc, Builder.encodeUnNode(.zero, operand));
    }

    // ---- Saturating arithmetic (binary, pl_node with Bin payload) ----

    /// Emit saturating addition (`+|`). Uses `pl_node` with `Bin` payload.
    pub fn addAddSat(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.add_sat, lhs, rhs);
    }

    /// Emit saturating subtraction (`-|`). Uses `pl_node` with `Bin` payload.
    pub fn addSubSat(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.sub_sat, lhs, rhs);
    }

    /// Emit saturating multiplication (`*|`). Uses `pl_node` with `Bin` payload.
    pub fn addMulSat(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.mul_sat, lhs, rhs);
    }

    /// Emit saturating shift-left (`<<|`). Uses `pl_node` with `Bin` payload.
    pub fn addShlSat(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.shl_sat, lhs, rhs);
    }

    // ---- Overflow-detecting arithmetic (Extended with BinNode payload) ----

    /// Emit `@addWithOverflow(lhs, rhs)`. Returns a struct {result, overflow_bit}.
    /// Uses `.extended` with `Extended.add_with_overflow` and `BinNode` payload.
    pub fn addAddWithOverflow(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addOverflowOp(.add_with_overflow, lhs, rhs);
    }

    /// Emit `@subWithOverflow(lhs, rhs)`. Returns a struct {result, overflow_bit}.
    /// Uses `.extended` with `Extended.sub_with_overflow` and `BinNode` payload.
    pub fn addSubWithOverflow(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addOverflowOp(.sub_with_overflow, lhs, rhs);
    }

    /// Emit `@mulWithOverflow(lhs, rhs)`. Returns a struct {result, overflow_bit}.
    /// Uses `.extended` with `Extended.mul_with_overflow` and `BinNode` payload.
    pub fn addMulWithOverflow(self: *FuncBody, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addOverflowOp(.mul_with_overflow, lhs, rhs);
    }

    /// Shared implementation for overflow-detecting arithmetic builtins.
    /// These use `.extended` tag with a `BinNode` payload in extra:
    ///   { node: Ast.Node.Offset, lhs: Ref, rhs: Ref }
    fn addOverflowOp(self: *FuncBody, extended_tag: Zir.Inst.Extended, lhs: Zir.Inst.Ref, rhs: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // node = 0 (synthetic)
        try b.extra.append(b.gpa, @intFromEnum(lhs));
        try b.extra.append(b.gpa, @intFromEnum(rhs));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(extended_tag), 0, payload_idx),
        );
    }

    // ---- Bit manipulation (unary, un_node encoding) ----

    /// Emit `@clz(operand)`. Uses `un_node`.
    pub fn addClz(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.clz, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@ctz(operand)`. Uses `un_node`.
    pub fn addCtz(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.ctz, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@popCount(operand)`. Uses `un_node`.
    pub fn addPopCount(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.pop_count, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@byteSwap(operand)`. Uses `un_node`.
    pub fn addByteSwap(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.byte_swap, Builder.encodeUnNode(.zero, operand));
    }

    /// Emit `@bitReverse(operand)`. Uses `un_node`.
    pub fn addBitReverse(self: *FuncBody, operand: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.emitBodyInst(.bit_reverse, Builder.encodeUnNode(.zero, operand));
    }

    // ---- Type reification builtins ----

    /// Emit `@Int(signedness, bit_count)`.
    /// Uses `.reify_int` tag with `pl_node` data and `Bin` payload.
    /// `signedness` is a Ref to a signedness enum value, `bit_count` is a Ref to a u16 value.
    pub fn addReifyInt(self: *FuncBody, signedness: Zir.Inst.Ref, bit_count: Zir.Inst.Ref) !Zir.Inst.Ref {
        return self.addBinOp(.reify_int, signedness, bit_count);
    }

    /// Emit `@Struct(layout, backing_ty, field_names, field_types, field_attrs)`.
    /// Uses `.extended` tag with `Extended.reify_struct` and `ReifyStruct` payload.
    /// All parameters are Refs to comptime-resolved values.
    pub fn addReifyStruct(
        self: *FuncBody,
        layout: Zir.Inst.Ref,
        backing_ty: Zir.Inst.Ref,
        field_names: Zir.Inst.Ref,
        field_types: Zir.Inst.Ref,
        field_attrs: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // src_line
        try b.extra.append(b.gpa, 0); // node (absolute)
        try b.extra.append(b.gpa, @intFromEnum(layout));
        try b.extra.append(b.gpa, @intFromEnum(backing_ty));
        try b.extra.append(b.gpa, @intFromEnum(field_names));
        try b.extra.append(b.gpa, @intFromEnum(field_types));
        try b.extra.append(b.gpa, @intFromEnum(field_attrs));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.reify_struct), @intFromEnum(Zir.Inst.NameStrategy.anon), payload_idx),
        );
    }

    /// Emit `@Enum(tag_ty, mode, field_names, field_values)`.
    /// Uses `.extended` tag with `Extended.reify_enum` and `ReifyEnum` payload.
    /// All parameters are Refs to comptime-resolved values.
    pub fn addReifyEnum(
        self: *FuncBody,
        tag_ty: Zir.Inst.Ref,
        mode: Zir.Inst.Ref,
        field_names: Zir.Inst.Ref,
        field_values: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // src_line
        try b.extra.append(b.gpa, 0); // node (absolute)
        try b.extra.append(b.gpa, @intFromEnum(tag_ty));
        try b.extra.append(b.gpa, @intFromEnum(mode));
        try b.extra.append(b.gpa, @intFromEnum(field_names));
        try b.extra.append(b.gpa, @intFromEnum(field_values));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.reify_enum), @intFromEnum(Zir.Inst.NameStrategy.anon), payload_idx),
        );
    }

    /// Emit `@Union(layout, arg_ty, field_names, field_types, field_attrs)`.
    /// Uses `.extended` tag with `Extended.reify_union` and `ReifyUnion` payload.
    /// All parameters are Refs to comptime-resolved values.
    pub fn addReifyUnion(
        self: *FuncBody,
        layout: Zir.Inst.Ref,
        arg_ty: Zir.Inst.Ref,
        field_names: Zir.Inst.Ref,
        field_types: Zir.Inst.Ref,
        field_attrs: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // src_line
        try b.extra.append(b.gpa, 0); // node (absolute)
        try b.extra.append(b.gpa, @intFromEnum(layout));
        try b.extra.append(b.gpa, @intFromEnum(arg_ty));
        try b.extra.append(b.gpa, @intFromEnum(field_names));
        try b.extra.append(b.gpa, @intFromEnum(field_types));
        try b.extra.append(b.gpa, @intFromEnum(field_attrs));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.reify_union), @intFromEnum(Zir.Inst.NameStrategy.anon), payload_idx),
        );
    }

    /// Emit `@Pointer(size, attrs, elem_ty, sentinel)`.
    /// Uses `.extended` tag with `Extended.reify_pointer` and `ReifyPointer` payload.
    /// All parameters are Refs to comptime-resolved values.
    pub fn addReifyPointer(
        self: *FuncBody,
        size: Zir.Inst.Ref,
        attrs: Zir.Inst.Ref,
        elem_ty: Zir.Inst.Ref,
        sentinel: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // node
        try b.extra.append(b.gpa, @intFromEnum(size));
        try b.extra.append(b.gpa, @intFromEnum(attrs));
        try b.extra.append(b.gpa, @intFromEnum(elem_ty));
        try b.extra.append(b.gpa, @intFromEnum(sentinel));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.reify_pointer), 0, payload_idx),
        );
    }

    /// Emit `@Tuple(field_types)`.
    /// Uses `.extended` tag with `Extended.reify_tuple` and `UnNode` payload.
    /// `field_types` is a Ref to a comptime-resolved `[]const type` slice.
    pub fn addReifyTuple(self: *FuncBody, field_types: Zir.Inst.Ref) !Zir.Inst.Ref {
        const b = self.builder;
        const payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0); // node
        try b.extra.append(b.gpa, @intFromEnum(field_types));
        return self.emitBodyInst(
            .extended,
            Builder.encodeExtended(@intFromEnum(Zir.Inst.Extended.reify_tuple), 0, payload_idx),
        );
    }
};

pub const FinalizedZir = struct {
    instructions_tags: []const u8,
    instructions_data: []const u8,
    instructions_len: u32,
    string_bytes: []const u8,
    string_bytes_len: u32,
    extra: []const u32,
    extra_len: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "Builder: void main produces valid ZIR" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("main", .void);
    // Don't add explicit return - endFunction will add ret_implicit
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Should produce 6 instructions:
    // 0: extended(struct_decl)
    // 1: declaration
    // 2: restore_err_ret_index_unconditional
    // 3: ret_implicit
    // 4: func
    // 5: break_inline
    try std.testing.expectEqual(@as(u32, 6), result.instructions_len);

    // Verify instruction tags
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.extended), result.instructions_tags[0]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.declaration), result.instructions_tags[1]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.restore_err_ret_index_unconditional), result.instructions_tags[2]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ret_implicit), result.instructions_tags[3]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.func), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.break_inline), result.instructions_tags[5]);

    // String bytes should contain "\x00main\x00"
    try std.testing.expectEqual(@as(u32, 6), result.string_bytes_len);
    try std.testing.expectEqual(@as(u8, 0), result.string_bytes[0]);
    try std.testing.expectEqualStrings("main", result.string_bytes[1..5]);

    // Verify extra array structure
    // extra[0] = compile_errors = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[0]);
    // extra[1] = imports = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[1]);

    // Func payload starts at extra[2]
    // extra[2] = ret_ty = 0 (void, non-generic)
    try std.testing.expectEqual(@as(u32, 0), result.extra[2]);
    // extra[3] = param_block = 1 (declaration inst)
    try std.testing.expectEqual(@as(u32, 1), result.extra[3]);
    // extra[4] = body_len = 2
    try std.testing.expectEqual(@as(u32, 2), result.extra[4]);
    // extra[5] = body[0] = 2 (restore_err_ret_index_unconditional)
    try std.testing.expectEqual(@as(u32, 2), result.extra[5]);
    // extra[6] = body[1] = 3 (ret_implicit)
    try std.testing.expectEqual(@as(u32, 3), result.extra[6]);

    // Break payload at extra[14]
    // extra[14] = operand_src_node = 0x7FFFFFFF (OptionalOffset.none)
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), result.extra[14]);
    // extra[15] = block_inst = 1 (declaration)
    try std.testing.expectEqual(@as(u32, 1), result.extra[15]);

    // Declaration payload at extra[16]
    // extra[16..19] = src_hash = all zeros
    try std.testing.expectEqual(@as(u32, 0), result.extra[16]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[17]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[18]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[19]);
    // extra[20] = flags_0 = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[20]);
    // extra[21] = flags_1 = 0x38000000 (pub_const_simple)
    try std.testing.expectEqual(@as(u32, 0x38000000), result.extra[21]);
    // extra[22] = name index = 1 ("main")
    try std.testing.expectEqual(@as(u32, 1), result.extra[22]);
    // extra[23] = value_body_len = 2
    try std.testing.expectEqual(@as(u32, 2), result.extra[23]);
    // extra[24] = value_body[0] = 4 (func inst)
    try std.testing.expectEqual(@as(u32, 4), result.extra[24]);
    // extra[25] = value_body[1] = 5 (break_inline inst)
    try std.testing.expectEqual(@as(u32, 5), result.extra[25]);

    // StructDecl payload at extra[26]
    // extra[26..29] = fields_hash = all zeros
    try std.testing.expectEqual(@as(u32, 0), result.extra[26]);
    // extra[30] = src_line = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[30]);
    // extra[31] = src_node = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[31]);
    // extra[32] = decls_len = 1
    try std.testing.expectEqual(@as(u32, 1), result.extra[32]);
    // extra[33] = decl[0] = 1 (declaration inst)
    try std.testing.expectEqual(@as(u32, 1), result.extra[33]);

    // Total extra length should match reference: 34 entries
    try std.testing.expectEqual(@as(u32, 34), result.extra_len);
}

test "Builder: function with int constant" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("main", .void);
    const val = try body.addInt(42);
    _ = val; // unused for now, just verify it doesn't crash
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Should have: extended, declaration, restore_err_ret, int(42), ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);

    // Verify the int instruction is at index 3
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[3]);

    // Verify the int value is 42 in the data
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    try std.testing.expectEqual(@as(u64, 42), data_items[3].int);
}

test "Builder: addInt returns valid Ref" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("add_test", .void);
    const a = try body.addInt(10);
    const b = try body.addInt(20);

    // a should be inst[3] -> Ref(3 + 124 = 127)
    try std.testing.expectEqual(@as(u32, 127), @intFromEnum(a));
    // b should be inst[4] -> Ref(4 + 124 = 128)
    try std.testing.expectEqual(@as(u32, 128), @intFromEnum(b));

    // Use them in a binary op
    const sum = try body.addBinOp(.add, a, b);
    _ = sum;

    try builder.endFunction(body);
    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(10), int(20), add, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 9), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.add), result.instructions_tags[5]);
}

test "Builder: addFloat" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("float_test", .void);
    const val = try body.addFloat(3.14);
    _ = val;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, float(3.14), ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.float), result.instructions_tags[3]);
}

test "Builder: addStr" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("str_test", .void);
    const val = try body.addStr("hello");
    _ = val;
    try builder.endFunction(body);

    const result = try builder.finalize();

    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.str), result.instructions_tags[3]);

    // String bytes should contain: \x00 "hello" \x00 "str_test" \x00
    // "hello\x00" was interned first at index 1, then "str_test\x00" at index 7
    try std.testing.expectEqualStrings("hello", result.string_bytes[1..6]);
}

test "Builder: addBoolTrue and addBoolFalse return named refs" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("bool_test", .void);
    const t = body.addBoolTrue();
    const f = body.addBoolFalse();
    const v = body.addVoidValue();

    try std.testing.expectEqual(Zir.Inst.Ref.bool_true, t);
    try std.testing.expectEqual(Zir.Inst.Ref.bool_false, f);
    try std.testing.expectEqual(Zir.Inst.Ref.void_value, v);

    try builder.endFunction(body);
    _ = try builder.finalize();
}

test "Builder: addNegate and addBoolNot" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("unary_test", .void);
    const val = try body.addInt(42);
    const neg = try body.addNegate(val);
    _ = neg;
    const flag = body.addBoolTrue();
    const not_flag = try body.addBoolNot(flag);
    _ = not_flag;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int, negate, bool_not, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 9), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.negate), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.bool_not), result.instructions_tags[5]);
}

test "Builder: explicit return with value" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("ret_test", .void);
    const val = try body.addInt(99);
    try body.addRetNode(val);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(99), ret_node, func, break_inline
    // No ret_implicit because we used explicit return
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ret_node), result.instructions_tags[4]);
}

test "Builder: multiple functions" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body1 = try builder.beginFunction("foo", .void);
    try builder.endFunction(body1);

    const body2 = try builder.beginFunction("bar", .void);
    try builder.endFunction(body2);

    const result = try builder.finalize();

    // Two functions:
    // extended(struct_decl)
    // declaration(foo), restore_err_ret, ret_implicit, func, break_inline
    // declaration(bar), restore_err_ret, ret_implicit, func, break_inline
    // = 1 + 5 + 5 = 11
    try std.testing.expectEqual(@as(u32, 11), result.instructions_len);

    // Both "foo" and "bar" should be in string_bytes
    // \x00 "foo" \x00 "bar" \x00
    try std.testing.expectEqualStrings("foo", result.string_bytes[1..4]);
    try std.testing.expectEqualStrings("bar", result.string_bytes[5..8]);
}

test "Builder: addEnumLiteral" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("enum_test", .void);
    const lit = try body.addEnumLiteral("ok");
    _ = lit;
    try builder.endFunction(body);

    const result = try builder.finalize();

    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.enum_literal), result.instructions_tags[3]);
}

test "Builder: struct_decl extended encoding" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("main", .void);
    try builder.endFunction(body);
    const result = try builder.finalize();

    // Verify instruction 0 data encodes Extended.InstData correctly
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const ext = data_items[0].extended;

    try std.testing.expectEqual(Zir.Inst.Extended.struct_decl, ext.opcode);
    try std.testing.expectEqual(@as(u16, 0x0004), ext.small);
    // StructDecl payload should be at index 26 (after all func/decl payloads)
    try std.testing.expectEqual(@as(u32, 26), ext.operand);
}

test "Builder: addCall" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("call_test", .void);
    const arg = try body.addInt(42);
    const call_result = try body.addCall("some_func", &.{arg});
    _ = call_result;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), decl_val("some_func"), break_inline(arg), dbg_stmt, call, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 11), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.decl_val), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.call), result.instructions_tags[7]);
}

test "Builder: function with i64 return type" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("get_value", .i64_type);
    const val = try body.addInt(42);
    try body.addRetNode(val);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Should produce 7 instructions:
    // 0: extended(struct_decl)
    // 1: declaration
    // 2: restore_err_ret_index_unconditional
    // 3: int(42)
    // 4: ret_node
    // 5: func
    // 6: break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);

    // Func payload starts at extra[2]
    // extra[2] = ret_ty = 1 (body_len=1, is_generic=false)
    try std.testing.expectEqual(@as(u32, 1), result.extra[2]);
    // extra[3] = param_block = 1 (declaration inst)
    try std.testing.expectEqual(@as(u32, 1), result.extra[3]);
    // extra[4] = body_len = 3 (restore_err_ret, int(42), ret_node)
    try std.testing.expectEqual(@as(u32, 3), result.extra[4]);

    // extra[5] = trailing return type Ref (i64_type)
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.i64_type), result.extra[5]);

    // extra[6] = body[0] = 2 (restore_err_ret_index_unconditional)
    try std.testing.expectEqual(@as(u32, 2), result.extra[6]);
    // extra[7] = body[1] = 3 (int(42))
    try std.testing.expectEqual(@as(u32, 3), result.extra[7]);
    // extra[8] = body[2] = 4 (ret_node)
    try std.testing.expectEqual(@as(u32, 4), result.extra[8]);

    // SrcLocs at extra[9..11]
    try std.testing.expectEqual(@as(u32, 0), result.extra[9]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[10]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[11]);

    // proto_hash at extra[12..15]
    try std.testing.expectEqual(@as(u32, 0), result.extra[12]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[13]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[14]);
    try std.testing.expectEqual(@as(u32, 0), result.extra[15]);

    // Break payload at extra[16] (shifted by 1 compared to void case due to ret type Ref)
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), result.extra[16]);
    try std.testing.expectEqual(@as(u32, 1), result.extra[17]);
}

test "Builder: function with u8 return type" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("get_byte", .u8_type);
    const val = try body.addInt(255);
    try body.addRetNode(val);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Verify ret_ty is 1 (body_len=1, non-generic)
    try std.testing.expectEqual(@as(u32, 1), result.extra[2]);
    // Verify trailing return type Ref is u8_type
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.u8_type), result.extra[5]);
}

test "Builder: addImport" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_import", .void);
    const std_mod = try body.addImport("std");
    _ = std_mod;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, import, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);

    // Verify the import instruction is at index 3
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.import), result.instructions_tags[3]);

    // Verify import payload in extra
    // extra[2] = Import.res_ty = Ref.none (0xFFFFFFFF)
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.none), result.extra[2]);
    // extra[3] = Import.path = string index of "std"
    const path_idx = result.extra[3];
    try std.testing.expectEqualStrings("std", result.string_bytes[path_idx .. path_idx + 3]);
}

test "Builder: addFieldPtrLoad" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_field", .void);
    const obj = try body.addInt(42);
    const field = try body.addFieldPtrLoad(obj, "some_field");
    _ = field;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), field_ptr_load, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 8), result.instructions_len);

    // Verify the field_ptr_load instruction is at index 4
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.field_ptr_load), result.instructions_tags[4]);

    // Verify Field payload in extra
    // The payload starts at extra[2]:
    // extra[2] = Field.lhs = Ref of int(42) instruction
    try std.testing.expectEqual(@intFromEnum(obj), result.extra[2]);
    // extra[3] = Field.field_name_start = string index of "some_field"
    const name_idx = result.extra[3];
    try std.testing.expectEqualStrings("some_field", result.string_bytes[name_idx .. name_idx + 10]);
}

test "Builder: addStructInitAnon" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_struct", .void);
    const val_a = try body.addInt(1);
    const val_b = try body.addInt(2);
    const init = try body.addStructInitAnon(
        &.{ "x", "y" },
        &.{ val_a, val_b },
    );
    _ = init;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(1), int(2), struct_init_anon, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 9), result.instructions_len);

    // Verify the struct_init_anon instruction is at index 5
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.struct_init_anon), result.instructions_tags[5]);

    // Verify StructInitAnon payload in extra
    // extra[2] = abs_node = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[2]);
    // extra[3] = abs_line = 0
    try std.testing.expectEqual(@as(u32, 0), result.extra[3]);
    // extra[4] = fields_len = 2
    try std.testing.expectEqual(@as(u32, 2), result.extra[4]);

    // Trailing items:
    // extra[5] = field_name "x" string index
    const name_x_idx = result.extra[5];
    try std.testing.expectEqualStrings("x", result.string_bytes[name_x_idx .. name_x_idx + 1]);
    // extra[6] = init Ref for val_a
    try std.testing.expectEqual(@intFromEnum(val_a), result.extra[6]);
    // extra[7] = field_name "y" string index
    const name_y_idx = result.extra[7];
    try std.testing.expectEqualStrings("y", result.string_bytes[name_y_idx .. name_y_idx + 1]);
    // extra[8] = init Ref for val_b
    try std.testing.expectEqual(@intFromEnum(val_b), result.extra[8]);
}

test "Builder: addCallRef" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_call_ref", .void);
    const mod = try body.addImport("std");
    const func_ref = try body.addFieldPtrLoad(mod, "debug");
    const arg = try body.addInt(42);
    const call_result = try body.addCallRef(func_ref, &.{arg});
    _ = call_result;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, import, field_ptr_load, int(42), break_inline(arg), dbg_stmt, call, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 12), result.instructions_len);

    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.import), result.instructions_tags[3]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.field_ptr_load), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[5]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.call), result.instructions_tags[8]);
}

test "Builder: addIfElse" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_if", .u8_type);
    const cond = body.addBoolTrue();
    const then_val = try body.addInt(1);
    const else_val = try body.addInt(0);
    const result_ref = try body.addIfElse(cond, then_val, else_val);
    try body.addRetNode(result_ref);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Instructions layout:
    // 0: extended(struct_decl)
    // 1: declaration
    // 2: restore_err_ret_index_unconditional
    // 3: int(1)
    // 4: int(0)
    // 5: block_inline        <- body instruction
    // 6: break_inline (then) <- NOT a body instruction, referenced from condbr extra
    // 7: break_inline (else) <- NOT a body instruction, referenced from condbr extra
    // 8: condbr              <- NOT a body instruction, referenced from block extra
    // 9: ret_node
    // 10: func
    // 11: break_inline (func)
    try std.testing.expectEqual(@as(u32, 12), result.instructions_len);

    // Verify instruction tags — using non-inline block/condbr/break for runtime support
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[3]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.block), result.instructions_tags[5]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.@"break"), result.instructions_tags[6]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.@"break"), result.instructions_tags[7]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.condbr), result.instructions_tags[8]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ret_node), result.instructions_tags[9]);

    // Verify block_inline's extra payload
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const block_data = data_items[5].pl_node;
    const block_payload_idx = block_data.payload_index;

    // Block payload: { body_len: u32 } + body indices
    try std.testing.expectEqual(@as(u32, 1), result.extra[block_payload_idx]); // body_len = 1
    try std.testing.expectEqual(@as(u32, 8), result.extra[block_payload_idx + 1]); // body[0] = condbr at index 8

    // Verify condbr's extra payload
    const condbr_data = data_items[8].pl_node;
    const condbr_payload_idx = condbr_data.payload_index;

    // CondBr payload: { condition: Ref, then_body_len: u32, else_body_len: u32 }
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.bool_true), result.extra[condbr_payload_idx]); // condition
    try std.testing.expectEqual(@as(u32, 1), result.extra[condbr_payload_idx + 1]); // then_body_len = 1
    try std.testing.expectEqual(@as(u32, 1), result.extra[condbr_payload_idx + 2]); // else_body_len = 1
    try std.testing.expectEqual(@as(u32, 6), result.extra[condbr_payload_idx + 3]); // then body[0] = break_inline at index 6
    try std.testing.expectEqual(@as(u32, 7), result.extra[condbr_payload_idx + 4]); // else body[0] = break_inline at index 7

    // Verify break_inline (then) carries then_val
    const break_then_data = data_items[6].@"break";
    try std.testing.expectEqual(then_val, break_then_data.operand);

    // Verify break_inline (else) carries else_val
    const break_else_data = data_items[7].@"break";
    try std.testing.expectEqual(else_val, break_else_data.operand);

    // Both break_inline Break payloads should reference the block_inline instruction
    const break_then_payload_idx = break_then_data.payload_index;
    try std.testing.expectEqual(@as(u32, 5), result.extra[break_then_payload_idx + 1]); // block_inst = 5

    const break_else_payload_idx = break_else_data.payload_index;
    try std.testing.expectEqual(@as(u32, 5), result.extra[break_else_payload_idx + 1]); // block_inst = 5

    // The result Ref should point to the block_inline instruction
    try std.testing.expectEqual(Builder.instRef(5), result_ref);
}

test "Builder: addElemValImm" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_elem", .void);
    const tuple = try body.addInt(0); // placeholder for a tuple value
    const elem = try body.addElemValImm(tuple, 2);
    _ = elem;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(0), elem_val_imm, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 8), result.instructions_len);

    // Verify the elem_val_imm instruction is at index 4
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.elem_val_imm), result.instructions_tags[4]);

    // Verify elem_val_imm data fields
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const elem_data = data_items[4].elem_val_imm;
    try std.testing.expectEqual(tuple, elem_data.operand);
    try std.testing.expectEqual(@as(u32, 2), elem_data.idx);
}

test "Builder: addArrayInitAnon" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_array", .void);
    const val_a = try body.addInt(10);
    const val_b = try body.addInt(20);
    const val_c = try body.addInt(30);
    const arr = try body.addArrayInitAnon(&.{ val_a, val_b, val_c });
    _ = arr;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(10), int(20), int(30), array_init_anon, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 10), result.instructions_len);

    // Verify the array_init_anon instruction is at index 6
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.array_init_anon), result.instructions_tags[6]);

    // Verify MultiOp payload in extra
    // extra[2] = operands_len = 3
    try std.testing.expectEqual(@as(u32, 3), result.extra[2]);
    // extra[3] = Ref for val_a
    try std.testing.expectEqual(@intFromEnum(val_a), result.extra[3]);
    // extra[4] = Ref for val_b
    try std.testing.expectEqual(@intFromEnum(val_b), result.extra[4]);
    // extra[5] = Ref for val_c
    try std.testing.expectEqual(@intFromEnum(val_c), result.extra[5]);
}

test "Builder: addEnsureResultUsed" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_ensure", .void);
    const val = try body.addInt(42);
    try body.addEnsureResultUsed(val);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), ensure_result_used, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 8), result.instructions_len);

    // Verify the ensure_result_used instruction is at index 4
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ensure_result_used), result.instructions_tags[4]);

    // Verify un_node data
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const ensure_data = data_items[4].un_node;
    try std.testing.expectEqual(val, ensure_data.operand);
}

test "Builder: addDbgStmt" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_dbg", .void);
    try body.addDbgStmt(10, 5);
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, dbg_stmt, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);

    // Verify the dbg_stmt instruction is at index 3
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.dbg_stmt), result.instructions_tags[3]);

    // Verify dbg_stmt data (LineColumn)
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const dbg_data = data_items[3].dbg_stmt;
    try std.testing.expectEqual(@as(u32, 10), dbg_data.line);
    try std.testing.expectEqual(@as(u32, 5), dbg_data.column);
}

test "Builder: addTypeOf" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_typeof", .void);
    const val = try body.addInt(42);
    const ty = try body.addTypeOf(val);
    _ = ty;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), typeof, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 8), result.instructions_len);

    // Verify the typeof instruction is at index 4
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.typeof), result.instructions_tags[4]);

    // Verify un_node data — operand should be the int(42) Ref
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const typeof_data = data_items[4].un_node;
    try std.testing.expectEqual(val, typeof_data.operand);
}

test "Builder: addFieldPtr and addStore" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_field_ptr_store", .void);

    // Create a struct
    const val_a = try body.addInt(1);
    const val_b = try body.addInt(2);
    const s = try body.addStructInitAnon(
        &.{ "x", "y" },
        &.{ val_a, val_b },
    );

    // Get a field pointer
    const fptr = try body.addFieldPtr(s, "x");

    // Store a new value through the pointer
    const new_val = try body.addInt(99);
    try body.addStore(fptr, new_val);

    try builder.endFunction(body);
    const result = try builder.finalize();

    // Instructions:
    // 0: extended(struct_decl)
    // 1: declaration
    // 2: restore_err_ret
    // 3: int(1)
    // 4: int(2)
    // 5: struct_init_anon
    // 6: field_ptr
    // 7: int(99)
    // 8: store_node
    // 9: ret_implicit
    // 10: func
    // 11: break_inline
    try std.testing.expectEqual(@as(u32, 12), result.instructions_len);

    // Verify the field_ptr instruction
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.field_ptr), result.instructions_tags[6]);

    // Verify Field payload for field_ptr
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const fptr_data = data_items[6].pl_node;
    const fptr_payload_idx = fptr_data.payload_index;
    // Field.lhs = Ref of struct_init_anon
    try std.testing.expectEqual(@intFromEnum(s), result.extra[fptr_payload_idx]);
    // Field.field_name_start = string index of "x"
    const name_idx = result.extra[fptr_payload_idx + 1];
    try std.testing.expectEqualStrings("x", result.string_bytes[name_idx .. name_idx + 1]);

    // Verify the store_node instruction
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.store_node), result.instructions_tags[8]);

    // Verify Bin payload for store_node
    const store_data = data_items[8].pl_node;
    const store_payload_idx = store_data.payload_index;
    // Bin.lhs = ptr (field_ptr Ref)
    try std.testing.expectEqual(@intFromEnum(fptr), result.extra[store_payload_idx]);
    // Bin.rhs = value (new_val Ref)
    try std.testing.expectEqual(@intFromEnum(new_val), result.extra[store_payload_idx + 1]);
}

test "Builder: addIsNonNull and addOptionalPayloadSafe" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_optional", .void);

    // Use a param to represent an optional value
    const opt_val = try body.addParam("maybe", Zir.Inst.Ref.usize_type);

    // Check if non-null
    const check = try body.addIsNonNull(opt_val);

    // Extract optional payload
    const payload = try body.addOptionalPayloadSafe(opt_val);

    _ = check;
    _ = payload;

    try builder.endFunction(body);
    const result = try builder.finalize();

    // Instructions:
    // 0: extended(struct_decl)
    // 1: declaration
    // 2: restore_err_ret
    // 3: break_inline (param type body)
    // 4: param
    // 5: is_non_null
    // 6: optional_payload_safe
    // 7: ret_implicit
    // 8: func
    // 9: break_inline (func)
    try std.testing.expectEqual(@as(u32, 10), result.instructions_len);

    // Verify is_non_null instruction
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.is_non_null), result.instructions_tags[5]);

    // Verify un_node data for is_non_null — operand should be the param Ref
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const is_nn_data = data_items[5].un_node;
    try std.testing.expectEqual(opt_val, is_nn_data.operand);

    // Verify optional_payload_safe instruction
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.optional_payload_safe), result.instructions_tags[6]);

    // Verify un_node data for optional_payload_safe
    const payload_data = data_items[6].un_node;
    try std.testing.expectEqual(opt_val, payload_data.operand);
}

test "Builder: addAs and addPtrCast" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_casts", .void);
    const value = try body.addParam("value", Zir.Inst.Ref.usize_type);
    const casted = try body.addAs(Zir.Inst.Ref.anyopaque_type, value);
    const ptr_casted = try body.addPtrCast(Zir.Inst.Ref.anyopaque_type, casted);
    _ = ptr_casted;

    try builder.endFunction(body);
    const result = try builder.finalize();

    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));

    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.as_node), result.instructions_tags[5]);
    const as_payload_idx = data_items[5].pl_node.payload_index;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.anyopaque_type), result.extra[as_payload_idx]);
    try std.testing.expectEqual(@intFromEnum(value), result.extra[as_payload_idx + 1]);

    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ptr_cast), result.instructions_tags[6]);
    const ptr_payload_idx = data_items[6].pl_node.payload_index;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Ref.anyopaque_type), result.extra[ptr_payload_idx]);
    try std.testing.expectEqual(@intFromEnum(casted), result.extra[ptr_payload_idx + 1]);
}

test "Builder: addAlignCast emits ptr_cast_full" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_align_cast", .void);
    const value = try body.addParam("value", Zir.Inst.Ref.anyopaque_type);
    _ = try body.addAlignCast(Zir.Inst.Ref.anyopaque_type, value);

    try builder.endFunction(body);
    const result = try builder.finalize();

    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.extended), result.instructions_tags[5]);
    const ext = data_items[5].extended;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Extended.ptr_cast_full), @intFromEnum(ext.opcode));

    const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(ext.small)));
    try std.testing.expect(flags.align_cast);
}

test "Builder: addSwitchBlock extra data layout" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_switch", .slice_const_u8_type);

    // Emit a string as the operand (fake union value)
    const operand = try body.addStr("test");

    // Build prong results (these would be pre-emitted body instructions)
    const ok_result = try body.addStr("ok_value");
    const err_result = try body.addStr("err_value");

    // Single-pass switch emission
    const prongs = [_]FuncBody.SwitchProng{
        .{ .item_name = "Ok", .has_capture = true, .body_insts = &.{}, .body_result = ok_result },
        .{ .item_name = "Error", .has_capture = true, .body_insts = &.{}, .body_result = err_result },
    };

    const result = try body.addSwitchBlock(operand, &prongs);
    try std.testing.expect(@intFromEnum(result) > 0);

    // Find the switch_block instruction index
    const switch_idx = @intFromEnum(result) - @intFromEnum(Zir.Inst.Index.ref_start_index);

    // Verify tag
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.switch_block), builder.tags.items[switch_idx]);

    // Verify extra data layout
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, @as([]const u8, std.mem.sliceAsBytes(builder.data.items))));
    const payload_idx = data_items[switch_idx].pl_node.payload_index;
    const extra = builder.extra.items;

    // extra[payload_idx+0] = operand Ref
    try std.testing.expectEqual(@intFromEnum(operand), extra[payload_idx]);

    // extra[payload_idx+1] = bits
    const bits: Zir.Inst.SwitchBlock.Bits = @bitCast(extra[payload_idx + 1]);
    try std.testing.expectEqual(@as(u25, 2), bits.scalar_cases_len);
    try std.testing.expect(bits.any_non_inline_capture);

    // extra[payload_idx+2] = first case item Ref (should be an enum_literal for "Ok")
    // Verify it's a valid instruction Ref (not zero/none)
    try std.testing.expect(extra[payload_idx + 2] > 0);

    // extra[payload_idx+3] = ProngInfo for first case
    const prong0_info: Zir.Inst.SwitchBlock.ProngInfo = @bitCast(extra[payload_idx + 3]);
    try std.testing.expectEqual(@as(u28, 1), prong0_info.body_len); // 0 body + 1 break
    try std.testing.expectEqual(Zir.Inst.SwitchBlock.ProngInfo.Capture.by_val, prong0_info.capture);
}
