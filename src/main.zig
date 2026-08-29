//! ac - A Calculator
//! A modern reimagining of the classic UNIX bc/dc calculators
//!
//! Zig 0.16.0

const std = @import("std");
const Lexer = @import("lex.zig").Lexer;
const Parser = @import("parse.zig").Parser;
const Evaluator = @import("eval.zig").Evaluator;
const BigDec = @import("num.zig").BigDec;
pub const Dc = @import("dc.zig").Dc;
const FunctionDef = @import("eval.zig").FunctionDef;
const Stmt = @import("parse.zig").Stmt;
const Expr = @import("parse.zig").Expr;

pub const version = "0.1.0";

const max_source_bytes: usize = 16 * 1024 * 1024;

pub const Mode = enum {
    infix,
    rpn,
};

/// ANSI color codes for terminal output
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";

    // Prompt colors
    pub const prompt = "\x1b[32m"; // green
    pub const prompt_rpn = "\x1b[36m"; // cyan

    // Output colors
    pub const number = "\x1b[33m"; // yellow
    pub const number_neg = "\x1b[31m"; // red for negative
    pub const operator = "\x1b[35m"; // magenta
    pub const err = "\x1b[31;1m"; // bold red
    pub const keyword = "\x1b[34;1m"; // bold blue
    pub const comment = "\x1b[90m"; // gray
};

/// Runtime state for the calculator
pub const State = struct {
    allocator: std.mem.Allocator,
    /// Stdin reader for the read() builtin (set once in main).
    stdin_reader: ?*std.Io.Reader = null,
    mode: Mode = .infix,
    scale: usize = 0,
    ibase: u8 = 10,
    obase: u8 = 10,
    last: ?BigDec = null,
    variables: std.StringHashMap(@import("eval.zig").Value),
    arrays: std.StringHashMap([]@import("eval.zig").Value),
    functions: std.StringHashMap(FunctionDef),
    color_enabled: bool = true,
    interactive: bool = true,
    mathlib_loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap(@import("eval.zig").Value).init(allocator),
            .arrays = std.StringHashMap([]@import("eval.zig").Value).init(allocator),
            .functions = std.StringHashMap(FunctionDef).init(allocator),
            .mathlib_loaded = false,
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.variables.deinit();
        var ait = self.arrays.iterator();
        while (ait.next()) |entry| {
            for (entry.value_ptr.*) |*v| v.deinit(self.allocator);
            if (entry.value_ptr.len > 0) self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.arrays.deinit();
        var fit = self.functions.iterator();
        while (fit.next()) |entry| {
            // value.name and the map key share one allocation; free once.
            entry.value_ptr.body.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.body);
            for (entry.value_ptr.params) |ps| self.allocator.free(ps.name);
            if (entry.value_ptr.params.len > 0) self.allocator.free(entry.value_ptr.params);
            for (entry.value_ptr.auto_vars) |av| {
                self.allocator.free(av.name);
                if (av.size) |sz| {
                    sz.deinit(self.allocator);
                    self.allocator.destroy(sz);
                }
            }
            if (entry.value_ptr.auto_vars.len > 0) self.allocator.free(entry.value_ptr.auto_vars);
            self.allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();
        if (self.last) |*last| {
            last.deinit();
        }
    }
};

/// Human-readable text for an error. Falls back to the Zig error name.
fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ExpectedExpression => "expected an expression",
        error.ExpectedLeftParen => "expected '('",
        error.ExpectedRightParen => "expected ')'",
        error.UndefinedVariable => "undefined variable",
        error.UndefinedFunction => "undefined function",
        error.WrongArgCount => "wrong number of arguments",
        error.InvalidAssignment => "invalid assignment target",
        error.InvalidBreak => "break outside a loop",
        error.InvalidContinue => "continue outside a loop",
        error.InvalidReturn => "return outside a function",
        error.DivisionByZero => "division by zero",
        error.NegativeSquareRoot => "square root of a negative number",
        error.NonIntegerExponent => "exponent must be an integer",
        error.InternalDivisionOverflow => "internal division overflow",
        error.InvalidOperand => "invalid operand",
        error.InvalidBase => "invalid base",
        error.StackEmpty => "stack is empty",
        error.UnexpectedToken => "unexpected token",
        error.WriteFailed => "write failed",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn printError(state: *State, stdout: anytype, err: anyerror) !void {
    if (state.color_enabled) {
        try stdout.print("{s}Error: {s}{s}\n", .{ Color.err, errorMessage(err), Color.reset });
    } else {
        try stdout.print("Error: {s}\n", .{errorMessage(err)});
    }
}

/// Print a diagnostic with a caret pointing at `col` (1-based) under
/// the offending source line.
fn printErrorCaret(state: *State, stdout: anytype, err: anyerror, source_line: []const u8, col: u32) !void {
    if (state.color_enabled) {
        try stdout.print("{s}Error: {s}{s}\n", .{ Color.err, errorMessage(err), Color.reset });
    } else {
        try stdout.print("Error: {s}\n", .{errorMessage(err)});
    }
    try stdout.writeAll(source_line);
    try stdout.writeAll("\n");
    var i: u32 = 1;
    while (i < col and i < 4096) : (i += 1) try stdout.writeByte(' ');
    if (state.color_enabled) try stdout.writeAll(Color.err);
    try stdout.writeAll("^");
    if (state.color_enabled) try stdout.writeAll(Color.reset);
    try stdout.writeAll("\n");
}

/// Skip newline/semicolon tokens. Mirrors Parser.skipTerminators via public fields.
fn skipParserTerminators(parser: *Parser) void {
    while (parser.current.kind == .newline or parser.current.kind == .semicolon) {
        parser.previous = parser.current;
        parser.current = parser.lexer.next();
    }
}

fn sourceLineAt(source: []const u8, line_no: u32) []const u8 {
    var n: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (n == line_no) {
                var end = i;
                if (end > start and source[end - 1] == '\r') end -= 1;
                return source[start..end];
            }
            n += 1;
            start = i + 1;
        }
    }
    if (n == line_no) {
        var end = source.len;
        if (end > start and source[end - 1] == '\r') end -= 1;
        return source[start..end];
    }
    return source;
}

/// Evaluate/execute one already-parsed statement (echo expr values).
fn runStatement(
    state: *State,
    stmt: *Stmt,
    stdout: *std.Io.Writer,
) !bool {
    // func_def transfers body/params/autos into state.functions; the
    // wrapper node itself is always destroyed here, and the union tag is
    // neutralized by execute() so no double free occurs.
    var consumed = false;
    defer {
        if (!consumed) stmt.deinit(state.allocator);
        state.allocator.destroy(stmt);
    }

    var evaluator = Evaluator.init(state);
    defer evaluator.deinit();
    evaluator.func_stdout = stdout;

    // Expression statements echo their value unless they are assignments.
    // POSIX bc does not print `x = 3`; GNU bc does as an extension.
    if (stmt.* == .expr) {
        const silent = isAssignmentExpr(stmt.expr);
        var result = evaluator.evaluate(stmt.expr) catch |err| {
            try printError(state, stdout, err);
            return true;
        };
        defer result.deinit(state.allocator);

        if (!silent) {
            switch (result) {
                .num => |*n| {
                    if (state.color_enabled) {
                        if (n.isNegative()) {
                            try stdout.writeAll(Color.number_neg);
                        } else {
                            try stdout.writeAll(Color.number);
                        }
                    }
                    try n.format(stdout, state.obase, state.scale);
                    if (state.color_enabled) {
                        try stdout.writeAll(Color.reset);
                    }
                    try stdout.writeAll("\n");
                    if (state.last) |*last| {
                        last.deinit();
                    }
                    state.last = try n.clone(state.allocator);
                },
                .str => |s| try stdout.writeAll(s),
            }
        }

        // The echo block already evaluated and printed this expression;
        // free its tree and neutralize the stmt so execute() doesn't
        // evaluate (and double-consume read() input) a second time.
        stmt.expr.deinit(state.allocator);
        state.allocator.destroy(stmt.expr);
        stmt.* = .noop;
    }
    const flow = evaluator.execute(stmt, stdout, 0, &consumed) catch |err| {
        try printError(state, stdout, err);
        return true;
    };
    switch (flow) {
        .quit => return false,
        .halt => return false,
        .ret => |maybe_v| {
            // Return outside a function: free the payload, report it.
            if (maybe_v) |v| {
                var vv = v;
                vv.deinit(state.allocator);
            }
            try printError(state, stdout, error.InvalidReturn);
            return true;
        },
        else => {},
    }

    return true;
}

/// Process a full source buffer (file, -e, or one REPL line after meta cmds).
pub fn processSource(
    state: *State,
    source: []const u8,
    stdout: *std.Io.Writer,
    dc: *Dc,
) !bool {
    if (state.mode == .rpn) {
        return dc.processLine(source, stdout) catch |err| {
            try printError(state, stdout, err);
            return true;
        };
    }

    var lexer = Lexer.init(source);
    var parser = Parser.init(&lexer, state.allocator);
    parser.ibase = state.ibase;
    parser.parse_scale = state.scale + 2;
    defer parser.deinit();

    while (true) {
        skipParserTerminators(&parser);
        if (parser.current.kind == .eof) break;

        const maybe_stmt = parser.parseTopLevel() catch |err| {
            if (parser.err_column > 0) {
                try printErrorCaret(state, stdout, err, sourceLineAt(source, parser.current.line), parser.err_column);
            } else {
                try printError(state, stdout, err);
            }
            return true;
        };

        const stmt = maybe_stmt orelse break;
        if (!try runStatement(state, stmt, stdout)) return false;
    }

    return true;
}

fn processFile(
    state: *State,
    io: std.Io,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    dc: *Dc,
) !bool {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, state.allocator, .limited(max_source_bytes)) catch |err| {
        try stderr.print("ac: {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer state.allocator.free(src);
    return processSource(state, src, stdout, dc);
}

fn processStdinBuffer(
    state: *State,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    dc: *Dc,
) !bool {
    const src = stdin.allocRemaining(state.allocator, .limited(max_source_bytes)) catch |err| {
        try stderr.print("ac: stdin: {s}\n", .{@errorName(err)});
        return err;
    };
    defer state.allocator.free(src);
    return processSource(state, src, stdout, dc);
}

/// Process a single REPL line of input.
fn processLine(
    state: *State,
    line: []const u8,
    stdout: *std.Io.Writer,
    dc: *Dc,
) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    if (trimmed.len == 0) return true;

    // Meta commands apply only to REPL lines, not files or -e buffers.
    if (trimmed[0] == ':') {
        return try handleCommand(state, trimmed, stdout);
    }

    return processSource(state, trimmed, stdout, dc);
}

/// Handle meta commands (starting with ':')
fn handleCommand(
    state: *State,
    cmd: []const u8,
    stdout: anytype,
) !bool {
    if (std.mem.eql(u8, cmd, ":quit") or std.mem.eql(u8, cmd, ":q")) {
        return false;
    }
    if (std.mem.eql(u8, cmd, ":rpn") or std.mem.eql(u8, cmd, ":dc")) {
        state.mode = .rpn;
        try stdout.writeAll("Switched to RPN mode\n");
        return true;
    }
    if (std.mem.eql(u8, cmd, ":infix") or std.mem.eql(u8, cmd, ":bc")) {
        state.mode = .infix;
        try stdout.writeAll("Switched to infix mode\n");
        return true;
    }
    if (std.mem.eql(u8, cmd, ":help") or std.mem.eql(u8, cmd, ":h") or std.mem.eql(u8, cmd, ":?")) {
        try printHelp(stdout, state.color_enabled);
        return true;
    }
    if (std.mem.eql(u8, cmd, ":vars")) {
        try printVariables(state, stdout);
        return true;
    }
    if (std.mem.eql(u8, cmd, ":clear")) {
        try stdout.writeAll("\x1b[2J\x1b[H");
        return true;
    }

    if (state.color_enabled) {
        try stdout.print("{s}Unknown command: {s}{s}\n", .{ Color.err, cmd, Color.reset });
    } else {
        try stdout.print("Unknown command: {s}\n", .{cmd});
    }
    return true;
}

fn printHelp(stdout: anytype, color: bool) !void {
    const c = if (color) Color.keyword else "";
    const r = if (color) Color.reset else "";

    try stdout.print(
        \\{s}ac{s} - A Calculator (v{s})
        \\
        \\{s}Usage:{s}
        \\  ac [OPTIONS] [FILE...]
        \\
        \\{s}Options:{s}
        \\  -h, --help              Show this help
        \\  -v, --version           Show version
        \\  -l, --mathlib           Load math library (scale=20)
        \\  -q, --quiet             Suppress the startup banner
        \\  -e, --expression EXPR   Evaluate EXPR
        \\  --rpn                   Start in RPN (dc) mode
        \\  --infix                 Start in infix (bc) mode
        \\  --no-color              Disable colored output
        \\
        \\  FILES are processed in order; `-` means stdin.
        \\
        \\{s}Commands:{s}
        \\  :help, :h, :?    Show this help
        \\  :quit, :q        Exit
        \\  :rpn, :dc        Switch to RPN (dc) mode
        \\  :infix, :bc      Switch to infix (bc) mode
        \\  :vars            Show all variables
        \\  :clear           Clear screen
        \\
        \\{s}Operators:{s}
        \\  + - * / %        Arithmetic
        \\  ^                 Power
        \\  ( )               Grouping
        \\
        \\{s}Built-in:{s}
        \\  scale             Decimal places (default: 0)
        \\  ibase             Input base (default: 10)
        \\  obase             Output base (default: 10)
        \\  sqrt(x)           Square root
        \\
    , .{ c, r, version, c, r, c, r, c, r, c, r, c, r });
}

fn printVariables(state: *State, stdout: anytype) !void {
    try stdout.print("scale = {d}\n", .{state.scale});
    try stdout.print("ibase = {d}\n", .{state.ibase});
    try stdout.print("obase = {d}\n", .{state.obase});

    if (state.last) |last| {
        try stdout.writeAll("last = ");
        try last.format(stdout, state.obase, state.scale);
        try stdout.writeAll("\n");
    }

    var it = state.variables.iterator();
    while (it.next()) |entry| {
        try stdout.print("{s} = ", .{entry.key_ptr.*});
        switch (entry.value_ptr.*) {
            .num => |*n| try n.format(stdout, state.obase, state.scale),
            .str => |s| try stdout.writeAll(s),
        }
        try stdout.writeAll("\n");
    }
}

const CliAction = union(enum) {
    expression: []u8,
    file: []u8,
    stdin,
};

/// Read one physical line into buf (through LF, CR dropped so CRLF and
/// LF input behave the same). Returns the byte count; sets `eof_out`
/// when the stream ended (a partial final line still counts).
fn readPhysicalLine(
    stdin: *std.Io.Reader,
    buf: []u8,
    eof_out: *bool,
    stderr: *std.Io.Writer,
) usize {
    var n: usize = 0;
    while (true) {
        const ch = stdin.takeByte() catch |err| {
            if (err != error.EndOfStream) {
                stderr.print("Read error: {s}\n", .{@errorName(err)}) catch {};
                stderr.flush() catch {};
            } else {
                eof_out.* = true;
            }
            break;
        };
        if (ch == '\r') continue;
        if (ch == '\n') break;
        if (n < buf.len) {
            buf[n] = ch;
            n += 1;
        }
    }
    return n;
}

/// Read one logical line: a physical line spliced with the next one when
/// it ends with a backslash (bc-style). Chained backslashes splice again.
fn readInputLine(
    stdin: *std.Io.Reader,
    buf: []u8,
    eof_out: *bool,
    stderr: *std.Io.Writer,
) usize {
    var line_len = readPhysicalLine(stdin, buf, eof_out, stderr);
    while (line_len >= 1 and buf[line_len - 1] == '\\' and !eof_out.*) {
        line_len -= 1; // drop the backslash
        const part = readPhysicalLine(stdin, buf[line_len..], eof_out, stderr);
        line_len += part;
        if (eof_out.* and part == 0) break;
    }
    return line_len;
}

/// Net { } depth of a source fragment. Ignores braces inside block
/// comments, line comments, and dc-style [ ... ] strings, mirroring the
/// lexer (lex.zig string/blockComment/lineComment).
fn netBraceDepth(src: []const u8) i32 {
    var depth: i32 = 0;
    var bracket: i32 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (bracket > 0) {
            // Inside a dc [ ... ] string: only nesting brackets matter.
            if (ch == '[') bracket += 1;
            if (ch == ']') bracket -= 1;
            continue;
        }
        switch (ch) {
            '/' => {
                if (i + 1 < src.len and src[i + 1] == '*') {
                    // Block comment: skip past the closing */.
                    i += 2;
                    while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
                    if (i + 1 < src.len) i += 1;
                }
            },
            '#' => {
                // Line comment: skip to the end of the line.
                while (i < src.len and src[i] != '\n') : (i += 1) {}
            },
            '[' => bracket += 1,
            ']' => bracket -= 1,
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

/// True when `expr` is a (possibly compound) assignment. POSIX bc
/// evaluates these as statements but does not print the stored value.
fn isAssignmentExpr(expr: *const Expr) bool {
    return switch (expr.*) {
        .binary => |b| switch (b.op) {
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign, .pow_assign => true,
            else => false,
        },
        else => false,
    };
}

/// Process source the same way the REPL does: splice trailing `\`,
/// join lines while braces stay open, then run each complete chunk.
pub fn processReplLines(
    state: *State,
    source: []const u8,
    stdout: *std.Io.Writer,
    dc: *Dc,
) !bool {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(state.allocator);
    var logical: std.ArrayList(u8) = .empty;
    defer logical.deinit(state.allocator);

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        var phys = raw;
        if (phys.len > 0 and phys[phys.len - 1] == '\r') {
            phys = phys[0 .. phys.len - 1];
        }
        try logical.appendSlice(state.allocator, phys);
        if (logical.items.len >= 1 and logical.items[logical.items.len - 1] == '\\') {
            logical.items.len -= 1;
            continue;
        }
        if (acc.items.len > 0) try acc.append(state.allocator, '\n');
        try acc.appendSlice(state.allocator, logical.items);
        logical.clearRetainingCapacity();
        if (state.mode == .infix and netBraceDepth(acc.items) > 0) continue;
        const keep = try processLine(state, acc.items, stdout, dc);
        acc.clearRetainingCapacity();
        if (!keep) return false;
    }
    if (logical.items.len > 0) {
        if (acc.items.len > 0) try acc.append(state.allocator, '\n');
        try acc.appendSlice(state.allocator, logical.items);
    }
    if (acc.items.len > 0) return processLine(state, acc.items, stdout, dc);
    return true;
}

fn runRepl(
    state: *State,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdin_reader: *std.Io.File.Reader,
    dc: *Dc,
) !void {
    const stdin = &stdin_reader.interface;
    while (true) {
        if (state.interactive) {
            const prompt_color = if (state.mode == .infix) Color.prompt else Color.prompt_rpn;
            const prompt_text = if (state.mode == .infix) "ac" else "dc";
            if (state.color_enabled) {
                try stdout.print("{s}{s}>{s} ", .{ prompt_color, prompt_text, Color.reset });
            } else {
                try stdout.print("{s}> ", .{prompt_text});
            }
            try stdout.flush();
        }

        // Read one logical line (spliced on trailing backslashes).
        var line_buf: [4096]u8 = undefined;
        var hit_eof = false;
        const line_len = readInputLine(stdin, &line_buf, &hit_eof, stderr);

        // Multiline defines: accumulate lines while braces stay unbalanced.
        // dc mode has no brace syntax, so no accumulation there.
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(state.allocator);
        try acc.appendSlice(state.allocator, line_buf[0..line_len]);
        var aborted = false;
        while (state.mode == .infix and netBraceDepth(acc.items) > 0) {
            if (state.interactive) {
                if (state.color_enabled) {
                    try stdout.print("{s}..>{s} ", .{ Color.prompt, Color.reset });
                } else {
                    try stdout.writeAll("..> ");
                }
                try stdout.flush();
            }
            var cont_buf: [4096]u8 = undefined;
            var cont_eof = false;
            const cont_len = readInputLine(stdin, &cont_buf, &cont_eof, stderr);
            if (cont_len == 0 and cont_eof) {
                // Stream ended mid-define: discard and exit.
                acc.clearRetainingCapacity();
                hit_eof = true;
                break;
            }
            const cont_line = cont_buf[0..cont_len];
            const cont_trimmed = std.mem.trim(u8, cont_line, " \t");
            if (cont_trimmed.len > 0 and cont_trimmed[0] == ':') {
                // Meta command while defining: discard the partial define
                // and run the command on its own.
                acc.clearRetainingCapacity();
                aborted = true;
                var keep = true;
                if (processLine(state, cont_line, stdout, dc)) |k| {
                    keep = k;
                } else |err| {
                    try stderr.print("Error: {s}\n", .{errorMessage(err)});
                    try stderr.flush();
                }
                try stdout.flush();
                if (!keep) return;
                break;
            }
            if (acc.items.len + cont_len + 1 > max_source_bytes) {
                try stderr.writeAll("Error: input too long\n");
                try stderr.flush();
                acc.clearRetainingCapacity();
                aborted = true;
                break;
            }
            try acc.append(state.allocator, '\n');
            try acc.appendSlice(state.allocator, cont_line);
        }
        if (hit_eof and acc.items.len == 0) break;

        const continue_loop = if (aborted) true else processLine(state, acc.items, stdout, dc) catch |err| {
            try stderr.print("Error: {s}\n", .{errorMessage(err)});
            try stderr.flush();
            continue;
        };

        try stdout.flush();

        if (!continue_loop) break;
    }

    if (state.interactive) {
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var state = State.init(allocator);
    defer state.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_file_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stdout = &stdout_file_writer.interface;
    const stderr = &stderr_file_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    state.interactive = try std.Io.File.stdin().isTty(io);
    state.color_enabled = state.interactive;

    var quiet = false;
    var actions: std.ArrayList(CliAction) = .empty;
    defer {
        for (actions.items) |a| switch (a) {
            .expression, .file => |s| allocator.free(s),
            .stdin => {},
        };
        actions.deinit(allocator);
    }

    {
        var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer arg_iter.deinit();
        _ = arg_iter.next(); // program name
        while (arg_iter.next()) |arg| {
            if (arg.len == 0) continue;

            if (std.mem.eql(u8, arg, "-")) {
                try actions.append(allocator, .stdin);
                continue;
            }

            if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    try printHelp(stdout, state.color_enabled);
                    return;
                } else if (std.mem.eql(u8, arg, "--version")) {
                    try stdout.print("ac {s}\n", .{version});
                    return;
                } else if (std.mem.eql(u8, arg, "--quiet")) {
                    quiet = true;
                } else if (std.mem.eql(u8, arg, "--mathlib")) {
                    state.mathlib_loaded = true;
                    state.scale = 20;
                } else if (std.mem.eql(u8, arg, "--rpn")) {
                    state.mode = .rpn;
                } else if (std.mem.eql(u8, arg, "--infix")) {
                    state.mode = .infix;
                } else if (std.mem.eql(u8, arg, "--no-color")) {
                    state.color_enabled = false;
                } else if (std.mem.eql(u8, arg, "--expression")) {
                    const expr = arg_iter.next() orelse {
                        try stderr.print("ac: option requires an argument: --expression\n", .{});
                        return error.MissingArgument;
                    };
                    try actions.append(allocator, .{ .expression = try allocator.dupe(u8, expr) });
                } else {
                    try stderr.print("ac: unknown option: {s}\n", .{arg});
                    return error.UnknownOption;
                }
                continue;
            }

            if (arg[0] == '-') {
                var i: usize = 1;
                while (i < arg.len) : (i += 1) {
                    switch (arg[i]) {
                        'h' => {
                            try printHelp(stdout, state.color_enabled);
                            return;
                        },
                        'v' => {
                            try stdout.print("ac {s}\n", .{version});
                            return;
                        },
                        'q' => quiet = true,
                        'l' => {
                            state.mathlib_loaded = true;
                            state.scale = 20;
                        },
                        'e' => {
                            const rest = arg[i + 1 ..];
                            const expr: []const u8 = if (rest.len > 0)
                                rest
                            else
                                arg_iter.next() orelse {
                                    try stderr.print("ac: option requires an argument: -e\n", .{});
                                    return error.MissingArgument;
                                };
                            try actions.append(allocator, .{ .expression = try allocator.dupe(u8, expr) });
                            break;
                        },
                        else => {
                            try stderr.print("ac: unknown option: -{c}\n", .{arg[i]});
                            return error.UnknownOption;
                        },
                    }
                }
                continue;
            }

            try actions.append(allocator, .{ .file = try allocator.dupe(u8, arg) });
        }
    }

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var dc = Dc.init(&state);
    defer dc.deinit();
    state.stdin_reader = &stdin_reader.interface;

    const had_actions = actions.items.len > 0;
    var had_file = false;
    var stop_repl = false;
    for (actions.items) |action| {
        switch (action) {
            .file, .stdin => had_file = true,
            .expression => {},
        }
        const keep = switch (action) {
            .expression => |expr| try processSource(&state, expr, stdout, &dc),
            .file => |path| try processFile(&state, io, path, stdout, stderr, &dc),
            .stdin => try processStdinBuffer(&state, &stdin_reader.interface, stdout, stderr, &dc),
        };
        try stdout.flush();
        if (!keep) {
            stop_repl = true;
            break;
        }
    }

    // Bare `ac`: always REPL (pipe or tty). Files: REPL if stdin is a tty.
    // Pure -e: do not enter REPL (so `ac -e '1+2'` prints and exits).
    const enter_repl = if (stop_repl) false else if (!had_actions) true else (had_file and state.interactive);

    if (!enter_repl) return;

    if (state.interactive and !quiet and !had_actions) {
        if (state.color_enabled) {
            try stdout.print("{s}{s}ac{s} v{s} - A Calculator\n", .{ Color.bold, Color.keyword, Color.reset, version });
            try stdout.print("{s}Type :help for help, :quit to exit{s}\n\n", .{ Color.comment, Color.reset });
        } else {
            try stdout.print("ac v{s} - A Calculator\n", .{version});
            try stdout.writeAll("Type :help for help, :quit to exit\n\n");
        }
        try stdout.flush();
    }

    try runRepl(&state, stdout, stderr, &stdin_reader, &dc);
}

test "basic sanity" {
    _ = @import("num.zig");
    _ = @import("lex.zig");
    _ = @import("parse.zig");
    _ = @import("eval.zig");
    _ = @import("mathlib.zig");
    _ = @import("dc.zig");
}

test "brace depth scanner" {
    try std.testing.expectEqual(@as(i32, 1), netBraceDepth("define f() {"));
    try std.testing.expectEqual(@as(i32, -1), netBraceDepth("x }"));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth("{ }"));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth("/* { */"));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth("# { tail"));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth("[{,}]"));
    try std.testing.expectEqual(@as(i32, 1), netBraceDepth("[2 3 +] { "));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth(""));
    try std.testing.expectEqual(@as(i32, 1), netBraceDepth("a[0] = {"));
    try std.testing.expectEqual(@as(i32, 0), netBraceDepth("{ /* } */ }"));
}
