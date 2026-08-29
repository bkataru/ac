//! POSIX fixture pack: run tests/posix/*.ac and *.dc through the same
//! path as `ac FILE` / `ac -l FILE` / `ac --rpn FILE`.
const std = @import("std");
const ac = @import("ac");
const Dc = ac.Dc;

const Fixture = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
    mathlib: bool = false,
    rpn: bool = false,
    repl: bool = false,
    echo_assign: bool = false,
    standard: bool = false,
};

const fixtures = [_]Fixture{
    .{ .name = "arith", .source = @embedFile("arith.ac"), .expected = @embedFile("arith.out") },
    .{ .name = "scale", .source = @embedFile("scale.ac"), .expected = @embedFile("scale.out") },
    .{ .name = "obase", .source = @embedFile("obase.ac"), .expected = @embedFile("obase.out") },
    .{ .name = "fact", .source = @embedFile("fact.ac"), .expected = @embedFile("fact.out") },
    .{ .name = "repl_multiline", .source = @embedFile("repl_multiline.ac"), .expected = @embedFile("repl_multiline.out"), .repl = true },
    .{ .name = "mathlib", .source = @embedFile("mathlib.ac"), .expected = @embedFile("mathlib.out"), .mathlib = true },
    .{ .name = "extras", .source = @embedFile("extras.ac"), .expected = @embedFile("extras.out") },
    .{ .name = "extras_mathlib", .source = @embedFile("extras_mathlib.ac"), .expected = @embedFile("extras_mathlib.out"), .mathlib = true },
    .{ .name = "macros", .source = @embedFile("macros.dc"), .expected = @embedFile("macros.out"), .rpn = true },
    .{ .name = "length", .source = @embedFile("length.ac"), .expected = @embedFile("length.out") },
    .{ .name = "arrays", .source = @embedFile("arrays.ac"), .expected = @embedFile("arrays.out") },
    .{ .name = "loops", .source = @embedFile("loops.ac"), .expected = @embedFile("loops.out") },
    .{ .name = "dc_extra", .source = @embedFile("dc_extra.dc"), .expected = @embedFile("dc_extra.out"), .rpn = true },
    .{ .name = "gnu_assign", .source = @embedFile("gnu_assign.ac"), .expected = @embedFile("gnu_assign.out"), .echo_assign = true },
    .{ .name = "standard", .source = @embedFile("standard.ac"), .expected = @embedFile("standard.out"), .standard = true },
};

fn stripCrlf(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c != '\r') try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn runFixture(f: Fixture) !void {
    const allocator = std.testing.allocator;
    var state = ac.State.init(allocator);
    defer state.deinit();
    state.color_enabled = false;
    state.interactive = false;
    if (f.mathlib) {
        state.mathlib_loaded = true;
        state.scale = 20;
    }
    if (f.rpn) state.mode = .rpn;
    if (f.echo_assign) state.echo_assign = true;
    if (f.standard) state.standard = true;

    var dc = Dc.init(&state);
    defer dc.deinit();

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const got_flow = if (f.repl)
        try ac.processReplLines(&state, f.source, &w, &dc)
    else
        try ac.processSource(&state, f.source, &w, &dc);
    _ = got_flow;

    const got = try stripCrlf(allocator, w.buffered());
    defer allocator.free(got);
    const exp = try stripCrlf(allocator, f.expected);
    defer allocator.free(exp);
    std.testing.expectEqualStrings(exp, got) catch |err| {
        std.debug.print("fixture {s}\n--- got ---\n{s}\n--- expected ---\n{s}\n", .{ f.name, got, exp });
        return err;
    };
}

test "posix fixture pack" {
    for (fixtures) |f| {
        try runFixture(f);
    }
}
