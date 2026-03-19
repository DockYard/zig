const std = @import("std");
const Zir = std.zig.Zir;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

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

    pub fn init(gpa: Allocator) !Builder {
        var self = Builder{
            .gpa = gpa,
            .tags = .{},
            .data = .{},
            .extra = .{},
            .string_bytes = .{},
            .decl_indices = .{},
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
        if (self.active_body) |body| {
            body.body_inst_indices.deinit(self.gpa);
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
    /// Instruction refs start at ref_start_index = 124.
    pub fn instRef(index: u32) Zir.Inst.Ref {
        return @enumFromInt(@as(u32, @intFromEnum(Zir.Inst.Index.ref_start_index)) + index);
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
            .body_inst_indices = .{},
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

        // Build Func payload in extra
        // Func struct: ret_ty (u32), param_block (Index), body_len (u32)
        // Trailing: [return type Ref if ret_ty.body_len==1], body indices, SrcLocs (3 u32s), proto_hash (4 u32s)
        const func_payload_idx: u32 = @intCast(self.extra.items.len);

        // ret_ty: packed RetTy { body_len: u31, is_generic: bool }
        if (body.ret_type == .void) {
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

        // Trailing return type Ref (if ret_ty.body_len == 1)
        if (body.ret_type != .void) {
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

        // value_body_len: 2 (func + break_inline)
        try self.extra.append(self.gpa, 2);

        // value_body[0]: func instruction index
        try self.extra.append(self.gpa, func_inst);

        // value_body[1]: break_inline instruction index
        try self.extra.append(self.gpa, break_inst);

        // Fix up declaration instruction with real payload index
        self.data.items[decl_inst] = encodeDeclaration(0, decl_payload_idx);

        // Track this declaration for the root struct_decl
        try self.decl_indices.append(self.gpa, decl_inst);

        // Clean up
        body.body_inst_indices.deinit(self.gpa);
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
        const small: u16 = 0x0004; // StructDecl.Small with has_decls_len = true (bit 2)
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

    fn encodeExtended(opcode: u16, small: u16, operand: u32) Zir.Inst.Data {
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
};

/// Accumulates function body instructions. Instructions are emitted eagerly
/// into the Builder's instruction arrays so that valid Refs can be returned
/// for use by subsequent instructions.
pub const FuncBody = struct {
    builder: *Builder,
    /// Tracks which instruction indices belong to this function's body
    body_inst_indices: std.ArrayListUnmanaged(u32),
    name: []const u8,
    decl_inst: u32,
    restore_inst: u32,
    has_explicit_return: bool,
    ret_type: ReturnType,

    /// Emit an instruction into the builder and track it as a body instruction.
    /// Returns the Ref pointing to this instruction.
    fn emitBodyInst(self: *FuncBody, tag: Zir.Inst.Tag, inst_data: Zir.Inst.Data) !Zir.Inst.Ref {
        const idx = try self.builder.addInst(tag, inst_data);
        try self.body_inst_indices.append(self.builder.gpa, idx);
        return Builder.instRef(idx);
    }

    /// Emit an instruction into the builder body but don't return a Ref (for void ops).
    fn emitBodyInstVoid(self: *FuncBody, tag: Zir.Inst.Tag, inst_data: Zir.Inst.Data) !void {
        const idx = try self.builder.addInst(tag, inst_data);
        try self.body_inst_indices.append(self.builder.gpa, idx);
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
    /// Uses the `.field_val` instruction with `.pl_node` data and `Field` payload.
    pub fn addFieldVal(self: *FuncBody, object: Zir.Inst.Ref, field_name: []const u8) !Zir.Inst.Ref {
        const name_idx = try self.builder.internString(field_name);
        // Field payload in extra: { lhs: Ref, field_name_start: NullTerminatedString }
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(object));
        try self.builder.extra.append(self.builder.gpa, name_idx);
        return self.emitBodyInst(.field_val, Builder.encodePlNode(.zero, payload_idx));
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

    /// Emit a call using a Ref as the callee (e.g. from import + field access).
    /// Returns a Ref to the result.
    ///
    /// For each arg, clones the original instruction as a separate non-body
    /// instruction for the arg body (Sema requires arg body instructions to
    /// be distinct from the function body).
    pub fn addCallRef(self: *FuncBody, callee: Zir.Inst.Ref, args: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        // Pre-compute where the call instruction will be:
        // After 2 non-body instructions per arg (value_clone + break_inline)
        const call_inst_idx: u32 = @intCast(self.builder.tags.items.len + 2 * args.len);

        // Each arg body = [value_clone, break_inline(call, value_ref)]
        // Matching AstGen's exact pattern.
        var arg_inst_indices = std.ArrayListUnmanaged(u32).empty;
        defer arg_inst_indices.deinit(self.builder.gpa);

        for (args) |arg| {
            // Emit a fresh int(0) as the arg value instruction.
            // The break_inline will carry the actual arg value as its operand.
            const val_idx = try self.builder.addInst(.int, Builder.encodeInt(0));
            try arg_inst_indices.append(self.builder.gpa, val_idx);

            // break_inline targeting the call, returning the ORIGINAL arg value
            const val_ref = arg;
            const brk_payload = try self.builder.addExtraSlice(&.{
                0, // operand_src_node (can be 0 for synthetic ZIR)
                call_inst_idx, // block_inst = call instruction
            });
            const brk_idx = try self.builder.addInst(.break_inline, Builder.encodeBreak(val_ref, brk_payload));
            try arg_inst_indices.append(self.builder.gpa, brk_idx);
        }

        // Call payload
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        const args_len: u32 = @intCast(args.len);
        const flags: u32 = args_len << 5;
        try self.builder.extra.append(self.builder.gpa, flags);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(callee));

        // arg_end: cumulative, each arg body has 2 instructions
        // arg_end[i] = args_len + 2*(i+1)
        for (0..args.len) |i| {
            try self.builder.extra.append(self.builder.gpa, @as(u32, @intCast(args_len + 2 * (i + 1))));
        }

        for (arg_inst_indices.items) |idx| {
            try self.builder.extra.append(self.builder.gpa, idx);
        }

        const call_idx_u32: u32 = @intCast(self.builder.tags.items.len);
        const call_result = try self.emitBodyInst(.call, Builder.encodePlNode(.zero, payload_idx));
        // Debug: dump arg body layout
        std.debug.print("addCallRef: call_inst={d} call_inst_precomputed={d} args_len={d}\n", .{ call_idx_u32, call_inst_idx, args_len });
        for (arg_inst_indices.items, 0..) |idx, j| {
            const t: Zir.Inst.Tag = @enumFromInt(self.builder.tags.items[idx]);
            std.debug.print("  arg_body[{d}]: inst[{d}] tag={s}\n", .{ j, idx, @tagName(t) });
        }
        std.debug.print("  extra payload at {d}: flags={d} callee={d} total_extra={d}\n", .{ payload_idx, self.builder.extra.items[payload_idx], self.builder.extra.items[payload_idx + 1], self.builder.extra.items.len });
        // Dump extra around payload
        {
            var ei: u32 = payload_idx;
            while (ei < @min(payload_idx + 10, self.builder.extra.items.len)) : (ei += 1) {
                std.debug.print("  extra[{d}]={d}\n", .{ ei, self.builder.extra.items[ei] });
            }
        }
        // Also dump all instruction tags
        std.debug.print("  Total instructions: {d}\n", .{self.builder.tags.items.len});
        for (self.builder.tags.items, 0..) |t, ti| {
            const tag: Zir.Inst.Tag = @enumFromInt(t);
            std.debug.print("  inst[{d}]: {s}\n", .{ ti, @tagName(tag) });
        }
        for (0..args.len) |ai| {
            std.debug.print("  arg_end[{d}]={d}\n", .{ ai, self.builder.extra.items[payload_idx + 2 + ai] });
        }
        for (0..arg_inst_indices.items.len) |ai| {
            std.debug.print("  trailing[{d}]={d}\n", .{ ai, self.builder.extra.items[payload_idx + 2 + args.len + ai] });
        }
        return call_result;
    }

    /// Add a function call by name. Returns a Ref to the result.
    pub fn addCall(self: *FuncBody, callee_name: []const u8, args: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        // First, resolve callee via decl_val
        const name_start = try self.builder.internString(callee_name);
        const callee_ref = try self.emitBodyInst(.decl_val, Builder.encodeStrTok(name_start, .zero));

        // Pre-compute call instruction index (after decl_val + 2*N non-body instructions)
        const call_inst_idx: u32 = @intCast(self.builder.tags.items.len + 2 * @as(u32, @intCast(args.len)));

        // Each arg body = [value_clone, break_inline] matching AstGen pattern
        var arg_inst_indices = std.ArrayListUnmanaged(u32).empty;
        defer arg_inst_indices.deinit(self.builder.gpa);

        const ref_base = @intFromEnum(Zir.Inst.Index.ref_start_index);
        for (args) |arg| {
            const ref_int = @intFromEnum(arg);
            const val_idx = if (ref_int >= ref_base) blk: {
                const orig_idx = ref_int - ref_base;
                const tag: Zir.Inst.Tag = @enumFromInt(self.builder.tags.items[orig_idx]);
                const data = self.builder.data.items[orig_idx];
                break :blk try self.builder.addInst(tag, data);
            } else blk: {
                break :blk try self.builder.addInst(.int, Builder.encodeInt(0));
            };
            try arg_inst_indices.append(self.builder.gpa, val_idx);

            const val_ref = if (ref_int >= ref_base) Builder.instRef(val_idx) else arg;
            const brk_payload = try self.builder.addExtraSlice(&.{ 0, call_inst_idx });
            const brk_idx = try self.builder.addInst(.break_inline, Builder.encodeBreak(val_ref, brk_payload));
            try arg_inst_indices.append(self.builder.gpa, brk_idx);
        }

        const payload_idx: u32 = @intCast(self.builder.extra.items.len);
        const args_len: u32 = @intCast(args.len);
        const flags: u32 = args_len << 5;
        try self.builder.extra.append(self.builder.gpa, flags);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(callee_ref));

        // arg_end: cumulative, 2 instructions per arg
        for (0..args.len) |i| {
            try self.builder.extra.append(self.builder.gpa, @as(u32, @intCast(args_len + 2 * (i + 1))));
        }

        for (arg_inst_indices.items) |idx| {
            try self.builder.extra.append(self.builder.gpa, idx);
        }

        return self.emitBodyInst(.call, Builder.encodePlNode(.zero, payload_idx));
    }

    /// Add element access by immediate index (tuple/array indexing).
    /// ZIR tag: `.elem_val_imm`, data field: `elem_val_imm`.
    pub fn addElemValImm(self: *FuncBody, operand: Zir.Inst.Ref, index: u32) !Zir.Inst.Ref {
        return self.emitBodyInst(.elem_val_imm, .{ .elem_val_imm = .{
            .operand = operand,
            .idx = index,
        } });
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

    /// Mark a value as used (prevents "result not used" compile error for void calls).
    /// ZIR tag: `.ensure_result_used`, data field: `un_node`.
    pub fn addEnsureResultUsed(self: *FuncBody, operand: Zir.Inst.Ref) !void {
        try self.emitBodyInstVoid(.ensure_result_used, Builder.encodeUnNode(.zero, operand));
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

        // 1. Emit block_inline with a placeholder payload (fix up below).
        const block_payload_idx: u32 = @intCast(b.extra.items.len);
        // Reserve space for Block { body_len: u32 } + 1 body index
        try b.extra.append(gpa, 1); // body_len = 1 (the condbr_inline)
        const block_body_slot: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, 0); // placeholder for condbr_inline index

        // The block_inline is a body instruction of the function.
        const block_idx = try b.addInst(.block_inline, Builder.encodePlNode(.zero, block_payload_idx));
        try self.body_inst_indices.append(gpa, block_idx);

        // 2. Emit the two break_inline instructions (NOT body instructions).
        //    They reference the block_inline by instruction index.

        // Break payload for then branch
        const break_then_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst = block_inline
        const break_then_idx = try b.addInst(.break_inline, Builder.encodeBreak(then_value, break_then_payload_idx));

        // Break payload for else branch
        const break_else_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @bitCast(@as(i32, std.math.maxInt(i32)))); // operand_src_node = none
        try b.extra.append(gpa, block_idx); // block_inst = block_inline
        const break_else_idx = try b.addInst(.break_inline, Builder.encodeBreak(else_value, break_else_payload_idx));

        // 3. Emit condbr_inline (NOT a body instruction).
        //    CondBr payload: { condition: Ref, then_body_len: u32, else_body_len: u32 }
        //    Trailing: then body indices..., else body indices...
        const condbr_payload_idx: u32 = @intCast(b.extra.items.len);
        try b.extra.append(gpa, @intFromEnum(condition)); // condition
        try b.extra.append(gpa, 1); // then_body_len = 1
        try b.extra.append(gpa, 1); // else_body_len = 1
        try b.extra.append(gpa, break_then_idx); // then body[0]
        try b.extra.append(gpa, break_else_idx); // else body[0]
        const condbr_idx = try b.addInst(.condbr_inline, Builder.encodePlNode(.zero, condbr_payload_idx));

        // 4. Fix up block_inline's body to point to condbr_inline.
        b.extra.items[block_body_slot] = condbr_idx;

        // The block_inline instruction result is the value produced by
        // whichever break_inline executes.
        return Builder.instRef(block_idx);
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

    // extended, declaration, restore_err_ret, int(42), decl_val("some_func"), int(clone), break_inline(arg), call, ret_implicit, func, break_inline
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

test "Builder: addFieldVal" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("test_field", .void);
    const obj = try body.addInt(42);
    const field = try body.addFieldVal(obj, "some_field");
    _ = field;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), field_val, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 8), result.instructions_len);

    // Verify the field_val instruction is at index 4
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.field_val), result.instructions_tags[4]);

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
    const func_ref = try body.addFieldVal(mod, "debug");
    const arg = try body.addInt(42);
    const call_result = try body.addCallRef(func_ref, &.{arg});
    _ = call_result;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, import, field_val, int(42), int(clone), break_inline(arg), call, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 12), result.instructions_len);

    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.import), result.instructions_tags[3]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.field_val), result.instructions_tags[4]);
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
    // 8: condbr_inline       <- NOT a body instruction, referenced from block extra
    // 9: ret_node
    // 10: func
    // 11: break_inline (func)
    try std.testing.expectEqual(@as(u32, 12), result.instructions_len);

    // Verify instruction tags
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[3]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.block_inline), result.instructions_tags[5]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.break_inline), result.instructions_tags[6]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.break_inline), result.instructions_tags[7]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.condbr_inline), result.instructions_tags[8]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ret_node), result.instructions_tags[9]);

    // Verify block_inline's extra payload
    const data_items: []const Zir.Inst.Data = @alignCast(std.mem.bytesAsSlice(Zir.Inst.Data, result.instructions_data));
    const block_data = data_items[5].pl_node;
    const block_payload_idx = block_data.payload_index;

    // Block payload: { body_len: u32 } + body indices
    try std.testing.expectEqual(@as(u32, 1), result.extra[block_payload_idx]); // body_len = 1
    try std.testing.expectEqual(@as(u32, 8), result.extra[block_payload_idx + 1]); // body[0] = condbr_inline at index 8

    // Verify condbr_inline's extra payload
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
