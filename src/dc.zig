//! dc-style RPN stack evaluator.
//!
//! One line at a time; tokens are single characters. Values on the stack
//! are owned Value unions (numbers and strings). Registers sX/lX map onto
//! the same storage as infix variables so both modes share state.
//!
//! Macros: `x` executes a popped string. `S`/`L` save/restore a register
//! on a hidden stack. `>r` `<r` `=r` (and `!>` `!<` `!=`) run register r
//! when the comparison of (top, second) holds. `?` reads a stdin line and
//! executes it. `q` unwinds two execution levels; `Q` pops a count.
//! `Z` digit count, `X` scale-of, `|` modexp, `:r`/`;r` array registers.
const std = @import("std");
const BigDec = @import("num.zig").BigDec;
const Value = @import("eval.zig").Value;
const MAX_ARRAY_LEN = @import("eval.zig").MAX_ARRAY_LEN;
const main = @import("main.zig");
const State = main.State;

pub const Error = error{
    StackEmpty,
    InvalidOperand,
    UnexpectedToken,
    DivisionByZero,
    NonIntegerExponent,
    NegativeSquareRoot,
    OutOfMemory,
    WriteFailed,
    InvalidBase,
    InternalDivisionOverflow,
};

pub const Dc = struct {
    state: *State,
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Value) = .empty,
    /// Hidden stacks for GNU/POSIX `S`/`L` (one list per register byte).
    reg_hidden: std.AutoHashMap(u8, std.ArrayList(Value)),
    quit_requested: bool = false,
    exec_depth: u32 = 0,
    /// Remaining execution levels to leave (`q`/`Q`).
    unwind: u32 = 0,

    const Self = @This();

    pub fn init(state: *State) Self {
        return .{
            .state = state,
            .allocator = state.allocator,
            .reg_hidden = std.AutoHashMap(u8, std.ArrayList(Value)).init(state.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |*v| v.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        var it = self.reg_hidden.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |*v| v.deinit(self.allocator);
            e.value_ptr.deinit(self.allocator);
        }
        self.reg_hidden.deinit();
    }

    fn push(self: *Self, v: Value) !void {
        try self.stack.append(self.allocator, v);
    }

    fn pop(self: *Self) !Value {
        if (self.stack.items.len == 0) return error.StackEmpty;
        return self.stack.pop().?;
    }

    fn popNum(self: *Self) !BigDec {
        var v = try self.pop();
        defer v.deinit(self.allocator);
        // Deep copy: the deferred deinit would free the limbs of a plain
        // struct copy before the caller uses them.
        const n = v.asNum() orelse return error.InvalidOperand;
        return n.clone(self.allocator) catch return error.OutOfMemory;
    }

    fn binary(self: *Self, op: fn (*BigDec, BigDec, BigDec, usize) @import("num.zig").Error!void) !void {
        if (self.stack.items.len < 2) return error.StackEmpty;
        var b = try self.popNum();
        defer b.deinit();
        var a = try self.popNum();
        defer a.deinit();
        var r = BigDec.init(self.allocator);
        errdefer r.deinit();
        op(&r, a, b, self.state.scale) catch |e| switch (e) {
            error.DivisionByZero => return error.DivisionByZero,
            error.NonIntegerExponent => return error.NonIntegerExponent,
            else => return error.OutOfMemory,
        };
        try self.push(.{ .num = r });
    }

    fn hiddenOf(self: *Self, reg: u8) !*std.ArrayList(Value) {
        const gop = try self.reg_hidden.getOrPut(reg);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        return gop.value_ptr;
    }

    fn storeRegister(self: *Self, reg: u8, v: Value) !void {
        var key: [1]u8 = .{reg};
        if (self.state.variables.fetchRemove(&key)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
        const k2 = try self.allocator.dupe(u8, &key);
        self.state.variables.put(k2, v) catch return error.OutOfMemory;
    }

    fn asIndex(n: BigDec) Error!usize {
        const f = n.toF64() catch return error.InvalidOperand;
        if (f < 0 or @floor(f) != f) return error.InvalidOperand;
        if (f >= @as(f64, @floatFromInt(MAX_ARRAY_LEN))) return error.InvalidOperand;
        return @intFromFloat(f);
    }

    fn arraySlot(self: *Self, name: u8) Error!*[]Value {
        var key: [1]u8 = .{name};
        if (self.state.arrays.getPtr(&key)) |slot| return slot;
        const owned = self.allocator.dupe(u8, &key) catch return error.OutOfMemory;
        self.state.arrays.put(owned, &[_]Value{}) catch return error.OutOfMemory;
        return self.state.arrays.getPtr(&key).?;
    }

    fn storeArray(self: *Self, name: u8, index: usize, value: Value) Error!void {
        if (index >= MAX_ARRAY_LEN) {
            var tmp = value;
            tmp.deinit(self.allocator);
            return error.InvalidOperand;
        }
        const slot = try self.arraySlot(name);
        if (index >= slot.*.len) {
            const new_len = @max(slot.*.len * 2, index + 1);
            const grown = self.allocator.alloc(Value, new_len) catch {
                var tmp = value;
                tmp.deinit(self.allocator);
                return error.OutOfMemory;
            };
            for (0..slot.*.len) |k| grown[k] = slot.*[k];
            var k = slot.*.len;
            while (k < new_len) : (k += 1) {
                grown[k] = .{ .num = BigDec.fromInt(self.allocator, 0) catch {
                    var tmp = value;
                    tmp.deinit(self.allocator);
                    return error.OutOfMemory;
                } };
            }
            if (slot.*.len > 0) self.allocator.free(slot.*);
            slot.* = grown;
        }
        slot.*[index].deinit(self.allocator);
        slot.*[index] = value;
    }

    /// Execute a popped value as a macro. Takes ownership of `v`.
    fn execValue(self: *Self, v: Value, stdout: *std.Io.Writer) Error!bool {
        switch (v) {
            .str => |s| {
                defer self.allocator.free(s);
                return self.execInput(s, stdout);
            },
            .num => |n| {
                // GNU: executing a number pushes it back.
                try self.push(.{ .num = n });
                return true;
            },
        }
    }

    fn execRegister(self: *Self, reg: u8, stdout: *std.Io.Writer) Error!bool {
        var key: [1]u8 = .{reg};
        if (self.state.variables.getPtr(&key)) |vp| {
            switch (vp.*) {
                .str => |s| return self.execInput(s, stdout),
                .num => return true,
            }
        }
        return true;
    }

    /// Pop top `a` and second `b`. Run register `reg` if `a rel b`.
    fn compareExec(
        self: *Self,
        rel: u8,
        invert: bool,
        reg: u8,
        stdout: *std.Io.Writer,
    ) Error!bool {
        var a = try self.popNum();
        defer a.deinit();
        var b = try self.popNum();
        defer b.deinit();
        const order = BigDec.cmp(a, b);
        const truth = switch (rel) {
            '>' => order == .gt,
            '<' => order == .lt,
            '=' => order == .eq,
            else => return error.UnexpectedToken,
        };
        if (truth != invert) return self.execRegister(reg, stdout);
        return true;
    }

    fn readAndExec(self: *Self, stdout: *std.Io.Writer) Error!bool {
        const reader = self.state.stdin_reader orelse return true;
        var line_buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < line_buf.len) {
            const ch = reader.takeByte() catch break;
            if (ch == '\n') break;
            if (ch == '\r') continue;
            line_buf[len] = ch;
            len += 1;
        }
        return self.execInput(line_buf[0..len], stdout);
    }

    /// Process one dc line. Returns false when `q`/`Q` ends this level
    /// (and, at the top level, when dc itself should exit).
    pub fn processLine(self: *Self, line: []const u8, stdout: *std.Io.Writer) Error!bool {
        return self.execInput(line, stdout);
    }

    fn execInput(self: *Self, line: []const u8, stdout: *std.Io.Writer) Error!bool {
        self.exec_depth += 1;
        defer self.exec_depth -= 1;

        const keep = try self.processChunk(line, stdout);

        if (self.unwind > 0) {
            self.unwind -= 1;
            if (self.exec_depth == 1) {
                if (self.unwind > 0) self.quit_requested = true;
                self.unwind = 0;
                return false;
            }
            return false;
        }
        return keep;
    }

    fn processChunk(self: *Self, line: []const u8, stdout: *std.Io.Writer) Error!bool {
        var i: usize = 0;
        while (i < line.len) {
            if (self.unwind > 0) break;
            const c = line[i];
            i += 1;
            switch (c) {
                ' ', '\t', '\r', '\n' => {},
                '0'...'9', '.', '_', 'A'...'F' => {
                    const neg = c == '_';
                    if (c >= 'A' and c <= 'F' and self.state.ibase <= 10) {
                        return error.UnexpectedToken;
                    }
                    if (!neg) i -= 1;
                    const start = i;
                    while (i < line.len) {
                        const sc = line[i];
                        if (std.ascii.isDigit(sc) or sc == '.') {
                            i += 1;
                        } else if (self.state.ibase > 10 and std.ascii.isUpper(sc) and
                            sc < 'A' + self.state.ibase - 10)
                        {
                            i += 1;
                        } else break;
                    }
                    var n = BigDec.parseBase(self.allocator, line[start..i], self.state.ibase, self.state.scale + 2) catch {
                        try stdout.writeAll("dc: bad number\n");
                        continue;
                    };
                    if (neg) n.negate();
                    try self.push(.{ .num = n });
                },
                '[' => {
                    const start = i;
                    var depth: usize = 1;
                    while (i < line.len and depth > 0) : (i += 1) {
                        switch (line[i]) {
                            '[' => depth += 1,
                            ']' => depth -= 1,
                            else => {},
                        }
                    }
                    if (depth != 0) return error.UnexpectedToken;
                    const content = line[start .. i - 1];
                    try self.push(.{ .str = self.allocator.dupe(u8, content) catch return error.OutOfMemory });
                },
                '+' => try self.binary(BigDec.add),
                '-' => try self.binary(BigDec.sub),
                '*' => try self.binary(BigDec.mul),
                '/' => try self.binary(BigDec.div),
                '%' => try self.binary(BigDec.mod),
                '^' => try self.binary(BigDec.pow),
                'v' => {
                    var a = try self.popNum();
                    defer a.deinit();
                    var r = BigDec.init(self.allocator);
                    r.sqrt(a, self.state.scale) catch |e| switch (e) {
                        error.NegativeSquareRoot => return error.NegativeSquareRoot,
                        else => return error.OutOfMemory,
                    };
                    try self.push(.{ .num = r });
                },
                'p' => {
                    if (self.stack.items.len == 0) return error.StackEmpty;
                    try self.printValue(self.stack.items[self.stack.items.len - 1], stdout);
                    try stdout.writeByte('\n');
                },
                'n' => {
                    var v = try self.pop();
                    defer v.deinit(self.allocator);
                    try self.printValue(v, stdout);
                },
                'f' => {
                    var j = self.stack.items.len;
                    while (j > 0) {
                        j -= 1;
                        try self.printValue(self.stack.items[j], stdout);
                        try stdout.writeByte('\n');
                    }
                },
                'P' => {
                    var v = try self.pop();
                    defer v.deinit(self.allocator);
                    switch (v) {
                        .str => |s| try stdout.writeAll(s),
                        .num => |*n| {
                            var buf: [4096]u8 = undefined;
                            var w: std.Io.Writer = .fixed(&buf);
                            n.format(&w, 10, 0) catch {};
                            try stdout.writeAll(w.buffered());
                        },
                    }
                },
                'c' => {
                    for (self.stack.items) |*v| v.deinit(self.allocator);
                    self.stack.clearRetainingCapacity();
                },
                'd' => {
                    if (self.stack.items.len == 0) return error.StackEmpty;
                    const top = self.stack.items[self.stack.items.len - 1];
                    try self.push(try top.clone(self.allocator));
                },
                'r' => {
                    if (self.stack.items.len < 2) return error.StackEmpty;
                    const n = self.stack.items.len;
                    const tmp = self.stack.items[n - 1];
                    self.stack.items[n - 1] = self.stack.items[n - 2];
                    self.stack.items[n - 2] = tmp;
                },
                'R' => {
                    var v = try self.pop();
                    v.deinit(self.allocator);
                },
                'z' => {
                    const d = BigDec.fromInt(self.allocator, @intCast(self.stack.items.len)) catch return error.OutOfMemory;
                    try self.push(.{ .num = d });
                },
                's' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    var v = try self.pop();
                    defer v.deinit(self.allocator);
                    try self.storeRegister(reg, v.clone(self.allocator) catch return error.OutOfMemory);
                },
                'S' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    const v = try self.pop();
                    var key: [1]u8 = .{reg};
                    const hidden = try self.hiddenOf(reg);
                    if (self.state.variables.fetchRemove(&key)) |kv| {
                        try hidden.append(self.allocator, kv.value);
                        self.allocator.free(kv.key);
                    } else {
                        try hidden.append(self.allocator, .{
                            .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory,
                        });
                    }
                    try self.storeRegister(reg, v);
                },
                'l' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    var key: [1]u8 = .{reg};
                    if (self.state.variables.getPtr(&key)) |vp| {
                        try self.push(try vp.clone(self.allocator));
                    } else {
                        try self.push(.{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory });
                    }
                },
                'L' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    const hidden = try self.hiddenOf(reg);
                    if (hidden.items.len == 0) return error.StackEmpty;
                    const restored = hidden.pop().?;
                    var key: [1]u8 = .{reg};
                    if (self.state.variables.fetchRemove(&key)) |kv| {
                        try self.push(kv.value);
                        self.allocator.free(kv.key);
                    } else {
                        try self.push(.{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory });
                    }
                    try self.storeRegister(reg, restored);
                },
                'x' => {
                    const v = try self.pop();
                    if (!try self.execValue(v, stdout)) break;
                },
                '>' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    if (!try self.compareExec('>', false, reg, stdout)) break;
                },
                '<' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    if (!try self.compareExec('<', false, reg, stdout)) break;
                },
                '=' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    if (!try self.compareExec('=', false, reg, stdout)) break;
                },
                '!' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const rel = line[i];
                    if (rel != '>' and rel != '<' and rel != '=') return error.UnexpectedToken;
                    i += 1;
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    if (!try self.compareExec(rel, true, reg, stdout)) break;
                },
                '?' => {
                    if (!try self.readAndExec(stdout)) break;
                },
                'i' => {
                    var n = try self.popNum();
                    defer n.deinit();
                    const f = n.toF64() catch return error.InvalidOperand;
                    if (f < 2 or f > 16) return error.InvalidOperand;
                    self.state.ibase = @intFromFloat(f);
                },
                'o' => {
                    var n = try self.popNum();
                    defer n.deinit();
                    const f = n.toF64() catch return error.InvalidOperand;
                    if (f < 2 or f > 16) return error.InvalidOperand;
                    self.state.obase = @intFromFloat(f);
                },
                'k' => {
                    var n = try self.popNum();
                    defer n.deinit();
                    const f = n.toF64() catch return error.InvalidOperand;
                    if (f < 0) return error.InvalidOperand;
                    self.state.scale = @intFromFloat(f);
                },
                'I' => try self.push(.{ .num = BigDec.fromInt(self.allocator, self.state.ibase) catch return error.OutOfMemory }),
                'O' => try self.push(.{ .num = BigDec.fromInt(self.allocator, self.state.obase) catch return error.OutOfMemory }),
                'K' => try self.push(.{ .num = BigDec.fromInt(self.allocator, @intCast(self.state.scale)) catch return error.OutOfMemory }),
                'q' => {
                    self.unwind = 2;
                    break;
                },
                'Q' => {
                    var n = try self.popNum();
                    defer n.deinit();
                    const f = n.toF64() catch return error.InvalidOperand;
                    if (f < 0) return error.InvalidOperand;
                    const levels: u32 = @intFromFloat(@floor(f));
                    if (levels == 0) continue;
                    self.unwind = levels;
                    break;
                },
                'Z' => {
                    var v = try self.pop();
                    defer v.deinit(self.allocator);
                    const count: i64 = switch (v) {
                        .str => |s| @intCast(s.len),
                        .num => |n| @intCast(n.sigDigitCount()),
                    };
                    try self.push(.{ .num = BigDec.fromInt(self.allocator, count) catch return error.OutOfMemory });
                },
                'X' => {
                    var v = try self.pop();
                    defer v.deinit(self.allocator);
                    const sc: i64 = switch (v) {
                        .str => 0,
                        .num => |n| @intCast(n.fracDigitCount()),
                    };
                    try self.push(.{ .num = BigDec.fromInt(self.allocator, sc) catch return error.OutOfMemory });
                },
                '|' => {
                    if (self.stack.items.len < 3) return error.StackEmpty;
                    var modulus = try self.popNum();
                    defer modulus.deinit();
                    var exponent = try self.popNum();
                    defer exponent.deinit();
                    var base = try self.popNum();
                    defer base.deinit();
                    var r = BigDec.init(self.allocator);
                    errdefer r.deinit();
                    r.modexp(base, exponent, modulus) catch |e| switch (e) {
                        error.DivisionByZero => return error.DivisionByZero,
                        error.NonIntegerExponent => return error.NonIntegerExponent,
                        else => return error.OutOfMemory,
                    };
                    try self.push(.{ .num = r });
                },
                ':' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    var idx_n = try self.popNum();
                    defer idx_n.deinit();
                    const index = try asIndex(idx_n);
                    const value = try self.pop();
                    try self.storeArray(reg, index, value);
                },
                ';' => {
                    if (i >= line.len) return error.UnexpectedToken;
                    const reg = line[i];
                    i += 1;
                    var idx_n = try self.popNum();
                    defer idx_n.deinit();
                    const index = try asIndex(idx_n);
                    var key: [1]u8 = .{reg};
                    if (self.state.arrays.get(&key)) |slot| {
                        if (index < slot.len) {
                            try self.push(try slot[index].clone(self.allocator));
                            continue;
                        }
                    }
                    try self.push(.{ .num = BigDec.fromInt(self.allocator, 0) catch return error.OutOfMemory });
                },
                '#' => break, // comment to end of line
                else => return error.UnexpectedToken,
            }
        }
        if (self.unwind > 0) return false;
        try stdout.flush();
        return true;
    }

    fn printValue(self: *Self, v: Value, stdout: *std.Io.Writer) !void {
        switch (v) {
            .str => |s| try stdout.writeAll(s),
            .num => |n| try n.format(stdout, self.state.obase, 1 << 30),
        }
    }
};

test "dc arithmetic and stack ops" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    var dc = Dc.init(&state);
    defer dc.deinit();

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    _ = try dc.processLine("3 4 + p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "7"));
    w = .fixed(&buf);

    _ = try dc.processLine("2 10 ^ p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "1024"));
    w = .fixed(&buf);

    // registers shared with variables
    _ = try dc.processLine("42 sa", &w);
    _ = try dc.processLine("la p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "42"));
    w = .fixed(&buf);

    // strings
    _ = try dc.processLine("[hello] p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "hello"));
}

test "dc macros S/L compares q" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    var dc = Dc.init(&state);
    defer dc.deinit();

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    _ = try dc.processLine("[2 3 +]x p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "5"));
    w = .fixed(&buf);

    _ = try dc.processLine("1 sa 2 Sa la p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "2"));
    w = .fixed(&buf);

    _ = try dc.processLine("La p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "2"));
    w = .fixed(&buf);

    _ = try dc.processLine("la p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "1"));
    w = .fixed(&buf);

    _ = try dc.processLine("[1p]sm 3 4 >m", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "1"));
    w = .fixed(&buf);

    _ = try dc.processLine("[9p]sm 4 3 >m", &w);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
    w = .fixed(&buf);

    _ = try dc.processLine("[1p]sm 3 3 =m", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "1"));
    w = .fixed(&buf);

    _ = try dc.processLine("[1p]sm 3 4 !>m", &w);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);

    const keep = try dc.processLine("[q]x 99p", &w);
    try std.testing.expect(!keep);
}

test "dc Z X modexp arrays" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    var dc = Dc.init(&state);
    defer dc.deinit();

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    _ = try dc.processLine("c 123 Z p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "3"));
    w = .fixed(&buf);

    _ = try dc.processLine("c 0 Z p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "1"));
    w = .fixed(&buf);

    _ = try dc.processLine("c [hello] Z p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "5"));
    w = .fixed(&buf);

    _ = try dc.processLine("c 1.25 X p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "2"));
    w = .fixed(&buf);

    _ = try dc.processLine("c [hello] X p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "0"));
    w = .fixed(&buf);

    _ = try dc.processLine("c 100 8 7 | p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "4"));
    w = .fixed(&buf);

    _ = try dc.processLine("c 5 2 :a 2 ;a p", &w);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "5"));
}
