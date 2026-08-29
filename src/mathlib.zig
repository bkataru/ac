//! bc -l math library: pi, ln, exp, sin, cos, atan, Bessel j(n,x),
//! plus extras (tan, asin, acos, log*) and always-on helpers
//! (abs, ceil, floor, round, gcd, lcm, factorial, perm, comb,
//! max, min, root, cbrt, modexp, bitwise).
//!
//! All series are evaluated at internal precision p = scale + GUARD
//! digits; final results are truncated to `scale`. Terms iterate with
//! BigDec division that truncates at p, so a term that truncates to zero
//! ends the series (terms are monotonically decreasing in magnitude).
const std = @import("std");
const BigDec = @import("num.zig").BigDec;
const Allocator = std.mem.Allocator;

/// Digits computed beyond the requested scale.
const GUARD: usize = 12;

fn prec(scale: usize) usize {
    return scale + GUARD;
}

fn isNeg(x: BigDec) bool {
    return x.neg and !x.isZero();
}

/// |x| with the sign flag preserved on a fresh value.
fn absOf(alloc: Allocator, x: BigDec) !BigDec {
    var r = try x.clone(alloc);
    r.neg = false;
    return r;
}

/// atan(1/m) for integer m >= 2 via the alternating Taylor series
/// sum (-1)^k / ((2k+1) m^(2k+1)).
pub fn atanRecip(alloc: Allocator, m: i64, scale: usize) !BigDec {
    const p = prec(scale);
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var dm = try BigDec.fromInt(alloc, m);
    defer dm.deinit();

    // term = 1/m; power-multiplier = 1/m^2
    var term = BigDec.init(alloc);
    defer term.deinit();
    try term.div(one, dm, p);
    var sum = try term.clone(alloc);
    defer sum.deinit();

    var m2 = BigDec.init(alloc);
    defer m2.deinit();
    try m2.mul(dm, dm, 0);

    var k: i64 = 1;
    while (true) {
        // term = term / m^2 (now (1/m)^(2k+1))
        var t = BigDec.init(alloc);
        errdefer t.deinit();
        try t.div(term, m2, p);
        if (t.isZero()) {
            t.deinit();
            break;
        }
        var dk = try BigDec.fromInt(alloc, 2 * k + 1);
        defer dk.deinit();
        var scaled = BigDec.init(alloc);
        errdefer scaled.deinit();
        try scaled.div(t, dk, p);
        // alternate sign: subtract on odd k
        if (@mod(k, 2) == 1) scaled.neg = !scaled.neg;
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, scaled, p);
        scaled.deinit();
        term.deinit();
        term = t;
        sum.deinit();
        sum = next;
        k += 1;
    }
    const result = try sum.clone(alloc);
    return result;
}

/// pi via Machin's formula: pi = 16 atan(1/5) - 4 atan(1/239).
pub fn pi(alloc: Allocator, scale: usize) !BigDec {
    const p = prec(scale);
    var a5 = try atanRecip(alloc, 5, p);
    defer a5.deinit();
    var a239 = try atanRecip(alloc, 239, p);
    defer a239.deinit();

    var c16 = try BigDec.fromInt(alloc, 16);
    defer c16.deinit();
    var c4 = try BigDec.fromInt(alloc, 4);
    defer c4.deinit();
    var t = BigDec.init(alloc);
    defer t.deinit();
    try t.mul(a5, c16, p);
    var u = BigDec.init(alloc);
    defer u.deinit();
    try u.mul(a239, c4, p);
    var r = BigDec.init(alloc);
    defer r.deinit();
    try r.sub(t, u, p);
    // Keep exactly `scale` fractional digits (no leftover guard digits).
    var fac = try pow10(alloc, scale);
    defer fac.deinit();
    var scaled = BigDec.init(alloc);
    defer scaled.deinit();
    try scaled.mul(r, fac, 0);
    var truncd = try truncTowardZero(alloc, scaled);
    defer truncd.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(truncd, fac, scale);
    return out;
}

/// e^x for any BigDec x.
pub fn exp(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    // exp(-x) = 1/exp(x)
    if (isNeg(x)) {
        var pos = try absOf(alloc, x);
        defer pos.deinit();
        var e = try exp(alloc, pos, scale);
        defer e.deinit();
        var one = try BigDec.fromInt(alloc, 1);
        defer one.deinit();
        var r = BigDec.init(alloc);
        errdefer r.deinit();
        try r.div(one, e, p);
        return r;
    }
    // Reduce: x = y * 2^n with |y| < 1.
    var y = try x.clone(alloc);
    defer y.deinit();
    var halves: usize = 0;
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var cmp_two = BigDec.cmp(y, two);
    while (cmp_two != .lt) : (cmp_two = BigDec.cmp(y, two)) {
        var ny = BigDec.init(alloc);
        errdefer ny.deinit();
        try ny.div(y, two, p);
        y.deinit();
        y = ny;
        halves += 1;
    }
    // Taylor: sum y^k / k!
    var sum = try BigDec.fromInt(alloc, 1);
    defer sum.deinit();
    var term = try BigDec.fromInt(alloc, 1);
    defer term.deinit();
    var k: i64 = 1;
    while (true) {
        var dk = try BigDec.fromInt(alloc, k);
        defer dk.deinit();
        var t1 = BigDec.init(alloc);
        errdefer t1.deinit();
        try t1.mul(term, y, p);
        var t2 = BigDec.init(alloc);
        errdefer t2.deinit();
        try t2.div(t1, dk, p);
        t1.deinit();
        if (t2.isZero()) {
            t2.deinit();
            break;
        }
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, t2, p);
        term.deinit();
        term = t2;
        sum.deinit();
        sum = next;
        k += 1;
    }
    // Square back up.
    var i: usize = 0;
    while (i < halves) : (i += 1) {
        var sq = BigDec.init(alloc);
        errdefer sq.deinit();
        try sq.mul(sum, sum, p);
        sum.deinit();
        sum = sq;
    }
    const result = try sum.clone(alloc);
    return result;
}

/// ln(x) for x > 0.
pub fn ln(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    if (isNeg(x) or x.isZero()) return error.InvalidOperand;
    const p = prec(scale);
    // Reduce x = y * 2^n with y in [0.5, 2).
    var y = try x.clone(alloc);
    defer y.deinit();
    var n: i64 = 0;
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var half = BigDec.init(alloc);
    defer half.deinit();
    {
        var one0 = try BigDec.fromInt(alloc, 1);
        defer one0.deinit();
        try half.div(one0, two, p);
    }
    var guard: usize = 0;
    while (BigDec.cmp(y, two) != .lt) {
        guard += 1;
        if (guard > 200) break;
        var ny = BigDec.init(alloc);
        errdefer ny.deinit();
        try ny.div(y, two, p);
        y.deinit();
        y = ny;
        n += 1;
    }
    var cmp_half = BigDec.cmp(y, half);
    guard = 0;
    while (cmp_half == .lt) : (cmp_half = BigDec.cmp(y, half)) {
        guard += 1;
        if (guard > 200) break;
        var ny = BigDec.init(alloc);
        errdefer ny.deinit();
        try ny.mul(y, two, p);
        y.deinit();
        y = ny;
        n -= 1;
    }
    // atanh series: ln(y) = 2 (t + t^3/3 + t^5/5 + ...), t = (y-1)/(y+1).
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var num = BigDec.init(alloc);
    defer num.deinit();
    try num.sub(y, one, p);
    var den = BigDec.init(alloc);
    defer den.deinit();
    try den.add(y, one, p);
    var t = BigDec.init(alloc);
    defer t.deinit();
    try t.div(num, den, p);

    var t2 = BigDec.init(alloc);
    defer t2.deinit();
    try t2.mul(t, t, p);

    var sum = try t.clone(alloc);
    defer sum.deinit();
    var term = try t.clone(alloc);
    defer term.deinit();
    var k: i64 = 1;
    while (true) {
        if (k > 5000) break;
        var tk = BigDec.init(alloc);
        errdefer tk.deinit();
        var raw = BigDec.init(alloc);
        defer raw.deinit();
        try raw.mul(term, t2, p);
        // mul is exact and never truncates; clip to working precision so
        // the geometric decay actually reaches zero.
        try tk.div(raw, one, p);
        if (tk.isZero()) {
            tk.deinit();
            break;
        }
        var dk = try BigDec.fromInt(alloc, 2 * k + 1);
        defer dk.deinit();
        var scaled = BigDec.init(alloc);
        errdefer scaled.deinit();
        try scaled.div(tk, dk, p);
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, scaled, p);
        scaled.deinit();
        term.deinit();
        term = tk;
        sum.deinit();
        sum = next;
        k += 1;
    }
    var ln_y = BigDec.init(alloc);
    defer ln_y.deinit();
    try ln_y.mul(sum, two, p);

    // ln(x) = n*ln2 + ln(y); ln2 = 2 atanh(1/3) computed via the same
    // series (t = 1/3 converges geometrically).
    if (n != 0) {
        var third = BigDec.init(alloc);
        defer third.deinit();
        {
            var c3 = try BigDec.fromInt(alloc, 3);
            defer c3.deinit();
            try third.div(one, c3, p);
        }
        var ln2 = try lnSmall(alloc, third, p);
        defer ln2.deinit();
        var n_ln2 = BigDec.init(alloc);
        errdefer n_ln2.deinit();
        var cn = try BigDec.fromInt(alloc, n);
        defer cn.deinit();
        try n_ln2.mul(ln2, cn, p);
        var r = BigDec.init(alloc);
        errdefer r.deinit();
        try r.add(ln_y, n_ln2, p);
        n_ln2.deinit();
        return r;
    }
    const result = try ln_y.clone(alloc);
    return result;
}

/// 2*atanh(t) for |t| <= 1/3; series converges fast.
fn lnSmall(alloc: Allocator, t: BigDec, p: usize) !BigDec {
    var sum = try t.clone(alloc);
    defer sum.deinit();
    var term = try t.clone(alloc);
    defer term.deinit();
    var t2 = BigDec.init(alloc);
    defer t2.deinit();
    try t2.mul(t, t, p);
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var k: i64 = 1;
    while (true) {
        if (k > 5000) break;
        var tk = BigDec.init(alloc);
        errdefer tk.deinit();
        var raw = BigDec.init(alloc);
        defer raw.deinit();
        try raw.mul(term, t2, p);
        try tk.div(raw, one, p);
        if (tk.isZero()) {
            tk.deinit();
            break;
        }
        var dk = try BigDec.fromInt(alloc, 2 * k + 1);
        defer dk.deinit();
        var scaled = BigDec.init(alloc);
        errdefer scaled.deinit();
        try scaled.div(tk, dk, p);
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, scaled, p);
        scaled.deinit();
        term.deinit();
        term = tk;
        sum.deinit();
        sum = next;
        k += 1;
    }
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var r = BigDec.init(alloc);
    errdefer r.deinit();
    try r.mul(sum, two, p);
    return r;
}

/// Reduce x to r in [0, 2*pi): r = x - 2*pi*trunc(x / 2*pi), and when the
/// truncated division rounds the wrong way for negatives, wrap once.
fn reduce2pi(alloc: Allocator, x: BigDec, two_pi: BigDec, p: usize) !BigDec {
    var q = BigDec.init(alloc);
    defer q.deinit();
    try q.div(x, two_pi, 0); // truncates toward zero
    var qr = BigDec.init(alloc);
    defer qr.deinit();
    try qr.mul(q, two_pi, p);
    var r = BigDec.init(alloc);
    errdefer r.deinit();
    try r.sub(x, qr, p);
    if (isNeg(r)) {
        var wrapped = BigDec.init(alloc);
        errdefer wrapped.deinit();
        try wrapped.add(r, two_pi, p);
        r.deinit();
        r = wrapped;
    }
    return r;
}

/// sin(x).
pub fn sin(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var two_pi = try pi(alloc, p);
    defer two_pi.deinit();
    var t2 = BigDec.init(alloc);
    defer t2.deinit();
    var c2 = try BigDec.fromInt(alloc, 2);
    defer c2.deinit();
    try t2.mul(two_pi, c2, p);
    var r = try reduce2pi(alloc, x, t2, p);
    defer r.deinit();

    var sum = try r.clone(alloc);
    defer sum.deinit();
    var term = try r.clone(alloc);
    defer term.deinit();
    var rsq = BigDec.init(alloc);
    defer rsq.deinit();
    try rsq.mul(r, r, p);
    var k: i64 = 1;
    while (true) {
        var dk1 = try BigDec.fromInt(alloc, 2 * k);
        defer dk1.deinit();
        var dk2 = try BigDec.fromInt(alloc, 2 * k + 1);
        defer dk2.deinit();
        var t1 = BigDec.init(alloc);
        errdefer t1.deinit();
        try t1.mul(term, rsq, p);
        var t2d = BigDec.init(alloc);
        errdefer t2d.deinit();
        try t2d.div(t1, dk1, p);
        t1.deinit();
        var tn = BigDec.init(alloc);
        errdefer tn.deinit();
        try tn.div(t2d, dk2, p);
        t2d.deinit();
        if (tn.isZero()) {
            tn.deinit();
            break;
        }
        tn.neg = !tn.neg;
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, tn, p);
        term.deinit();
        term = tn;
        sum.deinit();
        sum = next;
        k += 1;
    }
    const result = try sum.clone(alloc);
    return result;
}

/// cos(x).
pub fn cos(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var two_pi = try pi(alloc, p);
    defer two_pi.deinit();
    var t2 = BigDec.init(alloc);
    defer t2.deinit();
    var c2 = try BigDec.fromInt(alloc, 2);
    defer c2.deinit();
    try t2.mul(two_pi, c2, p);
    var r = try reduce2pi(alloc, x, t2, p);
    defer r.deinit();

    var sum = try BigDec.fromInt(alloc, 1);
    defer sum.deinit();
    var term = try BigDec.fromInt(alloc, 1);
    defer term.deinit();
    var rsq = BigDec.init(alloc);
    defer rsq.deinit();
    try rsq.mul(r, r, p);
    var k: i64 = 1;
    while (true) {
        var dk1 = try BigDec.fromInt(alloc, 2 * k - 1);
        defer dk1.deinit();
        var dk2 = try BigDec.fromInt(alloc, 2 * k);
        defer dk2.deinit();
        var t1 = BigDec.init(alloc);
        errdefer t1.deinit();
        try t1.mul(term, rsq, p);
        var t2d = BigDec.init(alloc);
        errdefer t2d.deinit();
        try t2d.div(t1, dk1, p);
        t1.deinit();
        var tn = BigDec.init(alloc);
        errdefer tn.deinit();
        try tn.div(t2d, dk2, p);
        t2d.deinit();
        if (tn.isZero()) {
            tn.deinit();
            break;
        }
        tn.neg = !tn.neg;
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, tn, p);
        term.deinit();
        term = tn;
        sum.deinit();
        sum = next;
        k += 1;
    }
    const result = try sum.clone(alloc);
    return result;
}

/// atan(x) for any x (result in (-pi/2, pi/2)).
pub fn atan(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    if (isNeg(x)) {
        var pos = try absOf(alloc, x);
        defer pos.deinit();
        var a = try atan(alloc, pos, scale);
        a.neg = true;
        return a;
    }
    var half_pi = try pi(alloc, p);
    defer half_pi.deinit();
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    try half_pi.div(half_pi, two, p);

    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    const cmp_one = BigDec.cmp(x, one);
    if (cmp_one == .gt) {
        var inv = BigDec.init(alloc);
        defer inv.deinit();
        try inv.div(one, x, p);
        var inner = try atanSmall(alloc, inv, p);
        defer inner.deinit();
        var r = BigDec.init(alloc);
        errdefer r.deinit();
        try r.sub(half_pi, inner, p);
        return r;
    }
    return atanSmall(alloc, x, p);
}

/// atan(x) for 0 <= x <= 1: halve the argument with
/// atan(x) = 2 atan(x / (1 + sqrt(1 + x^2))), then Taylor.
fn atanSmall(alloc: Allocator, x: BigDec, p: usize) !BigDec {
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var y = try x.clone(alloc);
    defer y.deinit();
    var doublings: usize = 0;
    var quarter = BigDec.init(alloc);
    defer quarter.deinit();
    {
        var four = try BigDec.fromInt(alloc, 4);
        defer four.deinit();
        {
            var one0 = try BigDec.fromInt(alloc, 1);
            defer one0.deinit();
            try quarter.div(one0, four, p);
        }
    }
    var cmp_q = BigDec.cmp(y, quarter);
    var guard: usize = 0;
    while (cmp_q == .gt) : (cmp_q = BigDec.cmp(y, quarter)) {
        guard += 1;
        if (guard > 64) break;
        var ysq = BigDec.init(alloc);
        defer ysq.deinit();
        try ysq.mul(y, y, p);
        var inner = BigDec.init(alloc);
        defer inner.deinit();
        try inner.add(one, ysq, p);
        var root = BigDec.init(alloc);
        defer root.deinit();
        try root.sqrt(inner, p);
        var den = BigDec.init(alloc);
        defer den.deinit();
        try den.add(one, root, p);
        var yn = BigDec.init(alloc);
        errdefer yn.deinit();
        try yn.div(y, den, p);
        y.deinit();
        y = yn;
        doublings += 1;
    }

    var sum = try y.clone(alloc);
    defer sum.deinit();
    var term = try y.clone(alloc);
    defer term.deinit();
    var ysq = BigDec.init(alloc);
    defer ysq.deinit();
    try ysq.mul(y, y, p);
    var k: i64 = 1;
    while (true) {
        if (k > 5000) break;
        var t1 = BigDec.init(alloc);
        errdefer t1.deinit();
        try t1.mul(term, ysq, p);
        if (t1.isZero()) {
            t1.deinit();
            break;
        }
        var dk = try BigDec.fromInt(alloc, 2 * k + 1);
        defer dk.deinit();
        var scaled = BigDec.init(alloc);
        errdefer scaled.deinit();
        try scaled.div(t1, dk, p);
        if (scaled.isZero()) {
            scaled.deinit();
            t1.deinit();
            break;
        }
        if (@mod(k, 2) == 1) scaled.neg = !scaled.neg;
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(sum, scaled, p);
        scaled.deinit();
        term.deinit();
        term = t1;
        sum.deinit();
        sum = next;
        k += 1;
    }
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var d: usize = 0;
    while (d < doublings) : (d += 1) {
        var dbl = BigDec.init(alloc);
        errdefer dbl.deinit();
        try dbl.mul(sum, two, p);
        sum.deinit();
        sum = dbl;
    }
    const result = try sum.clone(alloc);
    return result;
}

/// POSIX bc -l Bessel J_n(x). `n` is truncated toward zero to an integer.
/// Series: J_n(x) = (x/2)^n / n! * sum_k (-1)^k / (k!(n+1)..(n+k)) * (x/2)^{2k}.
/// Negative order uses J_{-n}(x) = (-1)^n J_n(x).
pub fn besselJ(alloc: Allocator, n_in: BigDec, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();

    var n_trunc = BigDec.init(alloc);
    defer n_trunc.deinit();
    try n_trunc.div(n_in, one, 0);
    const n_f = n_trunc.toF64() catch return error.InvalidOperand;
    if (!std.math.isFinite(n_f) or @abs(n_f) > 10_000) return error.InvalidOperand;
    const n_abs: i64 = @intFromFloat(@abs(@trunc(n_f)));
    const odd_neg = n_f < 0 and @mod(n_abs, 2) == 1;

    var fact = try BigDec.fromInt(alloc, 1);
    defer fact.deinit();
    var fi: i64 = 2;
    while (fi <= n_abs) : (fi += 1) {
        var di = try BigDec.fromInt(alloc, fi);
        defer di.deinit();
        var t = BigDec.init(alloc);
        errdefer t.deinit();
        try t.mul(fact, di, 0);
        fact.deinit();
        fact = t;
    }

    var n_bd = try BigDec.fromInt(alloc, n_abs);
    defer n_bd.deinit();
    var xpow = BigDec.init(alloc);
    defer xpow.deinit();
    try xpow.pow(x, n_bd, p);
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var two_n = BigDec.init(alloc);
    defer two_n.deinit();
    try two_n.pow(two, n_bd, 0);

    var tmp = BigDec.init(alloc);
    defer tmp.deinit();
    try tmp.div(xpow, two_n, p);
    var a = BigDec.init(alloc);
    defer a.deinit();
    try a.div(tmp, fact, p);

    var r = try BigDec.fromInt(alloc, 1);
    defer r.deinit();
    var v = try BigDec.fromInt(alloc, 1);
    defer v.deinit();
    var xsq = BigDec.init(alloc);
    defer xsq.deinit();
    try xsq.mul(x, x, p);
    var four = try BigDec.fromInt(alloc, 4);
    defer four.deinit();
    var f = BigDec.init(alloc);
    defer f.deinit();
    try f.div(xsq, four, p);
    if (!f.isZero()) f.neg = !f.neg;

    var k: i64 = 1;
    while (k < 100_000) : (k += 1) {
        var t1 = BigDec.init(alloc);
        defer t1.deinit();
        try t1.mul(v, f, p);
        var dk = try BigDec.fromInt(alloc, k);
        defer dk.deinit();
        var t2 = BigDec.init(alloc);
        defer t2.deinit();
        try t2.div(t1, dk, p);
        var dnk = try BigDec.fromInt(alloc, n_abs + k);
        defer dnk.deinit();
        var vn = BigDec.init(alloc);
        errdefer vn.deinit();
        try vn.div(t2, dnk, p);
        if (vn.isZero()) {
            vn.deinit();
            break;
        }
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(r, vn, p);
        v.deinit();
        v = vn;
        r.deinit();
        r = next;
    }

    var result = BigDec.init(alloc);
    errdefer result.deinit();
    try result.mul(a, r, p);
    if (odd_neg and !result.isZero()) result.neg = !result.neg;
    return result;
}

fn truncTowardZero(alloc: Allocator, x: BigDec) !BigDec {
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var t = BigDec.init(alloc);
    errdefer t.deinit();
    try t.div(x, one, 0);
    return t;
}

/// Absolute value.
pub fn abs(alloc: Allocator, x: BigDec) !BigDec {
    return absOf(alloc, x);
}

/// Greatest integer ≤ x.
pub fn floor(alloc: Allocator, x: BigDec) !BigDec {
    var t = try truncTowardZero(alloc, x);
    if (x.fracDigitCount() == 0 or !isNeg(x)) return t;
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.sub(t, one, 0);
    t.deinit();
    return out;
}

/// Least integer ≥ x.
pub fn ceil(alloc: Allocator, x: BigDec) !BigDec {
    var t = try truncTowardZero(alloc, x);
    if (x.fracDigitCount() == 0 or isNeg(x)) return t;
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.add(t, one, 0);
    t.deinit();
    return out;
}

/// Nearest integer; halves move away from zero.
pub fn round(alloc: Allocator, x: BigDec) !BigDec {
    var t = try truncTowardZero(alloc, x);
    if (x.fracDigitCount() == 0) return t;
    var ax = try absOf(alloc, x);
    defer ax.deinit();
    var at = try absOf(alloc, t);
    defer at.deinit();
    var frac = BigDec.init(alloc);
    defer frac.deinit();
    try frac.sub(ax, at, 0);
    var half = try BigDec.parse(alloc, "0.5", 10);
    defer half.deinit();
    if (BigDec.cmp(frac, half) == .lt) return t;
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    if (isNeg(x)) {
        try out.sub(t, one, 0);
    } else {
        try out.add(t, one, 0);
    }
    t.deinit();
    return out;
}

/// Positive gcd. Both arguments must be integers.
pub fn gcd(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    if (a.fracDigitCount() != 0 or b.fracDigitCount() != 0) return error.InvalidOperand;
    var x = try absOf(alloc, a);
    errdefer x.deinit();
    var y = try absOf(alloc, b);
    errdefer y.deinit();
    while (!y.isZero()) {
        var r = BigDec.init(alloc);
        errdefer r.deinit();
        try r.mod(x, y, 0);
        x.deinit();
        x = y;
        y = r;
    }
    y.deinit();
    return x;
}

/// Positive lcm. Both arguments must be integers.
pub fn lcm(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    if (a.fracDigitCount() != 0 or b.fracDigitCount() != 0) return error.InvalidOperand;
    if (a.isZero() or b.isZero()) return BigDec.fromInt(alloc, 0);
    var g = try gcd(alloc, a, b);
    defer g.deinit();
    var ax = try absOf(alloc, a);
    defer ax.deinit();
    var bx = try absOf(alloc, b);
    defer bx.deinit();
    var prod = BigDec.init(alloc);
    defer prod.deinit();
    try prod.mul(ax, bx, 0);
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(prod, g, 0);
    return out;
}

/// n! for a non-negative integer n ≤ 1000.
pub fn factorial(alloc: Allocator, n: BigDec) !BigDec {
    if (n.fracDigitCount() != 0 or isNeg(n)) return error.InvalidOperand;
    const f = n.toF64() catch return error.InvalidOperand;
    if (!std.math.isFinite(f) or f > 1000) return error.InvalidOperand;
    const ni: i64 = @intFromFloat(f);
    var acc = try BigDec.fromInt(alloc, 1);
    errdefer acc.deinit();
    var i: i64 = 2;
    while (i <= ni) : (i += 1) {
        var di = try BigDec.fromInt(alloc, i);
        defer di.deinit();
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.mul(acc, di, 0);
        acc.deinit();
        acc = next;
    }
    return acc;
}

fn asNonNegUsize(x: BigDec, cap: usize) !usize {
    if (x.fracDigitCount() != 0 or isNeg(x)) return error.InvalidOperand;
    const f = x.toF64() catch return error.InvalidOperand;
    if (!std.math.isFinite(f) or @floor(f) != f) return error.InvalidOperand;
    if (f > @as(f64, @floatFromInt(cap))) return error.InvalidOperand;
    return @intFromFloat(f);
}

fn pow10(alloc: Allocator, places: usize) !BigDec {
    var ten = try BigDec.fromInt(alloc, 10);
    defer ten.deinit();
    var pexp = try BigDec.fromInt(alloc, @as(i64, @intCast(places)));
    defer pexp.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.pow(ten, pexp, 0);
    return out;
}

/// Round x to `places` digits after the point (halves away from zero).
pub fn roundPlaces(alloc: Allocator, x: BigDec, places: BigDec) !BigDec {
    const p = try asNonNegUsize(places, 100000);
    if (p == 0) return round(alloc, x);
    var fac = try pow10(alloc, p);
    defer fac.deinit();
    var scaled = BigDec.init(alloc);
    defer scaled.deinit();
    try scaled.mul(x, fac, 0);
    var r = try round(alloc, scaled);
    defer r.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(r, fac, p);
    return out;
}

/// Least value with `places` digits after the point that is ≥ x.
pub fn ceilPlaces(alloc: Allocator, x: BigDec, places: BigDec) !BigDec {
    const p = try asNonNegUsize(places, 100000);
    if (p == 0) return ceil(alloc, x);
    var fac = try pow10(alloc, p);
    defer fac.deinit();
    var scaled = BigDec.init(alloc);
    defer scaled.deinit();
    try scaled.mul(x, fac, 0);
    var c = try ceil(alloc, scaled);
    defer c.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(c, fac, p);
    return out;
}

/// nPk = n·(n-1)·…·(n-k+1) for integers 0 ≤ k ≤ n ≤ 1000.
pub fn perm(alloc: Allocator, n: BigDec, k: BigDec) !BigDec {
    const nn = try asNonNegUsize(n, 1000);
    const kk = try asNonNegUsize(k, 1000);
    if (kk > nn) return error.InvalidOperand;
    var acc = try BigDec.fromInt(alloc, 1);
    errdefer acc.deinit();
    var i: usize = 0;
    while (i < kk) : (i += 1) {
        var term = try BigDec.fromInt(alloc, @as(i64, @intCast(nn - i)));
        defer term.deinit();
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.mul(acc, term, 0);
        acc.deinit();
        acc = next;
    }
    return acc;
}

/// nCk for integers 0 ≤ k ≤ n ≤ 1000.
pub fn comb(alloc: Allocator, n: BigDec, k: BigDec) !BigDec {
    const nn = try asNonNegUsize(n, 1000);
    var kk = try asNonNegUsize(k, 1000);
    if (kk > nn) return error.InvalidOperand;
    if (kk > nn - kk) kk = nn - kk;
    var acc = try BigDec.fromInt(alloc, 1);
    errdefer acc.deinit();
    var i: usize = 0;
    while (i < kk) : (i += 1) {
        var numf = try BigDec.fromInt(alloc, @as(i64, @intCast(nn - kk + 1 + i)));
        defer numf.deinit();
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.mul(acc, numf, 0);
        acc.deinit();
        acc = next;
        var den = try BigDec.fromInt(alloc, @as(i64, @intCast(i + 1)));
        defer den.deinit();
        var q = BigDec.init(alloc);
        errdefer q.deinit();
        try q.div(acc, den, 0);
        acc.deinit();
        acc = q;
    }
    return acc;
}

pub fn maxVal(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    if (BigDec.cmp(a, b) == .lt) return b.clone(alloc);
    return a.clone(alloc);
}

pub fn minVal(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    if (BigDec.cmp(a, b) == .gt) return b.clone(alloc);
    return a.clone(alloc);
}

/// Integer nth root of x, truncated to `scale`. Even n rejects x < 0.
pub fn nthRoot(alloc: Allocator, x: BigDec, n: BigDec, scale: usize) !BigDec {
    const ni64: i64 = blk: {
        const nu = try asNonNegUsize(n, 10000);
        if (nu == 0) return error.InvalidOperand;
        break :blk @intCast(nu);
    };
    if (ni64 == 1) {
        var one = try BigDec.fromInt(alloc, 1);
        defer one.deinit();
        var out = BigDec.init(alloc);
        errdefer out.deinit();
        try out.div(x, one, scale);
        return out;
    }
    const neg = isNeg(x);
    if (neg and @mod(ni64, 2) == 0) return error.NegativeSquareRoot;
    var ax = try absOf(alloc, x);
    defer ax.deinit();
    if (ax.isZero()) return BigDec.fromInt(alloc, 0);
    if (ni64 == 2) {
        var out = BigDec.init(alloc);
        errdefer out.deinit();
        try out.sqrt(ax, scale);
        return out;
    }

    const p = prec(scale);
    const xf = ax.toF64() catch 1.0;
    const nf: f64 = @floatFromInt(ni64);
    var guess_f = if (std.math.isFinite(xf) and xf > 0)
        std.math.pow(f64, xf, 1.0 / nf)
    else
        1.0;
    if (!std.math.isFinite(guess_f) or guess_f <= 0) guess_f = 1.0;

    var y = try BigDec.fromF64(alloc, guess_f, p);
    defer y.deinit();
    if (y.isZero()) {
        y.deinit();
        y = try BigDec.fromInt(alloc, 1);
    }
    var n_bd = try BigDec.fromInt(alloc, ni64);
    defer n_bd.deinit();
    var nm1 = try BigDec.fromInt(alloc, ni64 - 1);
    defer nm1.deinit();

    var it: usize = 0;
    while (it < 12) : (it += 1) {
        var ypow = BigDec.init(alloc);
        defer ypow.deinit();
        try ypow.pow(y, nm1, p);
        if (ypow.isZero()) break;
        var quot = BigDec.init(alloc);
        defer quot.deinit();
        try quot.div(ax, ypow, p);
        var ny = BigDec.init(alloc);
        defer ny.deinit();
        try ny.mul(nm1, y, 0);
        var sum = BigDec.init(alloc);
        defer sum.deinit();
        try sum.add(ny, quot, p);
        var ynew = BigDec.init(alloc);
        errdefer ynew.deinit();
        try ynew.div(sum, n_bd, p);
        const done = BigDec.cmp(ynew, y) == .eq;
        y.deinit();
        y = ynew;
        ynew = BigDec.init(alloc);
        if (done) break;
    }

    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(y, one, scale);
    if (neg and !out.isZero()) out.neg = true;
    return out;
}

pub fn cbrt(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    var three = try BigDec.fromInt(alloc, 3);
    defer three.deinit();
    return nthRoot(alloc, x, three, scale);
}


const max_bit_len: usize = 1_000_000;

fn requireNonNegInt(x: BigDec) !void {
    if (x.fracDigitCount() != 0 or isNeg(x)) return error.InvalidOperand;
}

fn shiftAmount(b: BigDec) !u32 {
    try requireNonNegInt(b);
    const f = b.toF64() catch return error.InvalidOperand;
    if (!std.math.isFinite(f) or f > max_bit_len or @floor(f) != f) return error.InvalidOperand;
    return @intFromFloat(f);
}

fn toWords(alloc: Allocator, x: BigDec) ![]u32 {
    try requireNonNegInt(x);
    var n = try absOf(alloc, x);
    defer n.deinit();
    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(alloc);
    if (n.isZero()) {
        try words.append(alloc, 0);
        return words.toOwnedSlice(alloc);
    }
    var two32 = try BigDec.fromInt(alloc, 4294967296);
    defer two32.deinit();
    var guard: usize = 0;
    while (!n.isZero()) {
        guard += 1;
        if (guard > max_bit_len / 32 + 1) return error.InvalidOperand;
        var rem = BigDec.init(alloc);
        defer rem.deinit();
        try rem.mod(n, two32, 0);
        const mag = rem.toF64() catch return error.InvalidOperand;
        try words.append(alloc, @intFromFloat(mag));
        var q = BigDec.init(alloc);
        errdefer q.deinit();
        try q.div(n, two32, 0);
        n.deinit();
        n = q;
        q = BigDec.init(alloc);
    }
    return words.toOwnedSlice(alloc);
}

fn fromWords(alloc: Allocator, words: []const u32) !BigDec {
    var acc = try BigDec.fromInt(alloc, 0);
    errdefer acc.deinit();
    if (words.len == 0) return acc;
    var two32 = try BigDec.fromInt(alloc, 4294967296);
    defer two32.deinit();
    var i = words.len;
    while (i > 0) {
        i -= 1;
        var shifted = BigDec.init(alloc);
        errdefer shifted.deinit();
        try shifted.mul(acc, two32, 0);
        var w = try BigDec.fromInt(alloc, words[i]);
        defer w.deinit();
        var next = BigDec.init(alloc);
        errdefer next.deinit();
        try next.add(shifted, w, 0);
        shifted.deinit();
        shifted = BigDec.init(alloc);
        acc.deinit();
        acc = next;
        next = BigDec.init(alloc);
    }
    return acc;
}

const BitOp = enum { and_, or_, xor };

fn bitBin(alloc: Allocator, a: BigDec, b: BigDec, op: BitOp) !BigDec {
    const aw = try toWords(alloc, a);
    defer alloc.free(aw);
    const bw = try toWords(alloc, b);
    defer alloc.free(bw);
    const n = @max(aw.len, bw.len);
    const out = try alloc.alloc(u32, n);
    defer alloc.free(out);
    @memset(out, 0);
    @memcpy(out[0..aw.len], aw);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const wv: u32 = if (i < bw.len) bw[i] else 0;
        out[i] = switch (op) {
            .and_ => out[i] & wv,
            .or_ => out[i] | wv,
            .xor => out[i] ^ wv,
        };
    }
    return fromWords(alloc, out);
}

pub fn band(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    return bitBin(alloc, a, b, .and_);
}

pub fn bor(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    return bitBin(alloc, a, b, .or_);
}

pub fn bxor(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    return bitBin(alloc, a, b, .xor);
}

pub fn bnotWidth(alloc: Allocator, x: BigDec, bits: u16) !BigDec {
    const words = try toWords(alloc, x);
    defer alloc.free(words);
    const nwords: usize = (@as(usize, bits) + 31) / 32;
    const out = try alloc.alloc(u32, nwords);
    defer alloc.free(out);
    @memset(out, 0);
    const copy = @min(words.len, nwords);
    @memcpy(out[0..copy], words[0..copy]);
    for (out) |*w| w.* = ~w.*;
    if (bits % 32 != 0) {
        const rem: u5 = @intCast(bits % 32);
        const mask: u32 = (@as(u32, 1) << rem) - 1;
        out[nwords - 1] &= mask;
    }
    return fromWords(alloc, out);
}

pub fn bshl(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    try requireNonNegInt(a);
    const sh = try shiftAmount(b);
    if (sh == 0) return a.clone(alloc);
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var shift_exp = try BigDec.fromInt(alloc, @as(i64, sh));
    defer shift_exp.deinit();
    var p2 = BigDec.init(alloc);
    defer p2.deinit();
    try p2.pow(two, shift_exp, 0);
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.mul(a, p2, 0);
    return out;
}

pub fn bshr(alloc: Allocator, a: BigDec, b: BigDec) !BigDec {
    try requireNonNegInt(a);
    const sh = try shiftAmount(b);
    if (sh == 0) return a.clone(alloc);
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var shift_exp = try BigDec.fromInt(alloc, @as(i64, sh));
    defer shift_exp.deinit();
    var p2 = BigDec.init(alloc);
    defer p2.deinit();
    try p2.pow(two, shift_exp, 0);
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(a, p2, 0);
    return out;
}

/// tan(x) = sin(x) / cos(x).
pub fn tan(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var s = try sin(alloc, x, p);
    defer s.deinit();
    var c = try cos(alloc, x, p);
    defer c.deinit();
    if (c.isZero()) return error.InvalidOperand;
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(s, c, p);
    return out;
}

/// asin(x) for |x| ≤ 1, via atan(x / sqrt(1 − x²)).
pub fn asin(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var ax = try absOf(alloc, x);
    defer ax.deinit();
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    switch (BigDec.cmp(ax, one)) {
        .gt => return error.InvalidOperand,
        .eq => {
            var half_pi = try pi(alloc, p);
            var two = try BigDec.fromInt(alloc, 2);
            defer two.deinit();
            var out = BigDec.init(alloc);
            errdefer out.deinit();
            try out.div(half_pi, two, p);
            half_pi.deinit();
            if (isNeg(x)) out.neg = true;
            return out;
        },
        .lt => {},
    }
    var xsq = BigDec.init(alloc);
    defer xsq.deinit();
    try xsq.mul(x, x, p);
    var inner = BigDec.init(alloc);
    defer inner.deinit();
    try inner.sub(one, xsq, p);
    var root = BigDec.init(alloc);
    defer root.deinit();
    try root.sqrt(inner, p);
    if (root.isZero()) return error.InvalidOperand;
    var q = BigDec.init(alloc);
    defer q.deinit();
    try q.div(x, root, p);
    return atan(alloc, q, scale);
}

/// acos(x) = π/2 − asin(x).
pub fn acos(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    var ax = try absOf(alloc, x);
    defer ax.deinit();
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    switch (BigDec.cmp(ax, one)) {
        .gt => return error.InvalidOperand,
        .eq => {
            if (!isNeg(x)) return BigDec.fromInt(alloc, 0);
            return pi(alloc, scale);
        },
        .lt => {},
    }

    const p = prec(scale);
    // Pass `scale`, not `p`. asin() already adds guard digits.
    var a = try asin(alloc, x, scale);
    defer a.deinit();
    var half_pi = try pi(alloc, p);
    defer half_pi.deinit();
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var q = BigDec.init(alloc);
    defer q.deinit();
    try q.div(half_pi, two, p);
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.sub(q, a, p);
    if (out.isZero()) out.neg = false;
    return out;
}

/// log base 2.
pub fn log2(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var ln_x = try ln(alloc, x, p);
    defer ln_x.deinit();
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var ln_2 = try ln(alloc, two, p);
    defer ln_2.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(ln_x, ln_2, p);
    return out;
}

/// log base 10.
pub fn log10(alloc: Allocator, x: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var ln_x = try ln(alloc, x, p);
    defer ln_x.deinit();
    var ten = try BigDec.fromInt(alloc, 10);
    defer ten.deinit();
    var ln_10 = try ln(alloc, ten, p);
    defer ln_10.deinit();
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(ln_x, ln_10, p);
    return out;
}

/// log(x, b) = ln(x) / ln(b).
pub fn logBase(alloc: Allocator, x: BigDec, base: BigDec, scale: usize) !BigDec {
    const p = prec(scale);
    var ln_x = try ln(alloc, x, p);
    defer ln_x.deinit();
    var ln_b = try ln(alloc, base, p);
    defer ln_b.deinit();
    if (ln_b.isZero()) return error.InvalidOperand;
    var out = BigDec.init(alloc);
    errdefer out.deinit();
    try out.div(ln_x, ln_b, p);
    return out;
}

test "pi digits" {
    const alloc = std.testing.allocator;
    var p = try pi(alloc, 20);
    defer p.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.format(&w, 10, 20);
    try std.testing.expectEqualStrings("3.14159265358979323846", w.buffered());
}

test "exp ln round trip" {
    const alloc = std.testing.allocator;
    var five = try BigDec.fromInt(alloc, 5);
    defer five.deinit();
    var l = try ln(alloc, five, 10);
    defer l.deinit();
    var e = try exp(alloc, l, 10);
    defer e.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try e.format(&w, 10, 12);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "4.9999999999"));
}

test "sin cos atan" {
    const alloc = std.testing.allocator;
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var s = try sin(alloc, one, 10);
    defer s.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.format(&w, 10, 10);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "0.8414709848"));
}

test "bessel j" {
    const alloc = std.testing.allocator;
    const Case = struct { n: i64, x: []const u8, prefix: []const u8 };

    const cases = [_]Case{
        .{ .n = 0, .x = "0", .prefix = "1" },
        .{ .n = 1, .x = "0", .prefix = "0" },
        .{ .n = 0, .x = "1", .prefix = "0.7651976865" },
        .{ .n = 1, .x = "1", .prefix = "0.4400505857" },
        .{ .n = 2, .x = "1", .prefix = "0.1149034849" },
        .{ .n = 3, .x = "0.75", .prefix = "0.00848438" },
        .{ .n = 0, .x = "-1", .prefix = "0.7651976865" },
        .{ .n = 1, .x = "-1", .prefix = "-0.4400505857" },
        .{ .n = -1, .x = "1", .prefix = "-0.4400505857" },
        .{ .n = -2, .x = "1", .prefix = "0.1149034849" },
    };
    for (cases) |c| {
        var n = try BigDec.fromInt(alloc, c.n);
        defer n.deinit();
        var x = try BigDec.parse(alloc, c.x, 10);
        defer x.deinit();
        var jv = try besselJ(alloc, n, x, 20);
        defer jv.deinit();
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try jv.format(&w, 10, 20);
        try std.testing.expect(std.mem.startsWith(u8, w.buffered(), c.prefix));
    }
}

fn expectFmt(n: BigDec, scale: usize, expected: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try n.format(&w, 10, scale);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "abs ceil floor round gcd lcm factorial" {
    const alloc = std.testing.allocator;

    var neg = try BigDec.parse(alloc, "-3.2", 10);
    defer neg.deinit();
    var a = try abs(alloc, neg);
    defer a.deinit();
    try expectFmt(a, 1, "3.2");

    var f1 = try floor(alloc, neg);
    defer f1.deinit();
    try expectFmt(f1, 0, "-4");
    var c1 = try ceil(alloc, neg);
    defer c1.deinit();
    try expectFmt(c1, 0, "-3");

    var p = try BigDec.parse(alloc, "1.2", 10);
    defer p.deinit();
    var f2 = try floor(alloc, p);
    defer f2.deinit();
    try expectFmt(f2, 0, "1");
    var c2 = try ceil(alloc, p);
    defer c2.deinit();
    try expectFmt(c2, 0, "2");

    var h = try BigDec.parse(alloc, "2.5", 10);
    defer h.deinit();
    var r = try round(alloc, h);
    defer r.deinit();
    try expectFmt(r, 0, "3");
    var hn = try BigDec.parse(alloc, "-2.5", 10);
    defer hn.deinit();
    var rn = try round(alloc, hn);
    defer rn.deinit();
    try expectFmt(rn, 0, "-3");

    var twelve = try BigDec.fromInt(alloc, 12);
    defer twelve.deinit();
    var eighteen = try BigDec.fromInt(alloc, 18);
    defer eighteen.deinit();
    var g = try gcd(alloc, twelve, eighteen);
    defer g.deinit();
    try expectFmt(g, 0, "6");
    var el = try lcm(alloc, twelve, eighteen);
    defer el.deinit();
    try expectFmt(el, 0, "36");

    var ten = try BigDec.fromInt(alloc, 10);
    defer ten.deinit();
    var fact = try factorial(alloc, ten);
    defer fact.deinit();
    try expectFmt(fact, 0, "3628800");
}

test "perm comb max min roundPlaces ceilPlaces root cbrt" {
    const alloc = std.testing.allocator;

    var five = try BigDec.fromInt(alloc, 5);
    defer five.deinit();
    var two = try BigDec.fromInt(alloc, 2);
    defer two.deinit();
    var pe = try perm(alloc, five, two);
    defer pe.deinit();
    try expectFmt(pe, 0, "20");

    var ten = try BigDec.fromInt(alloc, 10);
    defer ten.deinit();
    var three = try BigDec.fromInt(alloc, 3);
    defer three.deinit();
    var co = try comb(alloc, ten, three);
    defer co.deinit();
    try expectFmt(co, 0, "120");

    var neg3 = try BigDec.fromInt(alloc, -3);
    defer neg3.deinit();
    var neg1 = try BigDec.fromInt(alloc, -1);
    defer neg1.deinit();
    var mx = try maxVal(alloc, neg3, neg1);
    defer mx.deinit();
    try expectFmt(mx, 0, "-1");
    var mn = try minVal(alloc, neg3, neg1);
    defer mn.deinit();
    try expectFmt(mn, 0, "-3");

    var x = try BigDec.parse(alloc, "1.231", 10);
    defer x.deinit();
    var rp = try roundPlaces(alloc, x, two);
    defer rp.deinit();
    try expectFmt(rp, 2, "1.23");
    var cp = try ceilPlaces(alloc, x, two);
    defer cp.deinit();
    try expectFmt(cp, 2, "1.24");

    var eight = try BigDec.fromInt(alloc, 8);
    defer eight.deinit();
    var cb = try cbrt(alloc, eight, 0);
    defer cb.deinit();
    try expectFmt(cb, 0, "2");
    var n8 = try BigDec.fromInt(alloc, -8);
    defer n8.deinit();
    var cbn = try cbrt(alloc, n8, 0);
    defer cbn.deinit();
    try expectFmt(cbn, 0, "-2");

    var sixteen = try BigDec.fromInt(alloc, 16);
    defer sixteen.deinit();
    var four = try BigDec.fromInt(alloc, 4);
    defer four.deinit();
    var rt = try nthRoot(alloc, sixteen, four, 0);
    defer rt.deinit();
    try expectFmt(rt, 0, "2");

    var p2 = try pi(alloc, 2);
    defer p2.deinit();
    try expectFmt(p2, 2, "3.14");
}

test "log2 log10 tan asin acos" {
    const alloc = std.testing.allocator;
    var eight = try BigDec.fromInt(alloc, 8);
    defer eight.deinit();
    var l2 = try log2(alloc, eight, 10);
    defer l2.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l2.format(&w, 10, 8);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "3.0000000"));

    var hundred = try BigDec.fromInt(alloc, 100);
    defer hundred.deinit();
    var l10 = try log10(alloc, hundred, 10);
    defer l10.deinit();
    w = .fixed(&buf);
    try l10.format(&w, 10, 8);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "2.0000000"));

    var zero = try BigDec.fromInt(alloc, 0);
    defer zero.deinit();
    var t0 = try tan(alloc, zero, 10);
    defer t0.deinit();
    try expectFmt(t0, 1, "0");

    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var ac = try acos(alloc, one, 10);
    defer ac.deinit();
    try expectFmt(ac, 2, "0");
    var as0 = try asin(alloc, zero, 10);
    defer as0.deinit();
    try expectFmt(as0, 2, "0");
}


test "bitwise band bor bxor bnot shifts" {
    const alloc = std.testing.allocator;
    var twelve = try BigDec.fromInt(alloc, 12);
    defer twelve.deinit();
    var ten = try BigDec.fromInt(alloc, 10);
    defer ten.deinit();
    var a = try band(alloc, twelve, ten);
    defer a.deinit();
    try expectFmt(a, 0, "8");
    var o = try bor(alloc, twelve, ten);
    defer o.deinit();
    try expectFmt(o, 0, "14");
    var x = try bxor(alloc, twelve, ten);
    defer x.deinit();
    try expectFmt(x, 0, "6");

    var zero = try BigDec.fromInt(alloc, 0);
    defer zero.deinit();
    var one = try BigDec.fromInt(alloc, 1);
    defer one.deinit();
    var n8 = try bnotWidth(alloc, zero, 8);
    defer n8.deinit();
    try expectFmt(n8, 0, "255");
    var n8b = try bnotWidth(alloc, one, 8);
    defer n8b.deinit();
    try expectFmt(n8b, 0, "254");
    var n32 = try bnotWidth(alloc, zero, 32);
    defer n32.deinit();
    try expectFmt(n32, 0, "4294967295");

    var eight = try BigDec.fromInt(alloc, 8);
    defer eight.deinit();
    var sh = try bshl(alloc, one, eight);
    defer sh.deinit();
    try expectFmt(sh, 0, "256");
    var two56 = try BigDec.fromInt(alloc, 256);
    defer two56.deinit();
    var rs = try bshr(alloc, two56, eight);
    defer rs.deinit();
    try expectFmt(rs, 0, "1");
}

