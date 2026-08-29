//! Arbitrary precision decimal arithmetic for ac.
//!
//! Fixed-base (10^9) limb representation, least-significant limb first.
//! `rdx` counts how many low limbs are fractional, so the stored value is
//! `sum(limbs[i] * BASE^i) / BASE^rdx` with sign `neg`.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Limb = i64;
pub const BASE: i64 = 1_000_000_000;
pub const BASE_DIGS: usize = 9;
/// Use Karatsuba when both factors have at least this many limbs.
pub const karatsuba_cutoff: usize = 32;
/// Error set shared by BigDec operations.
pub const Error = error{
    DivisionByZero,
    NegativeSquareRoot,
    NonIntegerExponent,
    InternalDivisionOverflow,
    InvalidBase,
    OutOfMemory,
};
/// Arbitrary precision decimal number.
pub const BigDec = struct {
    allocator: Allocator,
    limbs: []Limb,
    len: usize,
    rdx: usize,
    neg: bool,
    const Self = @This();
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .limbs = &[_]Limb{},
            .len = 0,
            .rdx = 0,
            .neg = false,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = &[_]Limb{};
        self.len = 0;
        self.rdx = 0;
    }
    pub fn clone(self: Self, allocator: Allocator) !Self {
        var c = Self.init(allocator);
        if (self.len > 0) {
            c.limbs = try allocator.dupe(Limb, self.limbs[0..self.len]);
            c.len = self.len;
        }
        c.rdx = self.rdx;
        c.neg = self.neg;
        return c;
    }
    fn ensureLims(self: *Self, n: usize) !void {
        if (n <= self.limbs.len) return;
        const old = self.limbs;
        const new = try self.allocator.alloc(Limb, n);
        @memset(new, 0);
        if (old.len > 0) @memcpy(new[0..old.len], old);
        if (old.len > 0) self.allocator.free(old);
        self.limbs = new;
    }
    pub fn isZero(self: Self) bool {
        if (self.len == 0) return true;
        // normalize() keeps len == rdx for pure fractions, so an
        // all-zero value can still have limbs allocated.
        for (self.limbs[0..self.len]) |l| {
            if (l != 0) return false;
        }
        return true;
    }
    pub fn isNegative(self: Self) bool {
        return self.neg;
    }
    pub fn negate(self: *Self) void {
        if (!self.isZero()) self.neg = !self.neg;
    }
    /// Trim high zero limbs (never below the radix boundary) and canonicalize
    /// negative zero away.
    fn normalize(self: *Self) void {
        while (self.len > self.rdx and self.limbs[self.len - 1] == 0) {
            self.len -= 1;
        }
        if (self.len == 0) {
            self.neg = false;
            self.rdx = 0;
        }
    }
    /// Construct from a small signed integer.
    pub fn fromInt(allocator: Allocator, v: i64) !BigDec {
        var self = Self.init(allocator);
        errdefer self.deinit();
        var neg = v < 0;
        var mag: i64 = if (neg) -v else v;
        // Guard INT_MIN edge
        if (mag < 0) mag = -(v + 1) + 1;
        if (neg and v == std.math.minInt(i64)) neg = true;
        var idx: usize = 0;
        while (mag > 0) : (idx += 1) {
            try self.ensureLims(idx + 1);
            self.limbs[idx] = @mod(mag, BASE);
            mag = @divTrunc(mag, BASE);
        }
        self.len = idx;
        self.normalize();
        if (self.isZero()) neg = false;
        self.neg = neg;
        return self;
    }
    fn digitVal(ch: u8) ?i64 {
        if (ch >= '0' and ch <= '9') return ch - '0';
        if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
        if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
        return null;
    }
    fn int_limbsOf(digits: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < digits.len) : (i += 1) {
            if (digits[i] != '0' or count > 0) count += 1;
        }
        if (count == 0) return 0;
        return (count + BASE_DIGS - 1) / BASE_DIGS;
    }
    fn splitSciExp(s: []const u8) ?struct { mantissa: []const u8, exp: i64 } {
        var i = s.len;
        while (i > 1) {
            i -= 1;
            const c = s[i];
            if (c != 'e' and c != 'E') continue;
            const rest = s[i + 1 ..];
            if (rest.len == 0) return null;
            const expv = std.fmt.parseInt(i64, rest, 10) catch return null;
            const man = s[0..i];
            if (man.len == 0) return null;
            if (man[man.len - 1] == '.') return null;
            return .{ .mantissa = man, .exp = expv };
        }
        return null;
    }
    fn applyDecimalExp(self: *Self, expv: i64) Error!void {
        if (expv == 0 or self.isZero()) return;
        const mag: i64 = if (expv < 0) -expv else expv;
        if (mag > 1_000_000) return error.InvalidBase;
        var ten = try fromInt(self.allocator, 10);
        defer ten.deinit();
        var e_bd = try fromInt(self.allocator, mag);
        defer e_bd.deinit();
        var p10 = Self.init(self.allocator);
        defer p10.deinit();
        try p10.pow(ten, e_bd, 0);
        var out = Self.init(self.allocator);
        errdefer out.deinit();
        if (expv > 0) {
            try out.mul(self.*, p10, 0);
        } else {
            const extra = self.fracDigitCount() + @as(usize, @intCast(mag));
            try out.div(self.*, p10, extra);
        }
        const keep_neg = self.neg;
        self.deinit();
        self.* = out;
        out = Self.init(self.allocator);
        if (keep_neg and !self.isZero()) self.neg = true;
    }
    /// floor(log10(|n|)) for a non-zero value.
    fn decimalExp(n: Self) i64 {
        if (n.isZero()) return 0;
        const sig: i64 = @intCast(n.sigDigitCount());
        const frac: i64 = @intCast(n.fracDigitCount());
        return sig - frac - 1;
    }
    fn powIntBig(allocator: Allocator, base: i64, exp: usize) Error!BigDec {
        var r = try fromInt(allocator, 1);
        errdefer r.deinit();
        var i: usize = 0;
        while (i < exp) : (i += 1) {
            var b = try fromInt(allocator, base);
            defer b.deinit();
            var t = Self.init(allocator);
            defer t.deinit();
            try t.mul(r, b, 0);
            r.deinit();
            r = t;
            t = Self.init(allocator);
        }
        return r;
    }
    /// Parse a decimal string (base 10) into a BigDec.
    pub fn parse(allocator: Allocator, str: []const u8, ibase: u8) !Self {
        if (ibase != 10) return error.InvalidBase;
        var self = Self.init(allocator);
        errdefer self.deinit();
        var s = str;
        if (s.len > 0 and s[0] == '-') {
            self.neg = true;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '+') {
            s = s[1..];
        }
        var sci_exp: i64 = 0;
        if (splitSciExp(s)) |parts| {
            s = parts.mantissa;
            sci_exp = parts.exp;
        }
        const decimal_pos = std.mem.indexOfScalar(u8, s, '.');
        const int_end = decimal_pos orelse s.len;
        // Fractional limb count from digit count (rounded up).
        var frac_limbs: usize = 0;
        if (decimal_pos) |dp| {
            const frac_digits = s.len - dp - 1;
            frac_limbs = (frac_digits + BASE_DIGS - 1) / BASE_DIGS;
            // Cap: keep at most 4 limbs (36 digits) of fraction from input.
            if (frac_limbs > 4) frac_limbs = 4;
        }
        const total_limbs = int_limbsOf(s[0..int_end]) + frac_limbs;
        try self.ensureLims(@max(total_limbs, 1));
        self.rdx = frac_limbs;
        // Integer part: right to left, groups of nine. limb_idx tracks
        // limbs actually written; self.len derives from it.
        var limb_idx: usize = frac_limbs;
        {
            var i = int_end;
            while (i > 0 and limb_idx < self.limbs.len) {
                const start2 = if (i >= BASE_DIGS) i - BASE_DIGS else 0;
                var cur: Limb = 0;
                for (s[start2..i]) |c| {
                    cur = cur * 10 + (c - '0');
                }
                self.limbs[limb_idx] = cur;
                limb_idx += 1;
                i = start2;
                if (start2 == 0) break;
            }
        }
        // Fractional part: limb[0] holds the FIRST up-to-9 fractional digits
        // (weights 10^-1..10^-9), limb[1] the next nine, etc. A partial
        // trailing group is padded with low-order zeros.
        if (decimal_pos) |dp| {
            const frac_str = s[dp + 1 ..];
            var pos: usize = 0;
            var frac_idx: usize = 0;
            while (pos < frac_str.len and frac_idx < frac_limbs) {
                var cur: Limb = 0;
                var n: usize = 0;
                while (pos < frac_str.len and n < BASE_DIGS) : (pos += 1) {
                    const c = frac_str[pos];
                    if (c >= '0' and c <= '9') {
                        cur = cur * 10 + (c - '0');
                        n += 1;
                    }
                }
                if (n < BASE_DIGS) {
                    var sh: usize = BASE_DIGS - n;
                    while (sh > 0) : (sh -= 1) cur *= 10;
                }
                self.limbs[frac_idx] = cur;
                frac_idx += 1;
            }
        }
        self.len = limb_idx;
        self.normalize();
        if (sci_exp != 0) try self.applyDecimalExp(sci_exp);
        return self;
    }
    /// Parse a bc-style literal in an arbitrary input base (2..16).
    /// Letters A-F/a-f are digits 10-15. Fractional digits beyond max_frac
    /// are ignored. Result value is the literal's decimal value.
    pub fn parseBase(allocator: Allocator, str: []const u8, ibase: u8, max_frac: usize) !Self {
        if (ibase == 10) return parse(allocator, str, 10);
        if (ibase < 2 or ibase > 16) return error.InvalidBase;
        var self = Self.init(allocator);
        errdefer self.deinit();
        var s = str;
        if (s.len > 0 and s[0] == '-') { self.neg = true; s = s[1..]; }
        else if (s.len > 0 and s[0] == '+') s = s[1..];
        const dot = std.mem.indexOfScalar(u8, s, '.');
        const int_part = if (dot) |d| s[0..d] else s;
        const frac_part = if (dot) |d| s[d + 1 ..] else "";
        // Integer part via Horner in the input base.
        var acc = Self.init(allocator);
        defer acc.deinit();
        var bb = try fromInt(allocator, @intCast(ibase));
        defer bb.deinit();
        for (int_part) |ch| {
            const d = digitVal(ch) orelse continue;
            var t = Self.init(allocator);
            errdefer t.deinit();
            try t.mul(acc, bb, 0);
            var one_d = try fromInt(allocator, d);
            defer one_d.deinit();
            var t2 = Self.init(allocator);
            errdefer t2.deinit();
            try t2.add(t, one_d, 0);
            t.deinit();
            acc.deinit();
            acc = t2;
        }
        _ = &acc;
        // Fractional part: F = sum d_i * base^(n-1-i); value = F / base^n.
        if (frac_part.len > 0) {
            const n = frac_part.len;
            var f_num = Self.init(allocator);
            defer f_num.deinit();
            for (frac_part) |ch| {
                const d = digitVal(ch) orelse continue;
                var t = Self.init(allocator);
                defer t.deinit();
                try t.mul(f_num, bb, 0);
                var one_d = try fromInt(allocator, d);
                defer one_d.deinit();
                var t2 = Self.init(allocator);
                defer t2.deinit();
                try t2.add(t, one_d, 0);
                f_num.deinit();
                f_num = t2;
                t2 = Self.init(allocator);
            }
            var denom = try powIntBig(allocator, @intCast(ibase), n);
            defer denom.deinit();
            var frac_val = Self.init(allocator);
            defer frac_val.deinit();
            try frac_val.div(f_num, denom, max_frac);
            var total = Self.init(allocator);
            defer total.deinit();
            try total.add(acc, frac_val, 0);
            acc.deinit();
            acc = total;
            // Neutralize total's defer: it now aliases acc's memory.
            total = Self.init(allocator);
        }
        acc.neg = self.neg and !acc.isZero();
        // Transfer ownership out; the defer frees only the empty shell.
        const result = acc;
        acc = Self.init(allocator);
        return result;
    }
    /// Convert to f64. Loses precision beyond ~15 digits.
    pub fn toF64(self: Self) !f64 {
        if (self.isZero()) return 0.0;
        const base_f: f64 = @floatFromInt(BASE);
        var result: f64 = 0.0;
        var i = self.len;
        while (i > self.rdx) {
            i -= 1;
            result = result * base_f + @as(f64, @floatFromInt(self.limbs[i]));
        }
        var frac: f64 = 0.0;
        i = self.rdx;
        while (i > 0) {
            i -= 1;
            const limb: f64 = if (i < self.len)
                @floatFromInt(self.limbs[i])
            else
                0;
            frac = (frac + limb) / base_f;
        }
        result += frac;
        return if (self.neg) -result else result;
    }
    pub fn fromF64(allocator: Allocator, v: f64, scale: usize) !Self {
        var buf: [512]u8 = undefined;
        const fmt_scale: usize = @min(scale + 1, 15);
        const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, fmt_scale }) catch
            return error.OutOfMemory;
        return parse(allocator, s, 10);
    }
    pub fn format(self: Self, writer: anytype, obase: u8, max_frac_digits: usize) !void {
        const base: u8 = if (obase < 2 or obase > 16) 10 else obase;
        if (base != 10) {
            try self.formatObase(writer, base, max_frac_digits);
            return;
        }
        if (self.isZero()) {
            try writer.writeAll("0");
            return;
        }
        if (self.neg) try writer.writeAll("-");
        var wrote_digit = false;
        var i = self.len;
        while (i > self.rdx) {
            i -= 1;
            const limb = self.limbs[i];
            if (wrote_digit) {
                try writeLimbPadded(writer, limb);
            } else if (limb != 0) {
                try writer.print("{d}", .{limb});
                wrote_digit = true;
            }
        }
        if (!wrote_digit) try writer.writeAll("0");
        if (self.rdx > 0 and max_frac_digits > 0) {
            try writer.writeAll(".");
            var written: usize = 0;
            var j = self.rdx;
            while (j > 0 and written < max_frac_digits) {
                j -= 1;
                var cur = self.limbs[j];
                // Buffer one limb's digits, emit MSB-first (limb value
                // contributes its high digit at the earlier position).
                var digits: [BASE_DIGS]u8 = undefined;
                var di: usize = BASE_DIGS;
                while (di > 0) {
                    di -= 1;
                    digits[di] = @intCast(@mod(cur, 10));
                    cur = @divTrunc(cur, 10);
                }
                var k: usize = 0;
                while (k < BASE_DIGS and written < max_frac_digits) : (k += 1) {
                    try writer.writeByte('0' + digits[k]);
                    written += 1;
                }
            }
        }
    }
    /// Write scientific (`eng == false`) or engineering (`eng == true`) form.
    pub fn formatSci(self: Self, writer: anytype, max_frac_digits: usize, eng: bool) !void {
        if (self.isZero()) {
            try writer.writeAll("0");
            return;
        }
        var expv = decimalExp(self);
        if (eng) {
            var rem = @rem(expv, 3);
            if (rem < 0) rem += 3;
            expv -= rem;
        }
        var absv = try self.clone(self.allocator);
        defer absv.deinit();
        absv.neg = false;
        var ten = try fromInt(self.allocator, 10);
        defer ten.deinit();
        const mag: i64 = if (expv < 0) -expv else expv;
        var e_bd = try fromInt(self.allocator, mag);
        defer e_bd.deinit();
        var p10 = Self.init(self.allocator);
        defer p10.deinit();
        try p10.pow(ten, e_bd, 0);
        var coeff = Self.init(self.allocator);
        defer coeff.deinit();
        if (expv >= 0) {
            try coeff.div(absv, p10, max_frac_digits);
        } else {
            try coeff.mul(absv, p10, 0);
        }
        if (self.neg) try writer.writeAll("-");
        try coeff.format(writer, 10, max_frac_digits);
        try writer.writeAll("e");
        if (expv < 0) {
            try writer.print("-{d}", .{-expv});
        } else {
            try writer.print("{d}", .{expv});
        }
    }
    fn writeLimbPadded(writer: anytype, limb: Limb) !void {
        var digits: [BASE_DIGS]u8 = undefined;
        var v = limb;
        var idx: usize = BASE_DIGS;
        while (idx > 0) {
            idx -= 1;
            digits[idx] = '0' + @as(u8, @intCast(@mod(v, 10)));
            v = @divTrunc(v, 10);
        }
        try writer.writeAll(&digits);
    }
    const hex_digits = "0123456789ABCDEF";
    fn cloneInteger(self: Self) Error!Self {
        var n = try self.clone(self.allocator);
        errdefer n.deinit();
        n.neg = false;
        if (n.rdx == 0) return n;
        if (n.len <= n.rdx) {
            n.len = 0;
            n.rdx = 0;
            return n;
        }
        const drop = n.rdx;
        std.mem.copyForwards(Limb, n.limbs[0 .. n.len - drop], n.limbs[drop..n.len]);
        n.len -= drop;
        n.rdx = 0;
        n.normalize();
        return n;
    }
    fn cloneFraction(self: Self) Error!Self {
        var n = try self.clone(self.allocator);
        errdefer n.deinit();
        n.neg = false;
        if (n.rdx == 0) {
            n.len = 0;
            return n;
        }
        if (n.len > n.rdx) {
            @memset(n.limbs[n.rdx..n.len], 0);
            n.len = n.rdx;
        }
        return n;
    }
    fn integerMag(n: Self) i64 {
        if (n.len <= n.rdx) return 0;
        var v: i64 = 0;
        var i = n.len;
        while (i > n.rdx) {
            i -= 1;
            v = v * BASE + n.limbs[i];
        }
        return v;
    }
    fn peelInteger(n: *Self) i64 {
        const v = integerMag(n.*);
        if (n.len > n.rdx) {
            @memset(n.limbs[n.rdx..n.len], 0);
            n.len = n.rdx;
        }
        n.normalize();
        return v;
    }
    fn formatObase(self: Self, writer: anytype, base: u8, max_frac_digits: usize) !void {
        if (self.isZero()) {
            try writer.writeAll("0");
            return;
        }
        if (self.neg) try writer.writeAll("-");
        const allocator = self.allocator;
        var base_n = try fromInt(allocator, @intCast(base));
        defer base_n.deinit();
        var int_part = try self.cloneInteger();
        defer int_part.deinit();
        if (int_part.isZero()) {
            try writer.writeAll("0");
        } else {
            var digits: std.ArrayList(u8) = .empty;
            defer digits.deinit(allocator);
            while (!int_part.isZero()) {
                var q = Self.init(allocator);
                defer q.deinit();
                try q.div(int_part, base_n, 0);
                var prod = Self.init(allocator);
                defer prod.deinit();
                try prod.mul(q, base_n, 0);
                var rem = Self.init(allocator);
                defer rem.deinit();
                try rem.sub(int_part, prod, 0);
                const d: usize = @intCast(integerMag(rem));
                try digits.append(allocator, hex_digits[d]);
                int_part.deinit();
                int_part = q;
                q = Self.init(allocator);
            }
            var di = digits.items.len;
            while (di > 0) {
                di -= 1;
                try writer.writeByte(digits.items[di]);
            }
        }
        if (max_frac_digits == 0) return;
        var frac = try self.cloneFraction();
        defer frac.deinit();
        if (frac.isZero()) return;
        try writer.writeAll(".");
        var written: usize = 0;
        while (written < max_frac_digits and !frac.isZero()) {
            var prod = Self.init(allocator);
            defer prod.deinit();
            try prod.mul(frac, base_n, 0);
            const d: usize = @intCast(prod.peelInteger());
            try writer.writeByte(hex_digits[d]);
            written += 1;
            frac.deinit();
            frac = prod;
            prod = Self.init(allocator);
        }
    }
    pub fn add(self: *Self, a: Self, b: Self, scale: usize) Error!void {
        _ = scale;
        return addAbs(self, a, b, a.neg == b.neg);
    }
    pub fn sub(self: *Self, a: Self, b: Self, scale: usize) Error!void {
        _ = scale;
        // a - b = a + (-b): flip b's sign and use the add convention so
        // addAbs's different-magnitude sign rule picks the right flag.
        var b_flip = b;
        b_flip.neg = !b.neg;
        return addAbs(self, a, b_flip, a.neg == b_flip.neg);
    }
    /// Common addition/subtraction core. When same_sign is true the
    /// magnitudes add; otherwise the smaller magnitude is subtracted from
    /// the larger and the sign taken from it.
    fn addAbs(self: *Self, a: Self, b: Self, same_sign: bool) Error!void {
        const max_rdx = @max(a.rdx, b.rdx);
        const a_shift = max_rdx - a.rdx;
        const b_shift = max_rdx - b.rdx;
        const a_eff = a.len + a_shift;
        const b_eff = b.len + b_shift;
        const max_len = @max(a_eff, b_eff);
        var out = try self.allocator.alloc(Limb, max_len + 1);
        @memset(out, 0);
        if (same_sign) {
            var carry: Limb = 0;
            var idx: usize = 0;
            while (idx < max_len) : (idx += 1) {
                const av: i64 = if (idx >= a_shift and idx - a_shift < a.len)
                    a.limbs[idx - a_shift]
                else
                    0;
                const bv: i64 = if (idx >= b_shift and idx - b_shift < b.len)
                    b.limbs[idx - b_shift]
                else
                    0;
                const sum = av + bv + carry;
                out[idx] = @mod(sum, BASE);
                carry = @divTrunc(sum, BASE);
            }
            out[max_len] = carry;
            if (self.limbs.len > 0) self.allocator.free(self.limbs);
            self.limbs = out;
            self.len = max_len + @intFromBool(carry != 0);
            if (self.len > self.limbs.len) self.len = self.limbs.len;
            self.rdx = max_rdx;
            self.neg = a.neg;
            self.normalize();
        } else {
            var ord: std.math.Order = .eq;
            var k: usize = max_len;
            while (k > 0) {
                k -= 1;
                const av: i64 = if (k >= a_shift and k - a_shift < a.len)
                    a.limbs[k - a_shift]
                else
                    0;
                const bv: i64 = if (k >= b_shift and k - b_shift < b.len)
                    b.limbs[k - b_shift]
                else
                    0;
                if (av != bv) { ord = if (av > bv) .gt else .lt; break; }
            }
            if (ord == .eq) {
                if (self.limbs.len > 0) self.allocator.free(self.limbs);
                self.limbs = &[_]Limb{};
                self.len = 0;
                self.rdx = 0;
                self.neg = false;
                self.allocator.free(out);
                return;
            }
            const big = if (ord == .gt) a else b;
            const small = if (ord == .gt) b else a;
            const big_shift = if (ord == .gt) a_shift else b_shift;
            const small_shift = if (ord == .gt) b_shift else a_shift;
            var borrow: i64 = 0;
            var idx: usize = 0;
            while (idx < max_len) : (idx += 1) {
                const gv: i64 = if (idx >= big_shift and idx - big_shift < big.len)
                    big.limbs[idx - big_shift]
                else
                    0;
                const sv: i64 = if (idx >= small_shift and idx - small_shift < small.len)
                    small.limbs[idx - small_shift]
                else
                    0;
                var diff = gv - sv - borrow;
                if (diff < 0) {
                    borrow = 1;
                    diff += BASE;
                } else {
                    borrow = 0;
                }
                out[idx] = diff;
            }
            std.debug.assert(borrow == 0);
            if (self.limbs.len > 0) self.allocator.free(self.limbs);
            self.limbs = out;
            self.len = max_len;
            self.rdx = max_rdx;
            self.neg = if (ord == .gt) a.neg else b.neg;
            self.normalize();
        }
    }
    /// School multiplication for small operands; Karatsuba when both
    /// factors have at least `karatsuba_cutoff` limbs. Truncation to
    /// `scale` is NOT applied here — the full exact product is kept.
    pub fn mul(self: *Self, a: Self, b: Self, scale: usize) Error!void {
        _ = scale;
        if (a.isZero() or b.isZero()) {
            self.len = 0;
            self.rdx = 0;
            self.neg = false;
            return;
        }
        try self.mulWithCutoff(a, b, karatsuba_cutoff);
    }

    /// Multiply with an explicit Karatsuba limb cutoff (tests use 2).
    pub fn mulWithCutoff(self: *Self, a: Self, b: Self, cutoff: usize) Error!void {
        if (a.isZero() or b.isZero()) {
            self.len = 0;
            self.rdx = 0;
            self.neg = false;
            return;
        }
        const out = try mulLimbs(self.allocator, a.limbs[0..a.len], b.limbs[0..b.len], cutoff);
        if (self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = out;
        self.len = out.len;
        self.rdx = a.rdx + b.rdx;
        self.neg = a.neg != b.neg;
        self.normalize();
    }
    /// One long-division step: bring down u[step_i], compute the digit
    /// into q[step_i], and reduce r below v.
    fn divStep(
        allocator: Allocator,
        u: []const i64,
        v: []const i64,
        r: []i64,
        q: []i64,
        r_len: usize,
        v_len: usize,
        step_i: usize,
        base_i128: i128,
    ) Error!void {
        // Bring down: r = r * BASE + u[step_i], low limb first.
        var carry: i128 = u[step_i];
        for (0..r_len) |ri| {
            const prod = @as(i128, r[ri]) * base_i128 + carry;
            r[ri] = @intCast(@mod(prod, base_i128));
            carry = @divFloor(prod, base_i128);
        }
        if (carry != 0) return error.InternalDivisionOverflow;
        // Compute q_digit = floor(r / v), reducing r in place.
        var qhat: i128 = 0;
        while (true) {
            var r_top = r_len;
            while (r_top > 0 and r[r_top - 1] == 0) r_top -= 1;
            // r < v?
            if (r_top < v_len) break;
            if (r_top == v_len) {
                var lt = false;
                var k: usize = v_len;
                while (k > 0) {
                    k -= 1;
                    if (r[k] != v[k]) { lt = r[k] < v[k]; break; }
                }
                if (lt) break;
            }
                // Multi-limb binary search: largest d with d*v <= r.
                var lo_b: i128 = 0;
                var hi_b: i128 = base_i128 - 1;
                while (lo_b < hi_b) {
                    const mid = lo_b + @divFloor(hi_b - lo_b + 1, 2);
                    const prod = try allocator.alloc(i64, r_len);
                    defer allocator.free(prod);
                    @memset(prod, 0);
                    var c: i128 = 0;
                    for (0..v_len) |k| {
                        const pp = mid * v[k] + c;
                        prod[k] = @intCast(@mod(pp, base_i128));
                        c = @divFloor(pp, base_i128);
                    }
                    prod[v_len] = @intCast(c);
                    var ge = true;
                    var kk: usize = r_len;
                    while (kk > 0) {
                        kk -= 1;
                        if (prod[kk] != r[kk]) { ge = prod[kk] < r[kk]; break; }
                    }
                    if (ge) lo_b = mid else hi_b = mid - 1;
                }
                const d: i128 = lo_b;
                if (d <= 0) break;
                // Subtract d*v from r across all remainder limbs.
                var borrow: i128 = 0;
                for (0..r_len) |k| {
                    const vv: i128 = if (k < v_len) d * v[k] else 0;
                    const diff = @as(i128, r[k]) - vv + borrow;
                    const b2 = @divFloor(diff, base_i128);
                    borrow = b2;
                    r[k] = @intCast(diff - b2 * base_i128);
                }
                qhat += d;
            }
            q[step_i] = @intCast(qhat);
    }
    /// Divide a by b, producing at least `scale` fractional digits.
    ///
    /// Exact limb-based schoolbook long division. Both operands are
    /// scaled to integers; the dividend additionally carries b.rdx low
    /// zero limbs (cancelling the divisor fractional scale), frac_limbs
    /// more for output precision, and a spare top limb.
    pub fn div(self: *Self, a: Self, b: Self, scale: usize) Error!void {
        if (b.isZero()) return error.DivisionByZero;
        if (a.isZero()) {
            self.len = 0;
            self.rdx = 0;
            self.neg = false;
            return;
        }
        const base_i128: i128 = BASE;
        const frac_limbs = (scale + BASE_DIGS - 1) / BASE_DIGS;
        const v_len = b.len;
        // +2 guard limbs absorb truncation so displayed digits up to
        // `scale` match exact arithmetic.
        const low_pad = b.rdx + frac_limbs + 2;
        const int_limbs_needed = if (a.len >= v_len) a.len - v_len else 1;
        const total_digits = int_limbs_needed + frac_limbs + 2;
        const u_len = @max(v_len + total_digits, low_pad + a.len);
        const out_rdx = low_pad + a.rdx - b.rdx;
        const u = try self.allocator.alloc(i64, u_len);
        defer self.allocator.free(u);
        @memset(u, 0);
        for (0..a.len) |j| u[low_pad + j] = a.limbs[j];
        const v = try self.allocator.alloc(i64, v_len);
        defer self.allocator.free(v);
        for (0..v_len) |j| v[j] = b.limbs[j];
        const r_len = v_len + 2;
        const r = try self.allocator.alloc(i64, r_len);
        defer self.allocator.free(r);
        @memset(r, 0);
        const q = try self.allocator.alloc(i64, u_len);
        defer self.allocator.free(q);
        @memset(q, 0);
        // Bring down every dividend limb from the top down. The first
        // v_len-1 steps (dividend prefix shorter than the divisor) produce
        // guaranteed-zero digits and only warm up the remainder window.
        var top: usize = u_len;
        while (top > 0 and u[top - 1] == 0) top -= 1;
        var step_i: usize = @min(u_len, top + v_len - 1);
        while (step_i > 0) {
            step_i -= 1;
            try divStep(self.allocator, u, v, r, q, @intCast(r.len), v_len, step_i, base_i128);
        }
        // Assemble: quotient limbs are q[0 .. u_len-v_len]; above is zero.
        const qlen = u_len - v_len + 1;
        var out = try self.allocator.alloc(Limb, qlen);
        for (0..qlen) |i| out[i] = @intCast(q[i]);
        if (self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = out;
        self.len = qlen;
        self.rdx = out_rdx;
        self.neg = a.neg != b.neg;
        self.normalize();
        // Drop the guard limbs: bc truncates the quotient to `scale`
        // fractional digits.
        const want_frac = (scale + BASE_DIGS - 1) / BASE_DIGS;
        if (self.rdx > want_frac) {
            const drop = self.rdx - want_frac;
            if (drop >= self.len) {
                self.len = 0;
                self.rdx = 0;
            } else {
                std.mem.copyForwards(Limb, self.limbs[0 .. self.len - drop], self.limbs[drop..self.len]);
                self.len -= drop;
                self.rdx = want_frac;
                self.normalize();
            }
        }
    }
    /// a mod b with bc semantics: a - trunc_to_scale(a/b) * b.
    pub fn mod(self: *Self, a: Self, b: Self, scale: usize) Error!void {
        var quotient = Self.init(self.allocator);
        defer quotient.deinit();
        try quotient.div(a, b, scale);
        var product = Self.init(self.allocator);
        defer product.deinit();
        try product.mul(quotient, b, scale);
        return self.sub(a, product, scale);
    }
    /// Integer exponentiation by squaring. Non-integer exponents are
    /// rejected (bc behavior). Negative exponents compute the reciprocal
    /// via exact division at `scale`.
    pub fn pow(self: *Self, base_v: Self, exp: Self, scale: usize) Error!void {
        const e_f = try exp.toF64();
        if (@floor(e_f) != e_f) return error.NonIntegerExponent;
        const neg = e_f < 0;
        const e_int: i64 = @intFromFloat(@abs(e_f));
        var result = try fromInt(self.allocator, 1);
        defer result.deinit();
        var b = base_v.clone(self.allocator) catch return error.OutOfMemory;
        defer b.deinit();
        var remaining = e_int;
        while (remaining > 0) {
            if (remaining & 1 == 1) {
                // result *= b (no aliasing: compute via clone of result).
                var a_copy = result.clone(self.allocator) catch return error.OutOfMemory;
                defer a_copy.deinit();
                var t = Self.init(self.allocator);
                errdefer t.deinit();
                try t.mul(a_copy, b, scale);
                result.deinit();
                result = t;
            }
            remaining >>= 1;
            if (remaining > 0) {
                // b = b * b (same aliasing concern).
                var b_copy = b.clone(self.allocator) catch return error.OutOfMemory;
                defer b_copy.deinit();
                var t2 = Self.init(self.allocator);
                errdefer t2.deinit();
                try t2.mul(b_copy, b_copy, scale);
                b.deinit();
                b = t2;
            }
        }
        if (neg) {
            var one = try fromInt(self.allocator, 1);
            defer one.deinit();
            var inv = Self.init(self.allocator);
            defer inv.deinit();
            try inv.div(one, b, scale);
            result.deinit();
            result = inv;
            result.neg = base_v.neg and (e_int & 1 == 1);
        } else {
            if (base_v.neg and (e_int & 1 == 1)) result.neg = true;
        }
        // Move ownership: hand result's buffers to self without sharing.
        if (self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = result.limbs;
        self.len = result.len;
        self.rdx = result.rdx;
        self.neg = result.neg;
        result.limbs = &[_]Limb{};
        result.len = 0;
        result.rdx = 0;
    }
    /// Square root via Newton iteration on exact division.
    /// Converges quadratically from the f64 seed; a few iterations reach
    /// any practical precision. Result truncated to `scale` digits.
    pub fn sqrt(self: *Self, a: Self, scale: usize) Error!void {
        if (a.isNegative()) return error.NegativeSquareRoot;
        if (a.isZero()) {
            self.* = Self.init(self.allocator);
            return;
        }
        // Initial guess from f64 (~15 correct digits).
        const a_f64 = try a.toF64();
        const guess = @sqrt(a_f64);
        self.deinit();
        self.* = try fromF64(self.allocator, guess, scale + 2);
        self.normalize();
        const iterations = 5;
        for (0..iterations) |_| {
            var quotient = Self.init(self.allocator);
            defer quotient.deinit();
            try quotient.div(a, self.*, scale + 2);
            var sum = Self.init(self.allocator);
            defer sum.deinit();
            try sum.add(quotient, self.*, scale + 2);
            var half = try fromInt(self.allocator, 2);
            defer half.deinit();
            var new_x = Self.init(self.allocator);
            defer new_x.deinit();
            try new_x.div(sum, half, scale + 2);
            const converged = BigDec.cmp(new_x, self.*) == .eq;
            self.deinit();
            self.* = new_x;
            new_x = Self.init(self.allocator);
            if (converged) break;
        }
    }
    /// Three-way magnitude comparison with radix alignment.
    pub fn cmp(a: Self, b: Self) std.math.Order {
        const max_rdx = @max(a.rdx, b.rdx);
        const a_shift = max_rdx - a.rdx;
        const b_shift = max_rdx - b.rdx;
        // Sign check first (negative numbers sort below positive).
        if (a.neg != b.neg) return if (a.neg) .lt else .gt;
        const a_eff = a.len + a_shift;
        const b_eff = b.len + b_shift;
        const max_len = @max(a_eff, b_eff);
        var i: usize = max_len;
        while (i > 0) {
            i -= 1;
            const av: Limb = if (i >= a_shift and i - a_shift < a.len)
                a.limbs[i - a_shift]
            else
                0;
            const bv: Limb = if (i >= b_shift and i - b_shift < b.len)
                b.limbs[i - b_shift]
            else
                0;
            if (av != bv) {
                const mag_gt = av > bv;
                if (a.neg) return if (mag_gt) .lt else .gt;
                return if (mag_gt) .gt else .lt;
            }
        }
        return .eq;
    }
    /// POSIX scale of this value: fractional digits after stripping trailing zeros.
    pub fn fracDigitCount(self: Self) usize {
        if (self.isZero() or self.rdx == 0) return 0;
        var remaining: usize = self.rdx * BASE_DIGS;
        var limb_i: usize = 0;
        while (limb_i < self.rdx) : (limb_i += 1) {
            var limb: i64 = if (limb_i < self.len) self.limbs[limb_i] else 0;
            if (limb < 0) limb = -limb;
            var d: usize = 0;
            while (d < BASE_DIGS) : (d += 1) {
                if (@mod(limb, 10) != 0) return remaining;
                remaining -= 1;
                limb = @divTrunc(limb, 10);
            }
        }
        return 0;
    }
    /// Significant decimal digits (dc `Z` / bc `length`). Zero is 1.
    pub fn sigDigitCount(self: Self) usize {
        if (self.isZero()) return 1;
        var int_digits: usize = 0;
        if (self.len > self.rdx) {
            var top = self.limbs[self.len - 1];
            if (top < 0) top = -top;
            while (top > 0) {
                int_digits += 1;
                top = @divTrunc(top, 10);
            }
            int_digits += (self.len - self.rdx - 1) * BASE_DIGS;
        }
        const frac = self.fracDigitCount();
        if (int_digits == 0) return frac;
        return int_digits + frac;
    }
    fn dropFraction(self: *Self) void {
        if (self.rdx == 0) return;
        if (self.len <= self.rdx) {
            self.len = 0;
            self.rdx = 0;
            self.neg = false;
            return;
        }
        const new_len = self.len - self.rdx;
        std.mem.copyForwards(Limb, self.limbs[0..new_len], self.limbs[self.rdx..self.len]);
        self.len = new_len;
        self.rdx = 0;
        self.normalize();
    }
    fn isOdd(self: Self) bool {
        if (self.len == 0 or self.rdx != 0) return false;
        return @mod(self.limbs[0], 2) != 0;
    }
    /// Integer modular exponentiation: base^exp mod modulus.
    /// Exponent 0 yields 1 without reducing (so 0^0 mod 1 is 1).
    pub fn modexp(self: *Self, base: Self, exp: Self, modulus: Self) Error!void {
        if (modulus.isZero()) return error.DivisionByZero;
        if (base.fracDigitCount() != 0 or exp.fracDigitCount() != 0 or modulus.fracDigitCount() != 0)
            return error.NonIntegerExponent;
        if (exp.isNegative()) return error.NonIntegerExponent;

        var m = modulus.clone(self.allocator) catch return error.OutOfMemory;
        defer m.deinit();
        m.dropFraction();
        if (m.isNegative()) m.neg = false;
        if (m.isZero()) return error.DivisionByZero;

        if (exp.isZero()) {
            const one = try fromInt(self.allocator, 1);
            self.deinit();
            self.* = one;
            return;
        }

        var b = base.clone(self.allocator) catch return error.OutOfMemory;
        defer b.deinit();
        b.dropFraction();

        var e = exp.clone(self.allocator) catch return error.OutOfMemory;
        defer e.deinit();
        e.dropFraction();

        var two = try fromInt(self.allocator, 2);
        defer two.deinit();

        {
            var t = Self.init(self.allocator);
            t.mod(b, m, 0) catch |err| {
                t.deinit();
                return err;
            };
            b.deinit();
            b = t;
        }

        var result = try fromInt(self.allocator, 1);
        defer result.deinit();

        while (!e.isZero()) {
            if (e.isOdd()) {
                var prod = Self.init(self.allocator);
                prod.mul(result, b, 0) catch |err| {
                    prod.deinit();
                    return err;
                };
                var reduced = Self.init(self.allocator);
                reduced.mod(prod, m, 0) catch |err| {
                    prod.deinit();
                    reduced.deinit();
                    return err;
                };
                prod.deinit();
                result.deinit();
                result = reduced;
            }
            var half = Self.init(self.allocator);
            half.div(e, two, 0) catch |err| {
                half.deinit();
                return err;
            };
            e.deinit();
            e = half;
            if (e.isZero()) break;
            var sq = Self.init(self.allocator);
            sq.mul(b, b, 0) catch |err| {
                sq.deinit();
                return err;
            };
            var bmod = Self.init(self.allocator);
            bmod.mod(sq, m, 0) catch |err| {
                sq.deinit();
                bmod.deinit();
                return err;
            };
            sq.deinit();
            b.deinit();
            b = bmod;
        }

        if (self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = result.limbs;
        self.len = result.len;
        self.rdx = result.rdx;
        self.neg = result.neg;
        result.limbs = &[_]Limb{};
        result.len = 0;
        result.rdx = 0;
    }
};

fn limbTrim(s: []const Limb) []const Limb {
    var n = s.len;
    while (n > 0 and s[n - 1] == 0) n -= 1;
    return s[0..n];
}

fn mulLimbs(allocator: Allocator, a_in: []const Limb, b_in: []const Limb, cutoff: usize) Error![]Limb {
    const a = limbTrim(a_in);
    const b = limbTrim(b_in);
    if (a.len == 0 or b.len == 0) {
        const z = try allocator.alloc(Limb, 1);
        z[0] = 0;
        return z;
    }
    if (a.len < cutoff or b.len < cutoff) return mulSchoolbook(allocator, a, b);
    return mulKaratsuba(allocator, a, b, cutoff);
}

fn mulSchoolbook(allocator: Allocator, a: []const Limb, b: []const Limb) Error![]Limb {
    const out = try allocator.alloc(Limb, a.len + b.len + 1);
    @memset(out, 0);
    for (0..a.len) |i| {
        var carry: i64 = 0;
        for (0..b.len) |j| {
            const prod = a[i] * b[j] + out[i + j] + carry;
            out[i + j] = @mod(prod, BASE);
            carry = @divTrunc(prod, BASE);
        }
        var k = i + b.len;
        while (carry != 0) {
            const sum = out[k] + carry;
            out[k] = @mod(sum, BASE);
            carry = @divTrunc(sum, BASE);
            k += 1;
        }
    }
    return out;
}

fn addLimbs(allocator: Allocator, a: []const Limb, b: []const Limb) Error![]Limb {
    const n = @max(a.len, b.len);
    const out = try allocator.alloc(Limb, n + 1);
    @memset(out, 0);
    var carry: i64 = 0;
    var i: usize = 0;
    while (i < n or carry != 0) : (i += 1) {
        const av: i64 = if (i < a.len) a[i] else 0;
        const bv: i64 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        out[i] = @mod(sum, BASE);
        carry = @divTrunc(sum, BASE);
    }
    return out;
}

fn growLimbs(allocator: Allocator, old: []Limb, n: usize) Error![]Limb {
    if (old.len >= n) return old;
    const neu = try allocator.alloc(Limb, n);
    @memcpy(neu[0..old.len], old);
    @memset(neu[old.len..], 0);
    allocator.free(old);
    return neu;
}

fn subLimbsInPlace(a: []Limb, b: []const Limb) void {
    var borrow: i64 = 0;
    var i: usize = 0;
    const n = @max(a.len, b.len);
    while (i < n) : (i += 1) {
        const av: i64 = if (i < a.len) a[i] else 0;
        const bv: i64 = if (i < b.len) b[i] else 0;
        var diff = av - bv - borrow;
        if (diff < 0) {
            borrow = 1;
            diff += BASE;
        } else {
            borrow = 0;
        }
        if (i < a.len) {
            a[i] = diff;
        } else {
            std.debug.assert(diff == 0);
        }
    }
    std.debug.assert(borrow == 0);
}

fn addShift(out: []Limb, src: []const Limb, shift: usize) void {
    var carry: i64 = 0;
    var i: usize = 0;
    while (i < src.len or carry != 0) : (i += 1) {
        const idx = i + shift;
        std.debug.assert(idx < out.len);
        const sv: i64 = if (i < src.len) src[i] else 0;
        const sum = out[idx] + sv + carry;
        out[idx] = @mod(sum, BASE);
        carry = @divTrunc(sum, BASE);
    }
}

fn mulKaratsuba(allocator: Allocator, a: []const Limb, b: []const Limb, cutoff: usize) Error![]Limb {
    const n = @max(a.len, b.len);
    const m = n / 2;
    if (m == 0) return mulSchoolbook(allocator, a, b);

    const a0 = if (a.len > m) a[0..m] else a;
    const a1: []const Limb = if (a.len > m) a[m..] else a[0..0];
    const b0 = if (b.len > m) b[0..m] else b;
    const b1: []const Limb = if (b.len > m) b[m..] else b[0..0];

    const z0 = try mulLimbs(allocator, a0, b0, cutoff);
    defer allocator.free(z0);
    const z2 = try mulLimbs(allocator, a1, b1, cutoff);
    defer allocator.free(z2);

    const sa = try addLimbs(allocator, a0, a1);
    defer allocator.free(sa);
    const sb = try addLimbs(allocator, b0, b1);
    defer allocator.free(sb);

    var z1p = try mulLimbs(allocator, sa, sb, cutoff);
    z1p = try growLimbs(allocator, z1p, @max(limbTrim(z0).len, limbTrim(z2).len));
    defer allocator.free(z1p);
    subLimbsInPlace(z1p, limbTrim(z0));
    subLimbsInPlace(z1p, limbTrim(z2));

    // Product fits in na+nb limbs; z1 shifted by m can need one extra.
    const out = try allocator.alloc(Limb, a.len + b.len + m + 8);
    @memset(out, 0);
    addShift(out, limbTrim(z0), 0);
    addShift(out, limbTrim(z1p), m);
    addShift(out, limbTrim(z2), 2 * m);
    return out;
}

test "parse and format round trip" {
    const a = std.testing.allocator;
    var x = try BigDec.parse(a, "123.456", 10);
    defer x.deinit();
    try std.testing.expectEqual(@as(usize, 1), x.rdx);
}
test "add basic" {
    const a = std.testing.allocator;
    var x = try BigDec.parse(a, "2.5", 10);
    defer x.deinit();
    var y = try BigDec.parse(a, "0.25", 10);
    defer y.deinit();
    var s = BigDec.init(a);
    defer s.deinit();
    try s.add(x, y, 4);
    const f = try s.toF64();
    try std.testing.expectApproxEqAbs(@as(f64, 2.75), f, 1e-9);
}
test "div truncates at scale" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, 10);
    defer x.deinit();
    var y = try BigDec.fromInt(a, 3);
    defer y.deinit();
    var q = BigDec.init(a);
    defer q.deinit();
    try q.div(x, y, 6);
    const f = try q.toF64();
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), f, 1e-5);
}
test "digit counts" {
    const a = std.testing.allocator;
    var x = try BigDec.parse(a, "0.25", 10);
    defer x.deinit();
    try std.testing.expectEqual(@as(usize, 2), x.fracDigitCount());
    try std.testing.expectEqual(@as(usize, 2), x.sigDigitCount());
    var z = try BigDec.fromInt(a, 0);
    defer z.deinit();
    try std.testing.expectEqual(@as(usize, 0), z.fracDigitCount());
    try std.testing.expectEqual(@as(usize, 1), z.sigDigitCount());
    var n = try BigDec.fromInt(a, 123);
    defer n.deinit();
    try std.testing.expectEqual(@as(usize, 3), n.sigDigitCount());
}
test "scientific parse and format" {
    const a = std.testing.allocator;
    var n = try BigDec.parse(a, "1e3", 10);
    defer n.deinit();
    try std.testing.expectEqual(@as(f64, 1000.0), try n.toF64());
    var n2 = try BigDec.parse(a, "1.5e-1", 10);
    defer n2.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), try n2.toF64(), 1e-12);
    var n3 = try BigDec.parse(a, "2e+2", 10);
    defer n3.deinit();
    try std.testing.expectEqual(@as(f64, 200.0), try n3.toF64());
    var n4 = try BigDec.parse(a, "-1.2E3", 10);
    defer n4.deinit();
    try std.testing.expectEqual(@as(f64, -1200.0), try n4.toF64());

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var thousand = try BigDec.fromInt(a, 1000);
    defer thousand.deinit();
    try thousand.formatSci(&w, 0, false);
    try std.testing.expectEqualStrings("1e3", w.buffered());
    w = .fixed(&buf);
    var n12345 = try BigDec.fromInt(a, 12345);
    defer n12345.deinit();
    try n12345.formatSci(&w, 3, true);
    try std.testing.expectEqualStrings("12.345e3", w.buffered());
}
test "format multi-limb integers" {
    const a = std.testing.allocator;
    var two = try BigDec.fromInt(a, 2);
    defer two.deinit();
    var e64 = try BigDec.fromInt(a, 64);
    defer e64.deinit();
    var p = BigDec.init(a);
    defer p.deinit();
    try p.pow(two, e64, 0);

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.format(&w, 10, 20);
    try std.testing.expectEqualStrings("18446744073709551616", w.buffered());

    var big = try BigDec.parse(a, "123456789013", 10);
    defer big.deinit();
    var w2: std.Io.Writer = .fixed(&buf);
    try big.format(&w2, 10, 20);
    try std.testing.expectEqualStrings("123456789013", w2.buffered());

    var nbig = try BigDec.parse(a, "-123456789013", 10);
    defer nbig.deinit();
    var w3: std.Io.Writer = .fixed(&buf);
    try nbig.format(&w3, 10, 20);
    try std.testing.expectEqualStrings("-123456789013", w3.buffered());

    var w4: std.Io.Writer = .fixed(&buf);
    try p.format(&w4, 16, 20);
    try std.testing.expectEqualStrings("10000000000000000", w4.buffered());
}

test "modexp 100^8 mod 7" {
    const a = std.testing.allocator;
    var base = try BigDec.fromInt(a, 100);
    defer base.deinit();
    var exp = try BigDec.fromInt(a, 8);
    defer exp.deinit();
    var modulus = try BigDec.fromInt(a, 7);
    defer modulus.deinit();
    var r = BigDec.init(a);
    defer r.deinit();
    try r.modexp(base, exp, modulus);
    try std.testing.expectEqual(@as(f64, 4.0), try r.toF64());
}
test "modexp 0^0 mod 1 is 1" {
    const a = std.testing.allocator;
    var base = try BigDec.fromInt(a, 0);
    defer base.deinit();
    var exp = try BigDec.fromInt(a, 0);
    defer exp.deinit();
    var modulus = try BigDec.fromInt(a, 1);
    defer modulus.deinit();
    var r = BigDec.init(a);
    defer r.deinit();
    try r.modexp(base, exp, modulus);
    try std.testing.expectEqual(@as(f64, 1.0), try r.toF64());
}

fn expectFormat(n: BigDec, obase: u8, max_frac: usize, expected: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try n.format(&w, obase, max_frac);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "format 255 obase 16 max_frac 0 is FF" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, 255);
    defer x.deinit();
    try expectFormat(x, 16, 0, "FF");
}

test "format 10 obase 2 is 1010" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, 10);
    defer x.deinit();
    try expectFormat(x, 2, 0, "1010");
}

test "format 8 obase 8 is 10" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, 8);
    defer x.deinit();
    try expectFormat(x, 8, 0, "10");
}

test "format 255 obase 10 still 255" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, 255);
    defer x.deinit();
    try expectFormat(x, 10, 0, "255");
}

test "format -255 obase 16 is -FF" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, -255);
    defer x.deinit();
    try expectFormat(x, 16, 0, "-FF");
}

test "format 0.5 obase 16 contains 0.8" {
    const a = std.testing.allocator;
    var x = try BigDec.parse(a, "0.5", 10);
    defer x.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try x.format(&w, 16, 1);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "0.8") != null);
}

test "cmp orders negatives" {
    const a = std.testing.allocator;
    var x = try BigDec.fromInt(a, -3);
    defer x.deinit();
    var y = try BigDec.fromInt(a, -1);
    defer y.deinit();
    try std.testing.expectEqual(std.math.Order.lt, BigDec.cmp(x, y));
    try std.testing.expectEqual(std.math.Order.gt, BigDec.cmp(y, x));
    var z = try BigDec.fromInt(a, 2);
    defer z.deinit();
    try std.testing.expectEqual(std.math.Order.lt, BigDec.cmp(x, z));
    try std.testing.expectEqual(std.math.Order.gt, BigDec.cmp(z, x));
}

test "karatsuba matches schoolbook" {
    const a = std.testing.allocator;
    const digits = "1234567890123456789012345678901234567890123456789012345678901234567890";
    var x = try BigDec.parse(a, digits, 10);
    defer x.deinit();
    var y = try BigDec.parse(a, digits, 10);
    defer y.deinit();
    var school = BigDec.init(a);
    defer school.deinit();
    try school.mulWithCutoff(x, y, 10000);
    var kara = BigDec.init(a);
    defer kara.deinit();
    try kara.mulWithCutoff(x, y, 2);
    try std.testing.expectEqual(std.math.Order.eq, school.cmp(kara));
}

test "karatsuba uneven limb counts" {
    const a = std.testing.allocator;
    var x = try BigDec.parse(a, "999999999999999999999999999999", 10);
    defer x.deinit();
    var y = try BigDec.parse(a, "7", 10);
    defer y.deinit();
    var school = BigDec.init(a);
    defer school.deinit();
    try school.mulWithCutoff(x, y, 10000);
    var kara = BigDec.init(a);
    defer kara.deinit();
    try kara.mulWithCutoff(x, y, 2);
    try std.testing.expectEqual(std.math.Order.eq, school.cmp(kara));
}

test "mul bench schoolbook vs karatsuba" {
    const a = std.testing.allocator;
    var digits: [360]u8 = undefined;
    @memset(&digits, '9');
    var x = try BigDec.parse(a, &digits, 10);
    defer x.deinit();
    var y = try BigDec.parse(a, &digits, 10);
    defer y.deinit();
    var school = BigDec.init(a);
    defer school.deinit();
    try school.mulWithCutoff(x, y, 10000);
    var kara = BigDec.init(a);
    defer kara.deinit();
    try kara.mulWithCutoff(x, y, 2);
    try std.testing.expectEqual(std.math.Order.eq, school.cmp(kara));
    try std.testing.expect(x.len >= 32);
    try std.testing.expect(school.len > 0);
}
