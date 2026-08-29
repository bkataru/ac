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

    pub fn init(allocator: Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.disableRaw();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
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
                    redraw(stdout, prompt, line.items, cursor);
                },
                0x7f, 0x08 => { // Backspace
                    if (cursor > 0) {
                        _ = line.orderedRemove(cursor - 1);
                        cursor -= 1;
                        redraw(stdout, prompt, line.items, cursor);
                    }
                },
                0x01 => { // Ctrl-A
                    cursor = 0;
                    redraw(stdout, prompt, line.items, cursor);
                },
                0x05 => { // Ctrl-E
                    cursor = line.items.len;
                    redraw(stdout, prompt, line.items, cursor);
                },
                0x0b => { // Ctrl-K
                    line.shrinkRetainingCapacity(cursor);
                    redraw(stdout, prompt, line.items, cursor);
                },
                0x15 => { // Ctrl-U
                    line.clearRetainingCapacity();
                    cursor = 0;
                    redraw(stdout, prompt, line.items, cursor);
                },
                0x1b => {
                    const n1 = stdin.takeByte() catch continue;
                    if (n1 == '[') {
                        const n2 = stdin.takeByte() catch continue;
                        self.handleArrow(n2, &line, &cursor, &hist_pos, &saved_draft);
                        redraw(stdout, prompt, line.items, cursor);
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
                        redraw(stdout, prompt, line.items, cursor);
                    }
                },
                else => {
                    if (ch >= 32 and line.items.len < buf.len) {
                        line.insert(self.allocator, cursor, ch) catch continue;
                        cursor += 1;
                        redraw(stdout, prompt, line.items, cursor);
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
};

fn replaceLine(allocator: Allocator, line: *std.ArrayList(u8), src: []const u8) void {
    line.clearRetainingCapacity();
    line.appendSlice(allocator, src) catch {};
}

fn redraw(stdout: *std.Io.Writer, prompt: []const u8, line: []const u8, cursor: usize) void {
    stdout.writeAll("\r") catch {};
    stdout.writeAll(prompt) catch {};
    stdout.writeAll(line) catch {};
    stdout.writeAll("\x1b[K") catch {};
    if (line.len > cursor) {
        stdout.print("\x1b[{d}D", .{line.len - cursor}) catch {};
    }
    stdout.flush() catch {};
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
