const std = @import("std");
const Zir = std.zig.Zir;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const Builder = struct {
    gpa: Allocator,
    tags: std.ArrayListUnmanaged(u8),
    data: std.ArrayListUnmanaged([2]u32),
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
        try self.data.append(gpa, .{ 0, 0 });

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
    pub fn addInst(self: *Builder, tag: Zir.Inst.Tag, data_words: [2]u32) !u32 {
        const index: u32 = @intCast(self.tags.items.len);
        try self.tags.append(self.gpa, @intFromEnum(tag));
        try self.data.append(self.gpa, data_words);
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
    pub fn beginFunction(self: *Builder, name: []const u8) !*FuncBody {
        std.debug.assert(self.active_body == null);

        // Emit placeholder declaration instruction (fix up in endFunction)
        const decl_inst = try self.addInst(.declaration, .{ 0, 0 });

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
        // Trailing: body indices, SrcLocs (3 u32s), proto_hash (4 u32s)
        const func_payload_idx: u32 = @intCast(self.extra.items.len);

        // ret_ty: body_len=0 means void, is_generic=false
        try self.extra.append(self.gpa, 0);
        // param_block: the declaration instruction
        try self.extra.append(self.gpa, decl_inst);
        // body_len
        try self.extra.append(self.gpa, body_len);

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
        self.data.items[decl_inst] = .{ 0, decl_payload_idx };

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
        // Extended.InstData: { opcode: Extended(u16), small: u16, operand: u32 }
        // In memory as [2]u32: first = (small << 16) | opcode, second = operand
        const opcode: u16 = @intFromEnum(Zir.Inst.Extended.struct_decl);
        const small: u16 = 0x0004; // StructDecl.Small with has_decls_len = true (bit 2)
        self.data.items[0] = .{
            @as(u32, small) << 16 | @as(u32, opcode),
            struct_payload_idx,
        };

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

    fn encodeUnNode(src_node: Ast.Node.Offset, operand: Zir.Inst.Ref) [2]u32 {
        return .{
            @bitCast(@intFromEnum(src_node)),
            @intFromEnum(operand),
        };
    }

    fn encodeUnTok(src_tok: Ast.TokenOffset, operand: Zir.Inst.Ref) [2]u32 {
        return .{
            @bitCast(@intFromEnum(src_tok)),
            @intFromEnum(operand),
        };
    }

    fn encodePlNode(src_node: Ast.Node.Offset, payload_index: u32) [2]u32 {
        return .{
            @bitCast(@intFromEnum(src_node)),
            payload_index,
        };
    }

    fn encodeBreak(operand: Zir.Inst.Ref, payload_index: u32) [2]u32 {
        return .{
            @intFromEnum(operand),
            payload_index,
        };
    }

    fn encodeInt(value: u64) [2]u32 {
        return @bitCast(value);
    }

    fn encodeFloat(value: f64) [2]u32 {
        return @bitCast(value);
    }

    fn encodeStr(start: u32, len: u32) [2]u32 {
        return .{ start, len };
    }

    fn encodeStrTok(start: u32, src_tok: Ast.TokenOffset) [2]u32 {
        return .{ start, @bitCast(@intFromEnum(src_tok)) };
    }
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

    /// Emit an instruction into the builder and track it as a body instruction.
    /// Returns the Ref pointing to this instruction.
    fn emitBodyInst(self: *FuncBody, tag: Zir.Inst.Tag, data_words: [2]u32) !Zir.Inst.Ref {
        const idx = try self.builder.addInst(tag, data_words);
        try self.body_inst_indices.append(self.builder.gpa, idx);
        return Builder.instRef(idx);
    }

    /// Emit an instruction into the builder body but don't return a Ref (for void ops).
    fn emitBodyInstVoid(self: *FuncBody, tag: Zir.Inst.Tag, data_words: [2]u32) !void {
        const idx = try self.builder.addInst(tag, data_words);
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

    /// Add a function call by name. Returns a Ref to the result.
    pub fn addCall(self: *FuncBody, callee_name: []const u8, args: []const Zir.Inst.Ref) !Zir.Inst.Ref {
        // First, resolve callee via decl_val
        const name_start = try self.builder.internString(callee_name);
        const callee_ref = try self.emitBodyInst(.decl_val, Builder.encodeStrTok(name_start, .zero));

        // Call payload in extra: { flags: Flags(u32), callee: Ref }
        // Then trailing: arg_end for each arg (see Call struct)
        const payload_idx: u32 = @intCast(self.builder.extra.items.len);

        // flags: packed_modifier=auto(0), ensure_result_used=false, pop_error_return_trace=false, args_len
        const args_len: u32 = @intCast(args.len);
        const flags: u32 = args_len << 5; // args_len is top 27 bits
        try self.builder.extra.append(self.builder.gpa, flags);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(callee_ref));

        // Trailing arg_end values: each is the cumulative end index
        // arg_0_start is implicitly args_len
        // arg_N_end = args_len + N + 1 (each arg is one instruction)
        // But actually, the args are Refs stored in the body of each arg.
        // For simple single-instruction args, each arg body is length 1.
        // arg_0_start = args_len, arg_0_end = args_len + 1, etc.
        for (0..args.len) |i| {
            // arg_end for arg i
            try self.builder.extra.append(self.builder.gpa, @as(u32, @intCast(args_len + i + 1)));
        }

        // Then the actual arg refs
        for (args) |arg| {
            try self.builder.extra.append(self.builder.gpa, @intFromEnum(arg));
        }

        return self.emitBodyInst(.call, Builder.encodePlNode(.zero, payload_idx));
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

    const body = try builder.beginFunction("main");
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

    const body = try builder.beginFunction("main");
    const val = try body.addInt(42);
    _ = val; // unused for now, just verify it doesn't crash
    try builder.endFunction(body);

    const result = try builder.finalize();

    // Should have: extended, declaration, restore_err_ret, int(42), ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 7), result.instructions_len);

    // Verify the int instruction is at index 3
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.int), result.instructions_tags[3]);

    // Verify the int value is 42 in the data
    const data_u32s: []const [2]u32 = @alignCast(std.mem.bytesAsSlice([2]u32, result.instructions_data));
    const int_data = data_u32s[3];
    const int_value: u64 = @bitCast(int_data);
    try std.testing.expectEqual(@as(u64, 42), int_value);
}

test "Builder: addInt returns valid Ref" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("add_test");
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

    const body = try builder.beginFunction("float_test");
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

    const body = try builder.beginFunction("str_test");
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

    const body = try builder.beginFunction("bool_test");
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

    const body = try builder.beginFunction("unary_test");
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

    const body = try builder.beginFunction("ret_test");
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

    const body1 = try builder.beginFunction("foo");
    try builder.endFunction(body1);

    const body2 = try builder.beginFunction("bar");
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

    const body = try builder.beginFunction("enum_test");
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

    const body = try builder.beginFunction("main");
    try builder.endFunction(body);
    const result = try builder.finalize();

    // Verify instruction 0 data encodes Extended.InstData correctly
    const data_u32s: []const [2]u32 = @alignCast(std.mem.bytesAsSlice([2]u32, result.instructions_data));
    const ext_data = data_u32s[0];

    // First u32: lower 16 = opcode (struct_decl = 0), upper 16 = small (0x0004)
    const opcode_bits: u16 = @truncate(ext_data[0]);
    const small_bits: u16 = @truncate(ext_data[0] >> 16);
    try std.testing.expectEqual(@as(u16, @intFromEnum(Zir.Inst.Extended.struct_decl)), opcode_bits);
    try std.testing.expectEqual(@as(u16, 0x0004), small_bits);

    // Second u32: operand = payload index pointing to StructDecl in extra
    const payload_idx = ext_data[1];
    // StructDecl payload should be at index 26 (after all func/decl payloads)
    try std.testing.expectEqual(@as(u32, 26), payload_idx);
}

test "Builder: addCall" {
    var builder = try Builder.init(std.testing.allocator);
    defer builder.deinit();

    const body = try builder.beginFunction("call_test");
    const arg = try body.addInt(42);
    const call_result = try body.addCall("some_func", &.{arg});
    _ = call_result;
    try builder.endFunction(body);

    const result = try builder.finalize();

    // extended, declaration, restore_err_ret, int(42), decl_val("some_func"), call, ret_implicit, func, break_inline
    try std.testing.expectEqual(@as(u32, 9), result.instructions_len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.decl_val), result.instructions_tags[4]);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.call), result.instructions_tags[5]);
}
