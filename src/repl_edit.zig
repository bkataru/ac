//! Interactive line editor: arrows, backspace, and a history file.
//!
//! Falls back to cooked stdin when the TTY cannot enter raw mode.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;

const max_history: usize = 1000;
const max_history_bytes: usize = 1 * 1024 * 1024;

pub const Editor = struct {
    allocator: Allocator,
    lines: std.ArrayList([]u8) = .empty,
    raw: bool = false,
    posix_orig: if (builtin.os.tag == .windows) void else std.posix.termios = if (builtin.os.tag == .windows) {} else undefined,
    win_orig: u32 = 0,
    stdin_file: ?File = null,
    io: ?Io = null,
    extra_words: std.ArrayList([]const u8) = .empty,
    mathlib: bool = false,
    color: bool = true,

    pub fn init(allocator: Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.disableRaw();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.extra_words.deinit(self.allocator);
    }

    pub fn clearExtra(self: *Editor) void {
        self.extra_words.clearRetainingCapacity();
    }

    pub fn addExtra(self: *Editor, word: []const u8) !void {
        try self.extra_words.append(self.allocator, word);
    }

    pub fn add(self: *Editor, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.lines.items.len > 0 and std.mem.eql(u8, self.lines.items[self.lines.items.len - 1], trimmed)) {
            return;
        }
        const copy = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(copy);
        try self.lines.append(self.allocator, copy);
        while (self.lines.items.len > max_history) {
            self.allocator.free(self.lines.orderedRemove(0));
        }
    }

    pub fn load(self: *Editor, io: Io, path: []const u8) void {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_history_bytes)) catch return;
        defer self.allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.add(line) catch {};
        }
    }

    pub fn save(self: *Editor, io: Io, path: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (self.lines.items) |line| {
            buf.appendSlice(self.allocator, line) catch return;
            buf.append(self.allocator, '\n') catch return;
        }
        var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer file.close(io);
        file.writeStreamingAll(io, buf.items) catch {};
    }

    pub fn enableRaw(self: *Editor, io: Io, stdin_file: File) void {
        self.io = io;
        self.stdin_file = stdin_file;
        if (comptime builtin.os.tag == .windows) {
            self.enableRawWindows(io, stdin_file);
        } else {
            self.enableRawPosix();
        }
    }

    pub fn disableRaw(self: *Editor) void {
        if (!self.raw) return;
        if (comptime builtin.os.tag == .windows) {
            self.disableRawWindows();
        } else {
            self.disableRawPosix();
        }
        self.raw = false;
    }

    fn enableRawPosix(self: *Editor) void {
        if (comptime builtin.os.tag == .windows) return;
        const fd = (self.stdin_file orelse return).handle;
        const orig = std.posix.tcgetattr(fd) catch return;
        self.posix_orig = orig;
        var raw_term = orig;
        raw_term.lflag.ECHO = false;
        raw_term.lflag.ICANON = false;
        raw_term.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw_term.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(fd, .NOW, raw_term) catch return;
        self.raw = true;
    }

    fn disableRawPosix(self: *Editor) void {
        if (comptime builtin.os.tag == .windows) return;
        std.posix.tcsetattr((self.stdin_file orelse return).handle, .NOW, self.posix_orig) catch {};
    }

    fn enableRawWindows(self: *Editor, io: Io, stdin_file: File) void {
        if (comptime builtin.os.tag != .windows) return;
        const windows = std.os.windows;
        const ENABLE_LINE_INPUT: u32 = 0x0002;
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
        var get = windows.CONSOLE.USER_IO.GET_MODE;
        switch (get.operate(io, stdin_file) catch return) {
            .SUCCESS => {},
            else => return,
        }
        self.win_orig = get.Data;
        var mode = get.Data;
        mode &= ~ENABLE_LINE_INPUT;
        mode &= ~ENABLE_ECHO_INPUT;
        mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        var set = windows.CONSOLE.USER_IO.SET_MODE(mode);
        switch (set.operate(io, stdin_file) catch return) {
            .SUCCESS => self.raw = true,
            else => {},
        }
    }

    fn disableRawWindows(self: *Editor) void {
        if (comptime builtin.os.tag != .windows) return;
        const windows = std.os.windows;
        const io = self.io orelse return;
        var set = windows.CONSOLE.USER_IO.SET_MODE(self.win_orig);
        _ = set.operate(io, self.stdin_file orelse return) catch {};
    }

    /// Read one physical line. Prints `prompt`. Sets `eof_out` at stream end.
    /// Returns the byte count copied into `buf`.
    pub fn readLine(
        self: *Editor,
        stdin: *std.Io.Reader,
        stdout: *std.Io.Writer,
        prompt: []const u8,
        buf: []u8,
        eof_out: *bool,
        stderr: *std.Io.Writer,
    ) usize {
        if (!self.raw) {
            stdout.writeAll(prompt) catch {};
            stdout.flush() catch {};
            return readCooked(stdin, buf, eof_out, stderr);
        }
        return self.readLineRaw(stdin, stdout, prompt, buf, eof_out);
    }

    fn readLineRaw(
        self: *Editor,
        stdin: *std.Io.Reader,
        stdout: *std.Io.Writer,
        prompt: []const u8,
        buf: []u8,
        eof_out: *bool,
    ) usize {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        var cursor: usize = 0;
        var hist_pos: usize = self.lines.items.len;
        var saved_draft: ?[]u8 = null;
        defer if (saved_draft) |s| self.allocator.free(s);

        stdout.writeAll(prompt) catch {};
        stdout.flush() catch {};

        while (true) {
            const ch = stdin.takeByte() catch {
                eof_out.* = true;
                break;
            };
            switch (ch) {
                '\n', '\r' => {
                    stdout.writeAll("\r\n") catch {};
                    stdout.flush() catch {};
                    self.add(line.items) catch {};
                    const n = @min(line.items.len, buf.len);
                    @memcpy(buf[0..n], line.items[0..n]);
                    return n;
                },
                0x04 => { // Ctrl-D
                    if (line.items.len == 0) {
                        eof_out.* = true;
                        stdout.writeAll("\r\n") catch {};
                        stdout.flush() catch {};
                        return 0;
                    }
                },
                0x03 => { // Ctrl-C: drop the line
                    line.clearRetainingCapacity();
                    cursor = 0;
                    hist_pos = self.lines.items.len;
                    self.redraw(stdout, prompt, line.items, cursor);
                },
                0x7f, 0x08 => { // Backspace
                    if (cursor > 0) {
                        _ = line.orderedRemove(cursor - 1);
                        cursor -= 1;
                        self.redraw(stdout, prompt, line.items, cursor);
                    }
                },
                0x01 => { // Ctrl-A
                    cursor = 0;
                    self.redraw(stdout, prompt, line.items, cursor);
                },
                0x05 => { // Ctrl-E
                    cursor = line.items.len;
                    self.redraw(stdout, prompt, line.items, cursor);
                },
                0x0b => { // Ctrl-K
                    line.shrinkRetainingCapacity(cursor);
                    self.redraw(stdout, prompt, line.items, cursor);
                },
                0x15 => { // Ctrl-U
                    line.clearRetainingCapacity();
                    cursor = 0;
                    self.redraw(stdout, prompt, line.items, cursor);
                },
                '\t' => {
                    self.completeToken(&line, &cursor, stdout, prompt);
                },
                0x1b => {
                    const n1 = stdin.takeByte() catch continue;
                    if (n1 == '[') {
                        const n2 = stdin.takeByte() catch continue;
                        self.handleArrow(n2, &line, &cursor, &hist_pos, &saved_draft);
                        self.redraw(stdout, prompt, line.items, cursor);
                    } else if (n1 == 'O') {
                        _ = stdin.takeByte() catch {};
                    }
                },
                0xe0, 0x00 => { // Windows scan prefix
                    const n2 = stdin.takeByte() catch continue;
                    const mapped: u8 = switch (n2) {
                        0x48 => 'A',
                        0x50 => 'B',
                        0x4d => 'C',
                        0x4b => 'D',
                        else => 0,
                    };
                    if (mapped != 0) {
                        self.handleArrow(mapped, &line, &cursor, &hist_pos, &saved_draft);
                        self.redraw(stdout, prompt, line.items, cursor);
                    }
                },
                else => {
                    if (ch >= 32 and line.items.len < buf.len) {
                        line.insert(self.allocator, cursor, ch) catch continue;
                        cursor += 1;
                        self.redraw(stdout, prompt, line.items, cursor);
                    }
                },
            }
        }
        const n = @min(line.items.len, buf.len);
        if (n > 0) @memcpy(buf[0..n], line.items[0..n]);
        return n;
    }

    fn handleArrow(
        self: *Editor,
        code: u8,
        line: *std.ArrayList(u8),
        cursor: *usize,
        hist_pos: *usize,
        saved_draft: *?[]u8,
    ) void {
        switch (code) {
            'A' => { // up
                if (self.lines.items.len == 0 or hist_pos.* == 0) return;
                if (hist_pos.* == self.lines.items.len) {
                    if (saved_draft.*) |s| self.allocator.free(s);
                    saved_draft.* = self.allocator.dupe(u8, line.items) catch null;
                }
                hist_pos.* -= 1;
                replaceLine(self.allocator, line, self.lines.items[hist_pos.*]);
                cursor.* = line.items.len;
            },
            'B' => { // down
                if (hist_pos.* >= self.lines.items.len) return;
                hist_pos.* += 1;
                if (hist_pos.* == self.lines.items.len) {
                    replaceLine(self.allocator, line, if (saved_draft.*) |s| s else "");
                } else {
                    replaceLine(self.allocator, line, self.lines.items[hist_pos.*]);
                }
                cursor.* = line.items.len;
            },
            'C' => { // right
                if (cursor.* < line.items.len) cursor.* += 1;
            },
            'D' => { // left
                if (cursor.* > 0) cursor.* -= 1;
            },
            else => {},
        }
    }

    fn completeToken(
        self: *Editor,
        line: *std.ArrayList(u8),
        cursor: *usize,
        stdout: *std.Io.Writer,
        prompt: []const u8,
    ) void {
        const prefix = tokenBefore(line.items, cursor.*);
        if (prefix.len == 0) return;
        var matches: std.ArrayList([]const u8) = .empty;
        defer matches.deinit(self.allocator);
        self.collectMatches(prefix, &matches) catch return;
        if (matches.items.len == 0) return;
        const shared = commonPrefix(matches.items);
        if (shared.len > prefix.len) {
            const rest = shared[prefix.len..];
            for (rest) |ch| {
                line.insert(self.allocator, cursor.*, ch) catch return;
                cursor.* += 1;
            }
            self.redraw(stdout, prompt, line.items, cursor.*);
            return;
        }
        if (matches.items.len == 1) return;
        stdout.writeAll("\r\n") catch {};
        for (matches.items, 0..) |m, i| {
            if (i > 0) stdout.writeAll("  ") catch {};
            stdout.writeAll(m) catch {};
        }
        stdout.writeAll("\r\n") catch {};
        stdout.flush() catch {};
        self.redraw(stdout, prompt, line.items, cursor.*);
    }

    pub fn collectMatches(self: *const Editor, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
        if (prefix.len == 0) return;
        if (prefix[0] == ':') {
            for (command_words) |w| try appendMatch(self.allocator, out, w, prefix);
        } else {
            for (builtin_words) |w| try appendMatch(self.allocator, out, w, prefix);
            if (self.mathlib) {
                for (mathlib_words) |w| try appendMatch(self.allocator, out, w, prefix);
            }
            for (self.extra_words.items) |w| try appendMatch(self.allocator, out, w, prefix);
        }
        std.mem.sort([]const u8, out.items, {}, wordLess);
    }

    fn redraw(self: *const Editor, stdout: *std.Io.Writer, prompt: []const u8, line: []const u8, cursor: usize) void {
        stdout.writeAll("\r") catch {};
        stdout.writeAll(prompt) catch {};
        if (self.color) {
            writeHighlighted(stdout, line);
        } else {
            stdout.writeAll(line) catch {};
        }
        stdout.writeAll("\x1b[K") catch {};
        if (line.len > cursor) {
            stdout.print("\x1b[{d}D", .{line.len - cursor}) catch {};
        }
        stdout.flush() catch {};
    }

};

const builtin_words = [_][]const u8{
    "sqrt", "length", "scale", "read", "abs", "ceil", "floor", "round",
    "gcd", "lcm", "factorial", "ibase", "obase", "last",
    "band", "bor", "bxor", "bnot8", "bnot16", "bnot32", "bnot64",
    "bshl", "bshr", "rand", "irand", "sci", "eng",
};
const mathlib_words = [_][]const u8{
    "s", "c", "a", "l", "e", "pi", "j", "sin", "cos", "tan", "t",
    "atan", "asin", "acos", "log", "log2", "log10",
};
const command_words = [_][]const u8{
    ":help", ":h", ":?", ":quit", ":q", ":rpn", ":dc", ":infix", ":bc", ":vars", ":clear",
};


pub const SpanKind = enum { plain, number, operator, keyword, comment, string };

const ansi_reset = "\x1b[0m";
const ansi_number = "\x1b[33m";
const ansi_operator = "\x1b[35m";
const ansi_keyword = "\x1b[34;1m";
const ansi_comment = "\x1b[90m";
const ansi_string = "\x1b[32m";

const highlight_keywords = [_][]const u8{
    "if", "else", "while", "for", "define", "return", "break", "continue",
    "quit", "halt", "print", "sqrt", "length", "scale", "ibase", "obase", "last", "auto",
    "abs", "ceil", "floor", "round", "gcd", "lcm", "factorial",
    "band", "bor", "bxor", "bnot8", "bnot16", "bnot32", "bnot64", "bshl", "bshr",
    "rand", "irand", "sci", "eng", "sin", "cos", "tan", "asin", "acos", "atan", "log", "log2", "log10", "pi",
};

const Span = struct { kind: SpanKind, end: usize };

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isKeywordName(name: []const u8) bool {
    for (highlight_keywords) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

fn isOperatorChar(c: u8) bool {
    return switch (c) {
        '+', '-', '*', '/', '%', '^', '=', '<', '>', '!', '(', ')', '{', '}', ']', ';', ',', '\\' => true,
        else => false,
    };
}

fn isArrayIndexOpen(line: []const u8, pos: usize) bool {
    var i = pos;
    while (i > 0) {
        i -= 1;
        const ch = line[i];
        if (ch == ' ' or ch == '\t') continue;
        return isIdentCont(ch) or ch == ']';
    }
    return false;
}

fn nextSpan(line: []const u8, start: usize) Span {
    if (start >= line.len) return .{ .kind = .plain, .end = start };
    const c = line[start];
    if (c == ' ' or c == '\t') {
        var i = start + 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        return .{ .kind = .plain, .end = i };
    }
    if (c == '#') return .{ .kind = .comment, .end = line.len };
    if (c == '/' and start + 1 < line.len and line[start + 1] == '*') {
        var i = start + 2;
        while (i + 1 < line.len) : (i += 1) {
            if (line[i] == '*' and line[i + 1] == '/') return .{ .kind = .comment, .end = i + 2 };
        }
        return .{ .kind = .comment, .end = line.len };
    }
    if (c == '[') {
        if (isArrayIndexOpen(line, start)) {
            return .{ .kind = .operator, .end = start + 1 };
        }
        var depth: usize = 1;
        var i = start + 1;
        while (i < line.len) : (i += 1) {
            if (line[i] == '[') depth += 1;
            if (line[i] == ']') {
                depth -= 1;
                if (depth == 0) return .{ .kind = .string, .end = i + 1 };
            }
        }
        return .{ .kind = .string, .end = line.len };
    }
    if (c == ':') {
        var i = start + 1;
        while (i < line.len and isIdentCont(line[i])) i += 1;
        return .{ .kind = .keyword, .end = @max(i, start + 1) };
    }
    if (std.ascii.isDigit(c) or (c == '.' and start + 1 < line.len and std.ascii.isDigit(line[start + 1]))) {
        var i = start + 1;
        while (i < line.len) : (i += 1) {
            const d = line[i];
            const ok = std.ascii.isDigit(d) or d == '.' or
                (d >= 'A' and d <= 'F') or (d >= 'a' and d <= 'f');
            if (!ok) break;
        }
        if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
            var j = i + 1;
            if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
            if (j < line.len and std.ascii.isDigit(line[j])) {
                while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
                i = j;
            }
        } else if (i > start and i < line.len) {
            const prev = line[i - 1];
            if ((prev == 'e' or prev == 'E') and (line[i] == '+' or line[i] == '-')) {
                var j = i + 1;
                if (j < line.len and std.ascii.isDigit(line[j])) {
                    while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
                    i = j;
                }
            }
        }
        return .{ .kind = .number, .end = i };
    }
    if (isIdentStart(c)) {
        var i = start + 1;
        while (i < line.len and isIdentCont(line[i])) i += 1;
        const name = line[start..i];
        return .{ .kind = if (isKeywordName(name)) .keyword else .plain, .end = i };
    }
    if (start + 1 < line.len) {
        const two = line[start .. start + 2];
        const doubles = [_][]const u8{ "++", "--", "+=", "-=", "*=", "/=", "%=", "^=", "==", "!=", "<=", ">=" };
        for (doubles) |d| {
            if (std.mem.eql(u8, two, d)) return .{ .kind = .operator, .end = start + 2 };
        }
    }
    if (isOperatorChar(c)) return .{ .kind = .operator, .end = start + 1 };
    return .{ .kind = .plain, .end = start + 1 };
}

fn ansiOf(kind: SpanKind) []const u8 {
    return switch (kind) {
        .plain => "",
        .number => ansi_number,
        .operator => ansi_operator,
        .keyword => ansi_keyword,
        .comment => ansi_comment,
        .string => ansi_string,
    };
}

fn writeHighlighted(stdout: *std.Io.Writer, line: []const u8) void {
    var i: usize = 0;
    var prev: ?SpanKind = null;
    while (i < line.len) {
        var span = nextSpan(line, i);
        if (span.end <= i) span.end = i + 1;
        const code = ansiOf(span.kind);
        if (prev == null or prev.? != span.kind) {
            stdout.writeAll(ansi_reset) catch {};
            if (code.len > 0) stdout.writeAll(code) catch {};
            prev = span.kind;
        }
        stdout.writeAll(line[i..span.end]) catch {};
        i = span.end;
    }
    stdout.writeAll(ansi_reset) catch {};
}

pub fn spanKind(line: []const u8, index: usize) SpanKind {
    if (index >= line.len) return .plain;
    var i: usize = 0;
    while (i <= index and i < line.len) {
        var span = nextSpan(line, i);
        if (span.end <= i) span.end = i + 1;
        if (index < span.end) return span.kind;
        i = span.end;
    }
    return .plain;
}

fn wordLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn appendMatch(allocator: Allocator, out: *std.ArrayList([]const u8), word: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, word, prefix)) return;
    for (out.items) |m| {
        if (std.mem.eql(u8, m, word)) return;
    }
    try out.append(allocator, word);
}

fn commonPrefix(words: []const []const u8) []const u8 {
    if (words.len == 0) return "";
    var n = words[0].len;
    for (words[1..]) |w| {
        var i: usize = 0;
        while (i < n and i < w.len and words[0][i] == w[i]) : (i += 1) {}
        n = i;
    }
    return words[0][0..n];
}

fn tokenBefore(line: []const u8, cursor: usize) []const u8 {
    var i = cursor;
    while (i > 0) {
        const c = line[i - 1];
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '?';
        if (!ok) break;
        i -= 1;
    }
    if (i > 0 and line[i - 1] == ':') i -= 1;
    return line[i..cursor];
}

fn replaceLine(allocator: Allocator, line: *std.ArrayList(u8), src: []const u8) void {
    line.clearRetainingCapacity();
    line.appendSlice(allocator, src) catch {};
}

fn readCooked(
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

test "history skips blanks and repeats" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.add("  ");
    try ed.add("1 + 2");
    try ed.add("1 + 2");
    try ed.add(" 1 + 2 ");
    try ed.add("3");
    try std.testing.expectEqual(@as(usize, 2), ed.lines.items.len);
    try std.testing.expectEqualStrings("1 + 2", ed.lines.items[0]);
    try std.testing.expectEqualStrings("3", ed.lines.items[1]);
}

test "tab completion matches names and commands" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.addExtra("answer");
    try ed.addExtra("area");

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(std.testing.allocator);

    try ed.collectMatches("sq", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqualStrings("sqrt", matches.items[0]);

    matches.clearRetainingCapacity();
    try ed.collectMatches("a", &matches);
    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
    try std.testing.expectEqualStrings("abs", matches.items[0]);
    try std.testing.expectEqualStrings("answer", matches.items[1]);
    try std.testing.expectEqualStrings("area", matches.items[2]);

    matches.clearRetainingCapacity();
    try ed.collectMatches(":q", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqualStrings(":q", matches.items[0]);
    try std.testing.expectEqualStrings(":quit", matches.items[1]);

    ed.mathlib = true;
    matches.clearRetainingCapacity();
    try ed.collectMatches("as", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqualStrings("asin", matches.items[0]);

    try std.testing.expectEqualStrings("ab", commonPrefix(&.{ "abs", "abc" }));
    try std.testing.expectEqualStrings(":he", tokenBefore(":help", 3));
    try std.testing.expectEqualStrings("sq", tokenBefore("1+sq", 4));
}

test "syntax highlighting kinds" {
    try std.testing.expectEqual(SpanKind.keyword, spanKind("if (1)", 0));
    try std.testing.expectEqual(SpanKind.operator, spanKind("if (1)", 3));
    try std.testing.expectEqual(SpanKind.number, spanKind("if (1)", 4));
    try std.testing.expectEqual(SpanKind.number, spanKind("1+2", 0));
    try std.testing.expectEqual(SpanKind.operator, spanKind("1+2", 1));
    try std.testing.expectEqual(SpanKind.number, spanKind("1+2", 2));
    try std.testing.expectEqual(SpanKind.comment, spanKind("1 # hi", 2));
    try std.testing.expectEqual(SpanKind.comment, spanKind("/* x */ 1", 0));
    try std.testing.expectEqual(SpanKind.string, spanKind("[2 3 +]", 0));
    try std.testing.expectEqual(SpanKind.string, spanKind("[2 3 +]", 6));
    try std.testing.expectEqual(SpanKind.operator, spanKind("a[0]", 1));
    try std.testing.expectEqual(SpanKind.number, spanKind("a[0]", 2));
    try std.testing.expectEqual(SpanKind.keyword, spanKind(":help", 0));
    try std.testing.expectEqual(SpanKind.keyword, spanKind("define f()", 0));
    try std.testing.expectEqual(SpanKind.plain, spanKind("answer", 0));
    try std.testing.expectEqual(SpanKind.operator, spanKind("x += 1", 2));
    try std.testing.expectEqual(SpanKind.number, spanKind("1e-2", 2));
    try std.testing.expectEqual(SpanKind.number, spanKind("1.5e3", 4));
}
