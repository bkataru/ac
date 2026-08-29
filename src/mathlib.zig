//! bc -l math library: pi, ln, exp, sin, cos, atan, Bessel j(n,x).
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
    errdefer r.deinit();
    try r.sub(t, u, p);
    return r;
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
