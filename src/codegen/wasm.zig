const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const leb = std.leb;
const mem = std.mem;
const wasm = std.wasm;

const Module = @import("../Module.zig");
const Decl = Module.Decl;
const ir = @import("../ir.zig");
const Inst = ir.Inst;
const Type = @import("../type.zig").Type;
const Value = @import("../value.zig").Value;
const Compilation = @import("../Compilation.zig");
const AnyMCValue = @import("../codegen.zig").AnyMCValue;

/// Wasm Value, created when generating an instruction
const WValue = union(enum) {
    none: void,
    /// Index of the local variable
    local: u32,
    /// Instruction holding a constant `Value`
    constant: *Inst,
    /// Offset position in the list of bytecode instructions
    code_offset: usize,
    /// The label of the block, used by breaks to find its relative distance
    block_idx: u32,
};

/// Hashmap to store generated `WValue` for each `Inst`
pub const ValueTable = std.AutoHashMapUnmanaged(*Inst, WValue);

/// Code represents the `Code` section of wasm that
/// belongs to a function
pub const Context = struct {
    /// Reference to the function declaration the code
    /// section belongs to
    decl: *Decl,
    gpa: *mem.Allocator,
    /// Table to save `WValue`'s generated by an `Inst`
    values: ValueTable,
    /// `bytes` contains the wasm bytecode belonging to the 'code' section.
    code: ArrayList(u8),
    /// Contains the generated function type bytecode for the current function
    /// found in `decl`
    func_type_data: ArrayList(u8),
    /// The index the next local generated will have
    /// NOTE: arguments share the index with locals therefore the first variable
    /// will have the index that comes after the last argument's index
    local_index: u32 = 0,
    /// If codegen fails, an error messages will be allocated and saved in `err_msg`
    err_msg: *Module.ErrorMsg,
    /// Current block depth. Used to calculate the relative difference between a break
    /// and block
    block_depth: u32 = 0,
    /// List of all locals' types generated throughout this declaration
    /// used to emit locals count at start of 'code' section.
    locals: std.ArrayListUnmanaged(u8),

    const InnerError = error{
        OutOfMemory,
        CodegenFail,
    };

    pub fn deinit(self: *Context) void {
        self.values.deinit(self.gpa);
        self.locals.deinit(self.gpa);
        self.* = undefined;
    }

    /// Sets `err_msg` on `Context` and returns `error.CodegemFail` which is caught in link/Wasm.zig
    fn fail(self: *Context, src: usize, comptime fmt: []const u8, args: anytype) InnerError {
        self.err_msg = try Module.ErrorMsg.create(self.gpa, .{
            .file_scope = self.decl.getFileScope(),
            .byte_offset = src,
        }, fmt, args);
        return error.CodegenFail;
    }

    /// Resolves the `WValue` for the given instruction `inst`
    /// When the given instruction has a `Value`, it returns a constant instead
    fn resolveInst(self: Context, inst: *Inst) WValue {
        if (!inst.ty.hasCodeGenBits()) return .none;

        if (inst.value()) |_| {
            return WValue{ .constant = inst };
        }

        return self.values.get(inst).?; // Instruction does not dominate all uses!
    }

    /// Using a given `Type`, returns the corresponding wasm value type
    fn genValtype(self: *Context, src: usize, ty: Type) InnerError!u8 {
        return switch (ty.tag()) {
            .f32 => wasm.valtype(.f32),
            .f64 => wasm.valtype(.f64),
            .u32, .i32 => wasm.valtype(.i32),
            .u64, .i64 => wasm.valtype(.i64),
            else => self.fail(src, "TODO - Wasm genValtype for type '{s}'", .{ty.tag()}),
        };
    }

    /// Using a given `Type`, returns the corresponding wasm value type
    /// Differently from `genValtype` this also allows `void` to create a block
    /// with no return type
    fn genBlockType(self: *Context, src: usize, ty: Type) InnerError!u8 {
        return switch (ty.tag()) {
            .void, .noreturn => wasm.block_empty,
            else => self.genValtype(src, ty),
        };
    }

    /// Writes the bytecode depending on the given `WValue` in `val`
    fn emitWValue(self: *Context, val: WValue) InnerError!void {
        const writer = self.code.writer();
        switch (val) {
            .block_idx => unreachable,
            .none, .code_offset => {},
            .local => |idx| {
                try writer.writeByte(wasm.opcode(.local_get));
                try leb.writeULEB128(writer, idx);
            },
            .constant => |inst| try self.emitConstant(inst.castTag(.constant).?), // creates a new constant onto the stack
        }
    }

    fn genFunctype(self: *Context) InnerError!void {
        const ty = self.decl.typed_value.most_recent.typed_value.ty;
        const writer = self.func_type_data.writer();

        try writer.writeByte(wasm.function_type);

        // param types
        try leb.writeULEB128(writer, @intCast(u32, ty.fnParamLen()));
        if (ty.fnParamLen() != 0) {
            const params = try self.gpa.alloc(Type, ty.fnParamLen());
            defer self.gpa.free(params);
            ty.fnParamTypes(params);
            for (params) |param_type| {
                // Can we maybe get the source index of each param?
                const val_type = try self.genValtype(self.decl.src(), param_type);
                try writer.writeByte(val_type);
            }
        }

        // return type
        const return_type = ty.fnReturnType();
        switch (return_type.tag()) {
            .void, .noreturn => try leb.writeULEB128(writer, @as(u32, 0)),
            else => |ret_type| {
                try leb.writeULEB128(writer, @as(u32, 1));
                // Can we maybe get the source index of the return type?
                const val_type = try self.genValtype(self.decl.src(), return_type);
                try writer.writeByte(val_type);
            },
        }
    }

    /// Generates the wasm bytecode for the function declaration belonging to `Context`
    pub fn gen(self: *Context) InnerError!void {
        assert(self.code.items.len == 0);
        try self.genFunctype();
        const writer = self.code.writer();

        // Reserve space to write the size after generating the code
        try self.code.resize(5);

        // offset into 'code' section where we will put our locals count
        var local_offset = self.code.items.len;

        // Write instructions
        // TODO: check for and handle death of instructions
        const tv = self.decl.typed_value.most_recent.typed_value;
        const mod_fn = tv.val.castTag(.function).?.data;
        try self.genBody(mod_fn.body);

        // finally, write our local types at the 'offset' position
        {
            var totals_buffer: [5]u8 = undefined;
            leb.writeUnsignedFixed(5, totals_buffer[0..5], @intCast(u32, self.locals.items.len));
            try self.code.insertSlice(local_offset, &totals_buffer);
            local_offset += 5;

            // emit the actual locals amount
            for (self.locals.items) |local| {
                var buf: [6]u8 = undefined;
                leb.writeUnsignedFixed(5, buf[0..5], @as(u32, 1));
                buf[5] = local;
                try self.code.insertSlice(local_offset, &buf);
                local_offset += 6;
            }
        }

        try writer.writeByte(wasm.opcode(.end));

        // Fill in the size of the generated code to the reserved space at the
        // beginning of the buffer.
        const size = self.code.items.len - 5 + self.decl.fn_link.wasm.?.idx_refs.items.len * 5;
        leb.writeUnsignedFixed(5, self.code.items[0..5], @intCast(u32, size));
    }

    fn genInst(self: *Context, inst: *Inst) InnerError!WValue {
        return switch (inst.tag) {
            .add => self.genAdd(inst.castTag(.add).?),
            .alloc => self.genAlloc(inst.castTag(.alloc).?),
            .arg => self.genArg(inst.castTag(.arg).?),
            .block => self.genBlock(inst.castTag(.block).?),
            .br => self.genBr(inst.castTag(.br).?),
            .call => self.genCall(inst.castTag(.call).?),
            .cmp_eq => self.genCmp(inst.castTag(.cmp_eq).?, .eq),
            .cmp_gte => self.genCmp(inst.castTag(.cmp_gte).?, .gte),
            .cmp_gt => self.genCmp(inst.castTag(.cmp_gt).?, .gt),
            .cmp_lte => self.genCmp(inst.castTag(.cmp_lte).?, .lte),
            .cmp_lt => self.genCmp(inst.castTag(.cmp_lt).?, .lt),
            .cmp_neq => self.genCmp(inst.castTag(.cmp_neq).?, .neq),
            .condbr => self.genCondBr(inst.castTag(.condbr).?),
            .constant => unreachable,
            .dbg_stmt => WValue.none,
            .load => self.genLoad(inst.castTag(.load).?),
            .loop => self.genLoop(inst.castTag(.loop).?),
            .ret => self.genRet(inst.castTag(.ret).?),
            .retvoid => WValue.none,
            .store => self.genStore(inst.castTag(.store).?),
            else => self.fail(inst.src, "TODO: Implement wasm inst: {s}", .{inst.tag}),
        };
    }

    fn genBody(self: *Context, body: ir.Body) InnerError!void {
        for (body.instructions) |inst| {
            const result = try self.genInst(inst);
            try self.values.putNoClobber(self.gpa, inst, result);
        }
    }

    fn genRet(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        // TODO: Implement tail calls
        const operand = self.resolveInst(inst.operand);
        try self.emitWValue(operand);
        return .none;
    }

    fn genCall(self: *Context, inst: *Inst.Call) InnerError!WValue {
        const func_inst = inst.func.castTag(.constant).?;
        const func = func_inst.val.castTag(.function).?.data;
        const target = func.owner_decl;
        const target_ty = target.typed_value.most_recent.typed_value.ty;

        for (inst.args) |arg| {
            const arg_val = self.resolveInst(arg);
            try self.emitWValue(arg_val);
        }

        try self.code.append(wasm.opcode(.call));

        // The function index immediate argument will be filled in using this data
        // in link.Wasm.flush().
        try self.decl.fn_link.wasm.?.idx_refs.append(self.gpa, .{
            .offset = @intCast(u32, self.code.items.len),
            .decl = target,
        });

        return .none;
    }

    fn genAlloc(self: *Context, inst: *Inst.NoOp) InnerError!WValue {
        const elem_type = inst.base.ty.elemType();
        const valtype = try self.genValtype(inst.base.src, elem_type);
        try self.locals.append(self.gpa, valtype);

        defer self.local_index += 1;
        return WValue{ .local = self.local_index };
    }

    fn genStore(self: *Context, inst: *Inst.BinOp) InnerError!WValue {
        const writer = self.code.writer();

        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);
        try self.emitWValue(rhs);

        try writer.writeByte(wasm.opcode(.local_set));
        try leb.writeULEB128(writer, lhs.local);
        return .none;
    }

    fn genLoad(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        const operand = self.resolveInst(inst.operand);
        return operand;
    }

    fn genArg(self: *Context, inst: *Inst.Arg) InnerError!WValue {
        // arguments share the index with locals
        defer self.local_index += 1;
        return WValue{ .local = self.local_index };
    }

    fn genAdd(self: *Context, inst: *Inst.BinOp) InnerError!WValue {
        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        try self.emitWValue(lhs);
        try self.emitWValue(rhs);

        const opcode: wasm.Opcode = switch (inst.base.ty.tag()) {
            .u32, .i32 => .i32_add,
            .u64, .i64 => .i64_add,
            .f32 => .f32_add,
            .f64 => .f64_add,
            else => return self.fail(inst.base.src, "TODO - Implement wasm genAdd for type '{s}'", .{inst.base.ty.tag()}),
        };

        try self.code.append(wasm.opcode(opcode));
        return .none;
    }

    fn emitConstant(self: *Context, inst: *Inst.Constant) InnerError!void {
        const writer = self.code.writer();
        switch (inst.base.ty.tag()) {
            .u32 => {
                try writer.writeByte(wasm.opcode(.i32_const));
                try leb.writeILEB128(writer, inst.val.toUnsignedInt());
            },
            .i32 => {
                try writer.writeByte(wasm.opcode(.i32_const));
                try leb.writeILEB128(writer, inst.val.toSignedInt());
            },
            .u64 => {
                try writer.writeByte(wasm.opcode(.i64_const));
                try leb.writeILEB128(writer, inst.val.toUnsignedInt());
            },
            .i64 => {
                try writer.writeByte(wasm.opcode(.i64_const));
                try leb.writeILEB128(writer, inst.val.toSignedInt());
            },
            .f32 => {
                try writer.writeByte(wasm.opcode(.f32_const));
                // TODO: enforce LE byte order
                try writer.writeAll(mem.asBytes(&inst.val.toFloat(f32)));
            },
            .f64 => {
                try writer.writeByte(wasm.opcode(.f64_const));
                // TODO: enforce LE byte order
                try writer.writeAll(mem.asBytes(&inst.val.toFloat(f64)));
            },
            .void => {},
            else => |ty| return self.fail(inst.base.src, "Wasm TODO: emitConstant for type {s}", .{ty}),
        }
    }

    fn genBlock(self: *Context, block: *Inst.Block) InnerError!WValue {
        const block_ty = try self.genBlockType(block.base.src, block.base.ty);

        block.codegen = .{
            // we don't use relocs, so using `relocs` is illegal behaviour.
            .relocs = undefined,
            // Here we set the current block idx, so conditions know the depth to jump
            // to when breaking out. This will be set to .none when it is found again within
            // the same block
            .mcv = @bitCast(AnyMCValue, WValue{ .block_idx = self.block_depth }),
        };
        self.block_depth += 1;

        try self.code.append(wasm.opcode(.block));
        try self.code.append(block_ty);
        try self.genBody(block.body);
        try self.code.append(wasm.opcode(.end));

        self.block_depth -= 1;
        return .none;
    }

    fn genLoop(self: *Context, loop: *Inst.Loop) InnerError!WValue {
        const loop_ty = try self.genBlockType(loop.base.src, loop.base.ty);

        try self.code.append(wasm.opcode(.loop));
        try self.code.append(loop_ty);
        self.block_depth += 1;
        try self.genBody(loop.body);
        self.block_depth -= 1;

        try self.code.append(wasm.opcode(.end));

        return .none;
    }

    fn genCondBr(self: *Context, condbr: *Inst.CondBr) InnerError!WValue {
        const condition = self.resolveInst(condbr.condition);
        const writer = self.code.writer();

        // insert blocks at the position of `offset` so
        // the condition can jump to it
        const offset = condition.code_offset;
        try self.code.insert(offset, wasm.opcode(.block));
        try self.code.insert(offset, try self.genBlockType(condbr.base.src, condbr.base.ty));

        // we inserted the block in front of the condition
        // so now check if condition matches. If not, break outside this block
        // and continue with the regular codepath
        try writer.writeByte(wasm.opcode(.br_if));
        try leb.writeULEB128(writer, @as(u32, 0));

        // else body in case condition does not match
        try self.genBody(condbr.else_body);

        // finally, tell wasm we have reached the end of the block we inserted above
        try writer.writeByte(wasm.opcode(.end));

        // Outer block that matches the condition
        try self.genBody(condbr.then_body);

        return .none;
    }

    fn genCmp(self: *Context, inst: *Inst.BinOp, op: std.math.CompareOperator) InnerError!WValue {
        const ty = inst.lhs.ty.tag();

        // save offset, so potential conditions can insert blocks in front of
        // the comparison that we can later jump back to
        const offset = self.code.items.len - 1;

        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        try self.emitWValue(lhs);
        try self.emitWValue(rhs);

        const opcode_maybe: ?wasm.Opcode = switch (op) {
            .lt => @as(?wasm.Opcode, switch (ty) {
                .i32 => .i32_lt_s,
                .u32 => .i32_lt_u,
                .i64 => .i64_lt_s,
                .u64 => .i64_lt_u,
                .f32 => .f32_lt,
                .f64 => .f64_lt,
                else => null,
            }),
            .lte => @as(?wasm.Opcode, switch (ty) {
                .i32 => .i32_le_s,
                .u32 => .i32_le_u,
                .i64 => .i64_le_s,
                .u64 => .i64_le_u,
                .f32 => .f32_le,
                .f64 => .f64_le,
                else => null,
            }),
            .eq => @as(?wasm.Opcode, switch (ty) {
                .i32, .u32 => .i32_eq,
                .i64, .u64 => .i64_eq,
                .f32 => .f32_eq,
                .f64 => .f64_eq,
                else => null,
            }),
            .gte => @as(?wasm.Opcode, switch (ty) {
                .i32 => .i32_ge_s,
                .u32 => .i32_ge_u,
                .i64 => .i64_ge_s,
                .u64 => .i64_ge_u,
                .f32 => .f32_ge,
                .f64 => .f64_ge,
                else => null,
            }),
            .gt => @as(?wasm.Opcode, switch (ty) {
                .i32 => .i32_gt_s,
                .u32 => .i32_gt_u,
                .i64 => .i64_gt_s,
                .u64 => .i64_gt_u,
                .f32 => .f32_gt,
                .f64 => .f64_gt,
                else => null,
            }),
            .neq => @as(?wasm.Opcode, switch (ty) {
                .i32, .u32 => .i32_ne,
                .i64, .u64 => .i64_ne,
                .f32 => .f32_ne,
                .f64 => .f64_ne,
                else => null,
            }),
        };

        const opcode = opcode_maybe orelse
            return self.fail(inst.base.src, "TODO - Wasm genCmp for type '{s}' and operator '{s}'", .{ ty, @tagName(op) });

        try self.code.append(wasm.opcode(opcode));
        return WValue{ .code_offset = offset };
    }

    fn genBr(self: *Context, br: *Inst.Br) InnerError!WValue {
        // of operand has codegen bits we should break with a value
        if (br.operand.ty.hasCodeGenBits()) {
            const operand = self.resolveInst(br.operand);
            try self.emitWValue(operand);
        }

        // if the block contains a block_idx, do a relative jump to it
        // if `wvalue` was already 'consumed', simply break out of current block
        const wvalue = @bitCast(WValue, br.block.codegen.mcv);
        const idx: u32 = if (wvalue == .block_idx) blk: {
            br.block.codegen.mcv = @bitCast(AnyMCValue, WValue{ .none = {} });
            break :blk self.block_depth - wvalue.block_idx;
        } else 0;

        const writer = self.code.writer();
        try writer.writeByte(wasm.opcode(.br));
        try leb.writeULEB128(writer, idx);
        return WValue.none;
    }
};
