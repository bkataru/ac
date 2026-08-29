//! Evaluator for ac calculator
//!
//! Evaluates AST expressions and returns BigDec results.

const std = @import("std");
const BigDec = @import("num.zig").BigDec;
const mathlib = @import("mathlib.zig");
const Expr = @import("parse.zig").Expr;
const Stmt = @import("parse.zig").Stmt;
const BinaryOp = @import("parse.zig").BinaryOp;
const UnaryOp = @import("parse.zig").UnaryOp;
const Lexer = @import("lex.zig").Lexer;
const Parser = @import("parse.zig").Parser;

// Forward declare State from main
const State = @import("main.zig").State;

/// Control-flow signal produced by statement execution.
pub const Flow = union(enum) {
    normal,
    break_loop,
    continue_loop,
    quit,
    halt,
    ret: ?Value,
};

/// A runtime value: number or string. Strings are bounded values — they can
/// be assigned, printed, returned, and live on the dc stack, but have no
/// arithmetic operators.
pub const Value = union(enum) {
    num: BigDec,
    str: []u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .num => |*n| n.deinit(),
            .str => |s| allocator.free(s),
        }
    }

    pub fn clone(self: *const Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self.*) {
            .num => |n| .{ .num = try n.clone(allocator) },
            .str => |s| .{ .str = try allocator.dupe(u8, s) },
        };
    }

    /// Extract the numeric payload; strings are invalid operands for all
    /// arithmetic operators (bounded string semantics).
    pub fn asNum(self: *const Value) ?BigDec {
        return switch (self.*) {
            .num => |n| n,
            .str => null,
        };
    }
};

pub const EvalError = error{
    DivisionByZero,
    NegativeSquareRoot,
    NonIntegerExponent,
    UndefinedVariable,
    UndefinedFunction,
    WrongArgCount,
    InvalidAssignment,
    InvalidBreak,
    InvalidContinue,
    InvalidReturn,
    InternalDivisionOverflow,
    InvalidOperand,
    InvalidBase,
    WriteFailed,
    OutOfMemory,
};

/// A user-defined function.
pub const FunctionDef = struct {
    name: []const u8,
    params: []@import("parse.zig").ParamSpec,
    auto_vars: []@import("parse.zig").AutoEntry,
    body: *Stmt,
};

/// Maximum array elements (bounds runaway growth).
pub const MAX_ARRAY_LEN: usize = 1 << 20;

pub const Evaluator = struct {
    state: *State,
    allocator: std.mem.Allocator,
    /// Writer used by `print` statements inside function bodies.
    func_stdout: ?*std.Io.Writer = null,
    /// Binding frames: one per active callFunction. Standalone auto
    /// statements append to the innermost frame so recursive calls never
    /// unwind each other's bindings.
    frames: std.ArrayList(Frame) = .empty,

    /// Saved bindings for one active function call.
    const Frame = struct {
        saved_vals: std.ArrayList(?Value) = .empty,
        saved_keys: std.ArrayList([]const u8) = .empty,
        arr_saved: std.ArrayList(?[]Value) = .empty,
        arr_keys: std.ArrayList([]const u8) = .empty,
    };

    const Self = @This();

    pub fn init(state: *State) Self {
        return .{
            .state = state,
            .allocator = state.allocator,
        };
    }

    /// Free the frame stack (top-level auto bindings leave entries here).
    /// Map-owned values/keys are freed by State.deinit.
    pub fn deinit(self: *Self) void {
        for (self.frames.items) |*fr| {
            fr.saved_vals.deinit(self.allocator);
            fr.saved_keys.deinit(self.allocator);
            fr.arr_saved.deinit(self.allocator);
            fr.arr_keys.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
    }

    /// Evaluate an expression and return the result
    pub fn evaluate(self: *Self, expr: *const Expr) EvalError!Value {
        return switch (expr.*) {
            .number => |n| .{ .num = n.clone(self.allocator) catch return error.OutOfMemory },
            .variable => |name| self.evalVariable(name),
            .builtin_var => |which| self.evalBuiltinVar(which),
            .last => self.evalLast(),
            .string => |s| .{ .str = self.allocator.dupe(u8, s) catch return error.OutOfMemory },
            .index => |ix| self.evalIndex(ix.name, ix.idx),
            .array_ref => return error.InvalidOperand,
            .binary => |b| self.evalBinary(b.left, b.op, b.right),
            .unary => |u| self.evalUnary(u.op, u.operand),
            .call => |c| self.evalCall(c.name, c.args.items),
            .grouping => |g| self.evaluate(g),
        };
    }

    /// Evaluate a variable reference
    fn evalVariable(self: *Self, name: []const u8) EvalError!Value {
        if (self.state.variables.get(name)) |value| {
            return value.clone(self.allocator) catch return error.OutOfMemory;
        }

        // Undefined variables are zero in bc
        return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
    }

    /// Evaluate builtin variable (scale, ibase, obase)
    fn evalBuiltinVar(self: *Self, which: Expr.BuiltinVar) EvalError!Value {
        const value: i64 = switch (which) {
            .scale => @intCast(self.state.scale),
            .ibase => @intCast(self.state.ibase),
            .obase => @intCast(self.state.obase),
        };
        return .{ .num = BigDec.fromInt(self.allocator, value) catch return error.OutOfMemory };
    }

    /// Evaluate 'last' keyword
    fn evalLast(self: *Self) EvalError!Value {
        if (self.state.last) |last| {
            return .{ .num = last.clone(self.allocator) catch return error.OutOfMemory };
        }
        return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
    }

    /// Evaluate binary operation
    fn evalBinary(self: *Self, left_expr: *const Expr, op: BinaryOp, right_expr: *const Expr) EvalError!Value {
        // Assignment returns the stored value; handled separately.
        if (op == .assign or op == .add_assign or op == .sub_assign or
            op == .mul_assign or op == .div_assign or op == .mod_assign or op == .pow_assign)
        {
            return self.evalAssignment(left_expr, op, right_expr);
        }
        var left_v = try self.evaluate(left_expr);
        defer left_v.deinit(self.allocator);
        var right_v = try self.evaluate(right_expr);
        defer right_v.deinit(self.allocator);

        const left = left_v.asNum() orelse return error.InvalidOperand;
        const right = right_v.asNum() orelse return error.InvalidOperand;

        var result = BigDec.init(self.allocator);
        errdefer result.deinit();

        switch (op) {
            .add => result.add(left, right, self.state.scale) catch return error.OutOfMemory,
            .sub => result.sub(left, right, self.state.scale) catch return error.OutOfMemory,
            .mul => result.mul(left, right, self.state.scale) catch return error.OutOfMemory,
            .div => result.div(left, right, self.state.scale) catch |e| {
                if (e == error.DivisionByZero) return error.DivisionByZero;
                if (e == error.InternalDivisionOverflow) return error.InternalDivisionOverflow;
                return error.OutOfMemory;
            },
            .mod => result.mod(left, right, self.state.scale) catch |e| {
                if (e == error.DivisionByZero) return error.DivisionByZero;
                return error.OutOfMemory;
            },
            .pow => result.pow(left, right, self.state.scale) catch |e| {
                if (e == error.NonIntegerExponent) return error.NonIntegerExponent;
                return error.OutOfMemory;
            },
            .eq => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp == .eq) 1 else 0) catch return error.OutOfMemory;
            },
            .ne => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp != .eq) 1 else 0) catch return error.OutOfMemory;
            },
            .lt => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp == .lt) 1 else 0) catch return error.OutOfMemory;
            },
            .le => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp == .lt or cmp == .eq) 1 else 0) catch return error.OutOfMemory;
            },
            .gt => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp == .gt) 1 else 0) catch return error.OutOfMemory;
            },
            .ge => {
                const cmp = BigDec.cmp(left, right);
                result = BigDec.fromInt(self.allocator, if (cmp == .gt or cmp == .eq) 1 else 0) catch return error.OutOfMemory;
            },
            else => return error.InvalidAssignment,
        }

        return .{ .num = result };
    }

    /// Evaluate assignment. Returns the stored value (echoed by the REPL).
    fn evalAssignment(self: *Self, target: *const Expr, op: BinaryOp, value_expr: *const Expr) EvalError!Value {
        // Get the value to assign (may be a string — strings can be stored).
        var new_value = try self.evaluate(value_expr);
        errdefer new_value.deinit(self.allocator);

        // For compound assignments the target and RHS must both be numbers.
        if (op != .assign) {
            var current_v = try self.evaluate(target);
            defer current_v.deinit(self.allocator);

            const current = current_v.asNum() orelse return error.InvalidOperand;
            const rhs = new_value.asNum() orelse return error.InvalidOperand;

            var result = BigDec.init(self.allocator);

            switch (op) {
                .add_assign => result.add(current, rhs, self.state.scale) catch return error.OutOfMemory,
                .sub_assign => result.sub(current, rhs, self.state.scale) catch return error.OutOfMemory,
                .mul_assign => result.mul(current, rhs, self.state.scale) catch return error.OutOfMemory,
                .div_assign => result.div(current, rhs, self.state.scale) catch |e| {
                    if (e == error.DivisionByZero) return error.DivisionByZero;
                    return error.OutOfMemory;
                },
                .mod_assign => result.mod(current, rhs, self.state.scale) catch |e| {
                    if (e == error.DivisionByZero) return error.DivisionByZero;
                    return error.OutOfMemory;
                },
                .pow_assign => result.pow(current, rhs, self.state.scale) catch |e| {
                    if (e == error.NonIntegerExponent) return error.NonIntegerExponent;
                    return error.OutOfMemory;
                },
                else => {},
            }

            new_value.deinit(self.allocator);
            new_value = .{ .num = result };
        }

        // Assign to the target
        switch (target.*) {
            .variable => |name| {
                // StoreVariable takes ownership of new_value; return a copy
                // so the caller still owns the printed result.
                const stored = try self.storeVariable(name, new_value);
                new_value = stored;
            },
            .index => {
                try self.storeToTarget(target, new_value);
                // storeToTarget consumed new_value. Swap in an empty value
                // to disarm the errdefer before the echo read can fail.
                new_value = .{ .num = BigDec.init(self.allocator) };
                new_value = try self.evalIndex(target.index.name, target.index.idx);
            },
            .builtin_var => |which| {
                const assigned_num = new_value.asNum() orelse return error.InvalidOperand;
                const int_val = assigned_num.toF64() catch return error.OutOfMemory;
                const val: i64 = @intFromFloat(int_val);

                switch (which) {
                    .scale => self.state.scale = @intCast(@max(0, val)),
                    .ibase => {
                        const base: u8 = @intCast(@max(2, @min(16, val)));
                        self.state.ibase = base;
                    },
                    .obase => {
                        const base: u8 = @intCast(@max(2, @min(16, val)));
                        self.state.obase = base;
                    },
                }
            },
            else => return error.InvalidAssignment,
        }

        return new_value;
    }

    /// Evaluate unary operation
    fn evalUnary(self: *Self, op: UnaryOp, operand_expr: *const Expr) EvalError!Value {
        switch (op) {
            .negate => {
                var v = try self.evaluate(operand_expr);
                defer v.deinit(self.allocator);
                // Deep-copy: asNum returns a struct copy sharing v's limbs, and the
                // deferred v.deinit would free them out from under the result.
                var num = (v.asNum() orelse return error.InvalidOperand)
                    .clone(self.allocator) catch return error.OutOfMemory;
                num.negate();
                return .{ .num = num };
            },
            .pre_inc, .pre_dec => {
                // ++x / --x: modify then return the new value
                const inc = op == .pre_inc;
                var one = BigDec.fromInt(self.allocator, 1) catch return error.OutOfMemory;
                defer one.deinit();

                var current_v = try self.evaluate(operand_expr);
                defer current_v.deinit(self.allocator);
                const current = current_v.asNum() orelse return error.InvalidOperand;

                var new_value = BigDec.init(self.allocator);
                if (inc) {
                    new_value.add(current, one, self.state.scale) catch return error.OutOfMemory;
                } else {
                    new_value.sub(current, one, self.state.scale) catch return error.OutOfMemory;
                }

                const ret = new_value.clone(self.allocator) catch return error.OutOfMemory;
                var owned = Value{ .num = new_value };
                try self.storeToTarget(operand_expr, owned);
                owned = undefined; // ownership transferred to the variable map

                return .{ .num = ret };
            },
            .post_inc, .post_dec => {
                // x++ / x--: return the old value, then modify
                const inc = op == .post_inc;
                var one = BigDec.fromInt(self.allocator, 1) catch return error.OutOfMemory;
                defer one.deinit();

                var current_v = try self.evaluate(operand_expr);
                defer current_v.deinit(self.allocator);
                const current = current_v.asNum() orelse return error.InvalidOperand;

                var ret_num = current.clone(self.allocator) catch return error.OutOfMemory;
                errdefer ret_num.deinit();

                var new_value = BigDec.init(self.allocator);
                if (inc) {
                    new_value.add(current, one, self.state.scale) catch return error.OutOfMemory;
                } else {
                    new_value.sub(current, one, self.state.scale) catch return error.OutOfMemory;
                }

                var owned = Value{ .num = new_value };
                self.storeToTarget(operand_expr, owned) catch {
                    ret_num.deinit();
                    new_value.deinit();
                    return error.InvalidAssignment;
                };
                owned = undefined; // ownership transferred

                return .{ .num = ret_num };
            },
        }
    }

    /// Store a value under an owned copy of `name`.
    ///
    /// Takes ownership of `value`. Returns an independent clone so callers
    /// that still need the value can use it.
    fn storeVariable(self: *Self, name: []const u8, value: Value) EvalError!Value {
        const key = self.allocator.dupe(u8, name) catch return error.OutOfMemory;

        if (self.state.variables.fetchRemove(name)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
            self.allocator.free(kv.key);
        }

        self.state.variables.put(key, value) catch {
            self.allocator.free(key);
            return error.OutOfMemory;
        };

        return value.clone(self.allocator) catch return error.OutOfMemory;
    }

    /// Store a value to a target expression. Takes ownership of `value`.
    fn storeToTarget(self: *Self, target: *const Expr, value: Value) !void {
        switch (target.*) {
            .variable => |name| {
                var stored_copy = try self.storeVariable(name, value);
                stored_copy.deinit(self.allocator);
            },
            .index => |ix| {
                var idx_v = try self.evaluate(ix.idx);
                defer idx_v.deinit(self.allocator);
                const idx_n = idx_v.asNum() orelse return error.InvalidOperand;
                const i_f = idx_n.toF64() catch return error.InvalidOperand;
                if (i_f < 0 or @floor(i_f) != i_f) return error.InvalidOperand;
                const i: usize = @intFromFloat(i_f);
                const slot = try self.getOrCreateArray(ix.name);
                if (i >= slot.*.len) {
                    if (i >= MAX_ARRAY_LEN) return error.InvalidOperand;
                    const new_len = @max(slot.*.len * 2, i + 1);
                    const grown = self.allocator.alloc(Value, new_len) catch return error.OutOfMemory;
                    for (0..slot.*.len) |k| grown[k] = slot.*[k];
                    for (slot.*.len..new_len) |k| grown[k] = .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
                    if (slot.*.len > 0) self.allocator.free(slot.*);
                    slot.* = grown;
                }
                // Takes ownership of value (matches the .variable arm).
                slot.*[i].deinit(self.allocator);
                slot.*[i] = value;
            },
            else => return error.InvalidAssignment,
        }
    }

    /// Look up (or create) an array slot by name.
    fn getOrCreateArray(self: *Self, name: []const u8) EvalError!*[]Value {
        if (self.state.arrays.getPtr(name)) |slot| return slot;
        const key = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        self.state.arrays.put(key, &[_]Value{}) catch return error.OutOfMemory;
        return self.state.arrays.getPtr(name).?;
    }

    /// Evaluate a[i]: clone of the element; 0 when unset or out of bounds.
    fn evalIndex(self: *Self, name: []const u8, idx_expr: *const Expr) EvalError!Value {
        var idx_v = try self.evaluate(idx_expr);
        defer idx_v.deinit(self.allocator);
        const idx_n = idx_v.asNum() orelse return error.InvalidOperand;
        const i_f = idx_n.toF64() catch return error.InvalidOperand;
        if (i_f < 0 or @floor(i_f) != i_f) return error.InvalidOperand;
        const i: usize = @intFromFloat(i_f);
        if (self.state.arrays.get(name)) |slot| {
            if (i < slot.len) return slot[i].clone(self.allocator) catch return error.OutOfMemory;
        }
        return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
    }

    /// Evaluate function call
    fn evalCall(self: *Self, name: []const u8, args: []const *Expr) EvalError!Value {
        // Built-in functions
        if (std.mem.eql(u8, name, "sqrt")) {
            if (args.len != 1) return error.WrongArgCount;

            var arg_v = try self.evaluate(args[0]);
            defer arg_v.deinit(self.allocator);
            const arg = arg_v.asNum() orelse return error.InvalidOperand;

            var result = BigDec.init(self.allocator);
            result.sqrt(arg, self.state.scale) catch |e| {
                if (e == error.NegativeSquareRoot) return error.NegativeSquareRoot;
                return error.OutOfMemory;
            };

            return .{ .num = result };
        }

        if (std.mem.eql(u8, name, "length")) {
            if (args.len != 1) return error.WrongArgCount;

            var arg_v = try self.evaluate(args[0]);
            defer arg_v.deinit(self.allocator);
            const count: i64 = @intCast((arg_v.asNum() orelse return error.InvalidOperand).sigDigitCount());
            return .{ .num = BigDec.fromInt(self.allocator, count) catch return error.OutOfMemory };
        }

        if (std.mem.eql(u8, name, "scale")) {
            if (args.len != 1) return error.WrongArgCount;

            var arg_v = try self.evaluate(args[0]);
            defer arg_v.deinit(self.allocator);
            const arg_n = arg_v.asNum() orelse return error.InvalidOperand;
            const scale_val: i64 = @intCast(arg_n.fracDigitCount());
            return .{ .num = BigDec.fromInt(self.allocator, scale_val) catch return error.OutOfMemory };
        }

        if (std.mem.eql(u8, name, "read")) {
            if (args.len != 0) return error.WrongArgCount;
            // Read one line from stdin; parse it in the current ibase.
            // Invalid input or EOF yields 0 (permissive bc behavior).
            const reader = self.state.stdin_reader orelse
                return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
            var line_buf: [256]u8 = undefined;
            var len: usize = 0;
            while (len < line_buf.len) {
                const ch = reader.takeByte() catch break;
                if (ch == '\n' or ch == '\r') break;
                line_buf[len] = ch;
                len += 1;
            }
            const text = std.mem.trim(u8, line_buf[0..len], " \t");
            // Reject anything that isn't [0-9A-Za-z-] so the BigDec
            // parsers never see garbage digits.
            for (text, 0..) |c, ti| {
                const ok = std.ascii.isAlphanumeric(c) or (c == '-' and ti == 0);
                if (!ok) return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
            }
            const n = BigDec.parseBase(self.allocator, text, self.state.ibase, self.state.scale + 2) catch {
                return .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
            };
            return .{ .num = n };
        }

        if (std.mem.eql(u8, name, "abs")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.abs(self.allocator, x) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "floor")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.floor(self.allocator, x) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "ceil")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.ceil(self.allocator, x) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "round")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.round(self.allocator, x) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "gcd")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.gcd(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "lcm")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.lcm(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "factorial")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.factorial(self.allocator, x) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "band")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.band(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bor")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.bor(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bxor")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.bxor(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bshl")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.bshl(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bshr")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.bshr(self.allocator, pair.a, pair.b) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bnot8")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.bnotWidth(self.allocator, x, 8) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bnot16")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.bnotWidth(self.allocator, x, 16) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bnot32")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.bnotWidth(self.allocator, x, 32) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "bnot64")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.bnotWidth(self.allocator, x, 64) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "rand")) {
            if (args.len != 0) return error.WrongArgCount;
            const n = self.state.nextRand(32768);
            return .{ .num = BigDec.fromInt(self.allocator, @intCast(n)) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "irand")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            if (x.fracDigitCount() != 0 or x.neg or x.isZero()) return error.InvalidOperand;
            const f = x.toF64() catch return error.InvalidOperand;
            if (!std.math.isFinite(f) or f > 0x1_0000_0000 or @floor(f) != f) return error.InvalidOperand;
            const bound: u64 = @intFromFloat(f);
            if (bound == 0) return error.InvalidOperand;
            const r = self.state.nextRand(bound);
            return .{ .num = BigDec.fromInt(self.allocator, @intCast(r)) catch return error.OutOfMemory };
        }

        if (isMathlibName(name) and !self.state.mathlib_loaded) {
            return error.UndefinedFunction;
        }

        if (std.mem.eql(u8, name, "pi")) {
            if (args.len != 0) return error.WrongArgCount;
            return .{ .num = mathlib.pi(self.allocator, self.state.scale) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "e")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.exp(self.allocator, x, self.state.scale) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "l") or (std.mem.eql(u8, name, "log") and args.len == 1)) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.ln(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "log") and args.len == 2) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.logBase(self.allocator, pair.a, pair.b, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "log")) return error.WrongArgCount;
        if (std.mem.eql(u8, name, "log2")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.log2(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "log10")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.log10(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "s") or std.mem.eql(u8, name, "sin")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.sin(self.allocator, x, self.state.scale) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "c") or std.mem.eql(u8, name, "cos")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.cos(self.allocator, x, self.state.scale) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "a") or std.mem.eql(u8, name, "atan")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.atan(self.allocator, x, self.state.scale) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "tan")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.tan(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "asin")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.asin(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "acos")) {
            var x = try self.evalOneNum(args);
            defer x.deinit();
            return .{ .num = mathlib.acos(self.allocator, x, self.state.scale) catch |err| return mapMath(err) };
        }
        if (std.mem.eql(u8, name, "j")) {
            var pair = try self.evalTwoNum(args);
            defer pair.a.deinit();
            defer pair.b.deinit();
            return .{ .num = mathlib.besselJ(self.allocator, pair.a, pair.b, self.state.scale) catch |err| return mapMath(err) };
        }

        // User-defined function
        return self.callFunction(name, args);
    }

    fn evalOneNum(self: *Self, args: []const *Expr) EvalError!BigDec {
        if (args.len != 1) return error.WrongArgCount;
        var v = try self.evaluate(args[0]);
        defer v.deinit(self.allocator);
        const n = v.asNum() orelse return error.InvalidOperand;
        return n.clone(self.allocator) catch return error.OutOfMemory;
    }

    fn evalTwoNum(self: *Self, args: []const *Expr) EvalError!struct { a: BigDec, b: BigDec } {
        if (args.len != 2) return error.WrongArgCount;
        var av = try self.evaluate(args[0]);
        errdefer av.deinit(self.allocator);
        var bv = try self.evaluate(args[1]);
        defer bv.deinit(self.allocator);
        const an = av.asNum() orelse return error.InvalidOperand;
        const bn = bv.asNum() orelse return error.InvalidOperand;
        const a = an.clone(self.allocator) catch return error.OutOfMemory;
        errdefer {
            var tmp = a;
            tmp.deinit();
        }
        const b = bn.clone(self.allocator) catch return error.OutOfMemory;
        av.deinit(self.allocator);
        av = .{ .num = BigDec.init(self.allocator) };
        return .{ .a = a, .b = b };
    }

    fn mapMath(err: anyerror) EvalError {
        return switch (err) {
            error.InvalidOperand => error.InvalidOperand,
            error.DivisionByZero => error.DivisionByZero,
            error.NegativeSquareRoot => error.NegativeSquareRoot,
            error.NonIntegerExponent => error.NonIntegerExponent,
            else => error.OutOfMemory,
        };
    }

    fn isMathlibName(name: []const u8) bool {
        const names = [_][]const u8{
            "s",   "c",    "a",    "l",     "e",    "pi",   "j",
            "sin", "cos",  "tan",  "t",     "atan", "asin", "acos",
            "log", "log2", "log10",
        };
        for (names) |n| {
            if (std.mem.eql(u8, name, n)) return true;
        }
        return false;
    }

    /// Call a user-defined function by name with evaluated args.
    /// Returns Value result (num 0 for void functions).
    pub fn callFunction(self: *Self, name: []const u8, args: []const *Expr) EvalError!Value {
        const def = self.state.functions.get(name) orelse return error.UndefinedFunction;
        if (args.len != def.params.len) return error.WrongArgCount;

        // Push a binding frame; all bindings (params, autos, standalone
        // auto statements in the body) unwind against it on exit.
        self.frames.append(self.allocator, .{}) catch return error.OutOfMemory;
        // Index, not pointer: nested calls push frames and the list may
        // reallocate, invalidating pointers into items.
        const my = self.frames.items.len - 1;
        // On any error after this point the frame must unwind: bindings
        // installed for this call are removed and the frame is popped.
        errdefer self.unwindFrame(my);

        // Reference params to copy back on exit (param name, dest name).
        var ref_params: std.ArrayList(struct { pname: []const u8, dest: []const u8 }) = .empty;
        defer ref_params.deinit(self.allocator);

        for (def.params, 0..) |pspec, idx| {
            switch (pspec.kind) {
                .scalar => {
                    var arg_val = try self.evaluate(args[idx]);
                    const fr = &self.frames.items[my];
                    self.pushBinding(pspec.name, arg_val, &fr.saved_vals, &fr.saved_keys) catch |e| {
                        arg_val.deinit(self.allocator);
                        return e;
                    };
                },
                .array_copy, .array_ref => {
                    const src_name = switch (args[idx].*) {
                        .array_ref => |n| n,
                        else => return error.InvalidOperand,
                    };
                    const src_slot = self.state.arrays.get(src_name) orelse &[_]Value{};
                    const copy = self.allocator.alloc(Value, src_slot.len) catch return error.OutOfMemory;
                    for (src_slot, 0..) |*v, k| copy[k] = v.clone(self.allocator) catch {
                        for (0..k) |j| copy[j].deinit(self.allocator);
                        self.allocator.free(copy);
                        return error.OutOfMemory;
                    };
                    const fr = &self.frames.items[my];
                    self.pushArrayBinding(pspec.name, copy, &fr.arr_saved, &fr.arr_keys) catch |e| {
                        for (copy) |*v| v.deinit(self.allocator);
                        self.allocator.free(copy);
                        return e;
                    };
                    if (pspec.kind == .array_ref) {
                        const fk = &self.frames.items[my].arr_keys;
                        ref_params.append(self.allocator, .{ .pname = fk.items[fk.items.len - 1], .dest = src_name }) catch return error.OutOfMemory;
                    }
                },
            }
        }

        for (def.auto_vars) |av| {
            const fr = &self.frames.items[my];
            try self.bindAutoEntry(av, &fr.saved_vals, &fr.saved_keys, &fr.arr_saved, &fr.arr_keys);
        }

        // Execute body.
        var result: Value = .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
        errdefer result.deinit(self.allocator);
        const f = try self.execute(def.body, self.func_stdout.?, 1, null);
        switch (f) {
            .ret => |maybe_v| {
                if (maybe_v) |v| {
                    result.deinit(self.allocator);
                    result = v;
                }
            },
            else => {},
        }

        // Copy reference-param arrays back to the caller.
        var ri = ref_params.items.len;
        while (ri > 0) {
            ri -= 1;
            const rp = ref_params.items[ri];
            if (self.state.arrays.get(rp.pname)) |cur| {
                const cloned = self.allocator.alloc(Value, cur.len) catch continue;
                for (cur, 0..) |*v, k| cloned[k] = v.clone(self.allocator) catch {
                    for (0..k) |j| cloned[j].deinit(self.allocator);
                    self.allocator.free(cloned);
                    continue;
                };
                if (self.getOrCreateArray(rp.dest)) |d| {
                    for (d.*) |*v| v.deinit(self.allocator);
                    if (d.*.len > 0) self.allocator.free(d.*);
                    d.* = cloned;
                } else |_| {
                    for (cloned) |*v| v.deinit(self.allocator);
                    self.allocator.free(cloned);
                }
            }
        }

        self.unwindFrame(my);
        return result;
    }

    /// Unwind the binding frame at index `my`: remove the bindings
    /// installed for the call, restore saved state, free the frame, pop it.
    fn unwindFrame(self: *Self, my: usize) void {
        const frame = &self.frames.items[my];
        var ai = frame.arr_saved.items.len;
        while (ai > 0) {
            ai -= 1;
            if (self.state.arrays.fetchRemove(frame.arr_keys.items[ai])) |kv| {
                for (kv.value) |*v| v.deinit(self.allocator);
                if (kv.value.len > 0) self.allocator.free(kv.value);
                self.allocator.free(kv.key);
            }
            if (frame.arr_saved.items[ai]) |saved_arr| {
                self.state.arrays.put(frame.arr_keys.items[ai], saved_arr) catch {};
                frame.arr_saved.items[ai] = null;
            }
        }
        self.popBindings(&frame.saved_vals, &frame.saved_keys);
        frame.saved_vals.deinit(self.allocator);
        frame.saved_keys.deinit(self.allocator);
        frame.arr_saved.deinit(self.allocator);
        frame.arr_keys.deinit(self.allocator);
        _ = self.frames.pop();
    }

    /// Bind one auto entry: scalar to 0, array to sizeexpr zeros.
    fn bindAutoEntry(
        self: *Self,
        av: @import("parse.zig").AutoEntry,
        saved_vals: *std.ArrayList(?Value),
        saved_keys: *std.ArrayList([]const u8),
        arr_saved: *std.ArrayList(?[]Value),
        arr_keys: *std.ArrayList([]const u8),
    ) EvalError!void {
        if (av.size) |size_expr| {
            var sz_v = try self.evaluate(size_expr);
            defer sz_v.deinit(self.allocator);
            const sz_n = sz_v.asNum() orelse return error.InvalidOperand;
            const sz_f = sz_n.toF64() catch return error.InvalidOperand;
            if (sz_f < 0) return error.InvalidOperand;
            const n: usize = @intFromFloat(@floor(sz_f));
            if (n > MAX_ARRAY_LEN) return error.InvalidOperand;
            const slot = self.allocator.alloc(Value, n) catch return error.OutOfMemory;
            for (slot) |*v| v.* = .{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
            self.pushArrayBinding(av.name, slot, arr_saved, arr_keys) catch |e| {
                for (slot) |*v| v.deinit(self.allocator);
                self.allocator.free(slot);
                return e;
            };
        } else {
            var zero = Value{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory };
            self.pushBinding(av.name, zero, saved_vals, saved_keys) catch |e| {
                zero.deinit(self.allocator);
                return e;
            };
        }
    }
    fn pushBinding(
        self: *Self,
        name: []const u8,
        value: Value,
        saved_vals: *std.ArrayList(?Value),
        saved_keys: *std.ArrayList([]const u8),
    ) EvalError!void {
        const key = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        const existing = self.state.variables.fetchRemove(name);
        try saved_vals.append(self.allocator, if (existing) |kv| kv.value else null);
        try saved_keys.append(self.allocator, if (existing) |kv| kv.key else key);
        try self.state.variables.put(key, value);
    }

    fn popBindings(
        self: *Self,
        saved_vals: *std.ArrayList(?Value),
        saved_keys: *std.ArrayList([]const u8),
    ) void {
        var i = saved_vals.items.len;
        while (i > 0) {
            i -= 1;
            // Remove current binding entirely (key + value).
            if (self.state.variables.fetchRemove(name_at(saved_keys.items, i))) |kv| {
                var vv = kv.value;
                vv.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
            const old_val = saved_vals.items[i];
            if (old_val) |ov| {
                self.state.variables.put(saved_keys.items[i], ov) catch {};
                saved_vals.items[i] = null;
            }
        }
    }

    fn name_at(keys: []const []const u8, i: usize) []const u8 {
        return keys[i];
    }
    /// Bind an array slot: removes the current slot under name (if any)
    /// and installs slot, remembering the old state for popArrayBinding.
    fn pushArrayBinding(
        self: *Self,
        name: []const u8,
        slot: []Value,
        saved: *std.ArrayList(?[]Value),
        saved_keys: *std.ArrayList([]const u8),
    ) EvalError!void {
        const key = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        const existing = self.state.arrays.fetchRemove(name);
        try saved.append(self.allocator, if (existing) |kv| kv.value else null);
        try saved_keys.append(self.allocator, if (existing) |kv| kv.key else key);
        self.state.arrays.put(key, slot) catch return error.OutOfMemory;
    }

    /// Restore one array binding pushed by pushArrayBinding (top of
    /// stack). With copy_back_to set, the current slot values are first
    /// cloned into that array (bc *a[] reference semantics).
    fn popArrayBinding(
        self: *Self,
        name: []const u8,
        saved: *std.ArrayList(?[]Value),
        saved_keys: *std.ArrayList([]const u8),
        copy_back_to: ?[]const u8,
    ) void {
        const i = saved.items.len - 1;
        if (copy_back_to) |dest| {
            if (self.state.arrays.get(name)) |cur| {
                if (self.getOrCreateArray(dest)) |d| {
                    for (d.*) |*v| v.deinit(self.allocator);
                    if (d.*.len > 0) self.allocator.free(d.*);
                    const cloned = self.allocator.alloc(Value, cur.len) catch return;
                    for (cur, 0..) |*v, k| cloned[k] = v.clone(self.allocator) catch .{ .num = BigDec.init(self.allocator) };
                    d.* = cloned;
                } else |_| {}
            }
        }
        if (self.state.arrays.fetchRemove(saved_keys.items[i])) |kv| {
            for (kv.value) |*v| v.deinit(self.allocator);
            if (kv.value.len > 0) self.allocator.free(kv.value);
            self.allocator.free(kv.key);
        }
        if (saved.items[i]) |old| {
            self.state.arrays.put(saved_keys.items[i], old) catch {};
            saved.items[i] = null;
        }
        _ = saved.items.pop();
        _ = saved_keys.pop();
    }

    /// Execute a statement; returns control-flow signal. `stdout` receives
    /// print output. Caller owns any returned BigDec in Flow.ret.
    /// Execute `stmt`. If `consumed` is provided, it is set to true when
    /// execute() took ownership of the statement's children (func_def).
    pub fn execute(
        self: *Self,
        stmt: *Stmt,
        stdout: anytype,
        depth: usize,
        consumed: ?*bool,
    ) EvalError!Flow {
        if (depth > 512) return error.InvalidAssignment; // recursion guard
        switch (stmt.*) {
            .noop => return .normal,
            .auto => |entries| {
                if (self.frames.items.len == 0) {
                    self.frames.append(self.allocator, .{}) catch return error.OutOfMemory;
                }
                for (entries) |av| {
                    const frame = &self.frames.items[self.frames.items.len - 1];
                    try self.bindAutoEntry(av, &frame.saved_vals, &frame.saved_keys, &frame.arr_saved, &frame.arr_keys);
                }
                return .normal;
            },
            .expr => |e| {
                var v = try self.evaluate(e);
                v.deinit(self.allocator);
                return .normal;
            },
            .print => |exprs| {
                for (exprs) |e| {
                    var v = try self.evaluate(e);
                    defer v.deinit(self.allocator);
                    switch (v) {
                        .str => |s| {
                            // Strings emit literally, without a trailing newline
                            // or color (bc semantics).
                            try stdout.writeAll(s);
                        },
                        .num => |nn| {
                            var n = nn;
                            if (self.state.color_enabled) {
                                if (n.isNegative()) {
                                    try stdout.writeAll(@import("main.zig").Color.number_neg);
                                } else {
                                    try stdout.writeAll(@import("main.zig").Color.number);
                                }
                            }
                            try n.format(stdout, self.state.obase, self.state.scale);
                            if (self.state.color_enabled) {
                                try stdout.writeAll(@import("main.zig").Color.reset);
                            }
                            try stdout.writeAll("\n");
                        },
                    }
                }
                return .normal;
            },
            .if_stmt => |s| {
                var c_v = try self.evaluate(s.cond);
                defer c_v.deinit(self.allocator);
                const c = c_v.asNum() orelse return error.InvalidOperand;
                const truthy = !c.isZero();
                if (truthy) {
                    return self.execute(s.then_branch, stdout, depth + 1, null);
                } else if (s.else_branch) |eb| {
                    return self.execute(eb, stdout, depth + 1, null);
                }
                return .normal;
            },
            .while_stmt => |s| {
                var iter: usize = 0;
                while (true) {
                    iter += 1;
                    if (iter > 100000) return error.InvalidBreak;
                    var c_v = try self.evaluate(s.cond);
                    defer c_v.deinit(self.allocator);
                    const c = c_v.asNum() orelse return error.InvalidOperand;
                    const truthy = !c.isZero();
                    if (!truthy) break;
                    var body_consumed = false;
                    const f = self.execute(s.body, stdout, depth + 1, &body_consumed) catch |e| {
                        if (e == error.InvalidBreak) break;
                        if (e == error.InvalidContinue) continue;
                        return e;
                    };
                    switch (f) {
                        .break_loop => break,
                        .quit, .halt, .ret => return f,
                        else => {},
                    }
                }
                return .normal;
            },
            .for_stmt => |s| {
                if (s.init) |e| {
                    var v = try self.evaluate(e);
                    v.deinit(self.allocator);
                }
                while (true) {
                    if (s.cond) |ce| {
                        var c_v = try self.evaluate(ce);
                        defer c_v.deinit(self.allocator);
                        const c = c_v.asNum() orelse return error.InvalidOperand;
                        const truthy = !c.isZero();
                        if (!truthy) break;
                    }
                    var body_consumed = false;
                    const f = self.execute(s.body, stdout, depth + 1, &body_consumed) catch |e| {
                        if (e == error.InvalidBreak) break;
                        if (e == error.InvalidContinue) continue;
                        return e;
                    };
                    switch (f) {
                        .break_loop => break,
                        .quit, .halt, .ret => return f,
                        else => {},
                    }
                    if (s.update) |ue| {
                        var v = try self.evaluate(ue);
                        v.deinit(self.allocator);
                    }
                }
                return .normal;
            },
            .break_stmt => return error.InvalidBreak,
            .continue_stmt => return error.InvalidContinue,
            .halt => return .{ .halt = {} },
            .quit => return .{ .quit = {} },
            .block => |stmts| {
                for (stmts) |s| {
                    var child_consumed = false;
                    const f = self.execute(s, stdout, depth + 1, &child_consumed) catch |e| {
                        // let break/continue bubble to loop handlers
                        if (e == error.InvalidBreak or e == error.InvalidContinue) {
                            return e;
                        }
                        return e;
                    };
                    switch (f) {
                        .normal => {},
                        else => return f,
                    }
                }
                return .normal;
            },
            .func_def => |f| {
                // Take ownership of the parsed definition: the enclosing
                // statement tree is freed after execution, so the stored
                // function must own its body and param/auto slices.
                // f.name is a heap dupe from parseDefine; transfer it to
                // the stored definition instead of duplicating again.
                const def = FunctionDef{
                    .name = f.name,
                    .params = f.params,
                    .auto_vars = f.auto_vars,
                    .body = f.body,
                };
                // Prevent Stmt.deinit from freeing the moved subtree.
                // (func_def is a value captured by the switch; the caller
                // checks `stmt.* == .func_def` and skips freeing entirely.)
                stmt.* = .{ .break_stmt = {} };
                if (consumed) |c| c.* = true;
                if (self.state.functions.fetchRemove(f.name)) |kv| {
                    kv.value.body.deinit(self.allocator);
                    self.allocator.destroy(kv.value.body);
                    for (kv.value.params) |ps| self.allocator.free(ps.name);
                    if (kv.value.params.len > 0) self.allocator.free(kv.value.params);
                    for (kv.value.auto_vars) |av| {
                        self.allocator.free(av.name);
                        if (av.size) |sz| {
                            sz.deinit(self.allocator);
                            self.allocator.destroy(sz);
                        }
                    }
                    if (kv.value.auto_vars.len > 0) self.allocator.free(kv.value.auto_vars);
                    self.allocator.free(kv.key);
                }
                self.state.functions.put(def.name, def) catch {
                    self.allocator.free(def.name);
                    return error.OutOfMemory;
                };
                return .normal;
            },
            .return_stmt => |maybe_e| {
                if (maybe_e) |e| {
                    const v = try self.evaluate(e);
                    return Flow{ .ret = v };
                }
                return Flow{ .ret = null };
            },
        }
    }

    /// True when flow unwinds the current function body.
    fn isReturn(f: Flow) bool {
        return switch (f) {
            .ret => true,
            else => false,
        };
    }
};

// ============= Tests =============

test "Evaluator simple number" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    defer state.deinit();

    var num = try BigDec.fromInt(allocator, 42);
    const expr = Expr{ .number = num };

    var evaluator = Evaluator.init(&state);
    var result = try evaluator.evaluate(&expr);
    defer result.deinit(allocator);

    const val = try result.asNum().?.toF64();
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), val, 0.0001);

    num.deinit();
}

test "Evaluator addition" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    defer state.deinit();

    // Create 10 + 20
    var left_num = try BigDec.fromInt(allocator, 10);
    var right_num = try BigDec.fromInt(allocator, 20);

    const left_expr = try allocator.create(Expr);
    left_expr.* = .{ .number = left_num };
    const right_expr = try allocator.create(Expr);
    right_expr.* = .{ .number = right_num };

    const expr = Expr{ .binary = .{
        .left = left_expr,
        .op = .add,
        .right = right_expr,
    } };

    var evaluator = Evaluator.init(&state);
    var result = try evaluator.evaluate(&expr);
    defer result.deinit(allocator);

    const val = try result.asNum().?.toF64();
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), val, 0.0001);

    // Cleanup
    left_num.deinit();
    allocator.destroy(left_expr);
    right_num.deinit();
    allocator.destroy(right_expr);
}

test "invalid assignment frees value" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    defer state.deinit();

    var lexer = Lexer.init("1 = 2");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const stmt = (try parser.parseTopLevel()).?;
    defer {
        stmt.deinit(allocator);
        allocator.destroy(stmt);
    }

    var evaluator = Evaluator.init(&state);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // std.testing.allocator fails this test if evalAssignment leaks the
    // value it built before rejecting the target.
    try std.testing.expectError(error.InvalidAssignment, evaluator.execute(stmt, &w, 0, null));
}

test "return at top level yields ret flow" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    defer state.deinit();

    var lexer = Lexer.init("return 5");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const stmt = (try parser.parseTopLevel()).?;
    defer {
        stmt.deinit(allocator);
        allocator.destroy(stmt);
    }

    var evaluator = Evaluator.init(&state);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const flow = try evaluator.execute(stmt, &w, 0, null);
    try std.testing.expect(flow == .ret);
    if (flow.ret) |v| {
        var vv = v;
        vv.deinit(allocator);
    }
}

test "return inside while returns immediately" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    defer state.deinit();

    var lexer = Lexer.init("while (1) { return 5 }");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const stmt = (try parser.parseTopLevel()).?;
    defer {
        stmt.deinit(allocator);
        allocator.destroy(stmt);
    }

    var evaluator = Evaluator.init(&state);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // The loop must not swallow the return: before the flow switch
    // bubbled .ret, this spun to the iteration cap and errored.
    const flow = try evaluator.execute(stmt, &w, 0, null);
    try std.testing.expect(flow == .ret);
    if (flow.ret) |v| {
        var vv = v;
        vv.deinit(allocator);
    }
}


fn evalPrinted(state: *State, src: []const u8) ![]u8 {
    var lexer = Lexer.init(src);
    var parser = Parser.init(&lexer, state.allocator);
    defer parser.deinit();
    const stmt = (try parser.parseTopLevel()).?;
    defer {
        stmt.deinit(state.allocator);
        state.allocator.destroy(stmt);
    }
    const expr = switch (stmt.*) {
        .expr => |e| e,
        else => return error.InvalidOperand,
    };
    var evaluator = Evaluator.init(state);
    var v = try evaluator.evaluate(expr);
    defer v.deinit(state.allocator);
    const n = v.asNum() orelse return error.InvalidOperand;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try n.format(&w, 10, state.scale);
    return state.allocator.dupe(u8, w.buffered());
}

test "rand repeats after seed" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();
    state.color_enabled = false;
    state.seedRng(1);
    const a = try evalPrinted(&state, "rand()");
    defer allocator.free(a);
    const b = try evalPrinted(&state, "rand()");
    defer allocator.free(b);
    state.seedRng(1);
    const c = try evalPrinted(&state, "rand()");
    defer allocator.free(c);
    try std.testing.expectEqualStrings(a, c);
}

test "irand stays in range" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();
    state.color_enabled = false;
    state.seedRng(7);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const out = try evalPrinted(&state, "irand(10)");
        defer allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        const n = try std.fmt.parseInt(i64, trimmed, 10);
        try std.testing.expect(n >= 0 and n < 10);
    }
}
