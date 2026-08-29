//! Lexer for ac calculator
//!
//! Tokenizes input for both infix (bc-style) and RPN (dc-style) modes.

const std = @import("std");

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    line: u32,
    column: u32,

    pub const Kind = enum(u8) {
        // Literals
        number,
        string,
        identifier,

        // Operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %
        caret, // ^

        // Comparison
        equal_equal, // ==
        bang_equal, // !=
        less, // <
        less_equal, // <=
        greater, // >
        greater_equal, // >=

        // Assignment
        equal, // =
        plus_equal, // +=
        minus_equal, // -=
        star_equal, // *=
        slash_equal, // /=
        percent_equal, // %=
        caret_equal, // ^=

        // Increment/Decrement
        plus_plus, // ++
        minus_minus, // --

        // Grouping
        left_paren,
        right_paren,
        left_brace,
        right_brace,
        left_bracket,
        right_bracket,

        // Punctuation
        semicolon,
        comma,
        newline,

        // Keywords
        kw_if,
        kw_else,
        kw_while,
        kw_for,
        kw_define,
        kw_return,
        kw_break,
        kw_continue,
        kw_quit,
        kw_halt,
        kw_print,
        kw_sqrt,
        kw_length,
        kw_scale,
        kw_ibase,
        kw_obase,
        kw_last,
        kw_auto,

        // Special
        eof,
        err,
    };

    /// Keywords lookup table
    pub const keywords = std.StaticStringMap(Kind).initComptime(.{
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "while", .kw_while },
        .{ "for", .kw_for },
        .{ "define", .kw_define },
        .{ "return", .kw_return },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "quit", .kw_quit },
        .{ "halt", .kw_halt },
        .{ "print", .kw_print },
        .{ "sqrt", .kw_sqrt },
        .{ "length", .kw_length },
        .{ "scale", .kw_scale },
        .{ "ibase", .kw_ibase },
        .{ "obase", .kw_obase },
        .{ "last", .kw_last },
        .{ "auto", .kw_auto },
    });
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    start_column: u32,

    const Self = @This();

    pub fn init(source: []const u8) Self {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .start_column = 1,
        };
    }

    /// Get the next token
    pub fn next(self: *Self) Token {
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return self.makeToken(.eof, "");
        }

        self.start_column = self.column;
        const c = self.advance();

        // Numbers
        if (isDigit(c) or (c == '.' and !self.isAtEnd() and isDigit(self.peek()))) {
            return self.number();
        }

        // Identifiers and keywords
        if (isAlpha(c)) {
            return self.identifier();
        }

        // Brackets: '[' emits left_bracket; the parser decides between a
        // dc-style string literal and array indexing from context.
        if (c == '[') {
            return self.makeToken(.left_bracket, "[");
        }

        // Operators and punctuation
        return switch (c) {
            '+' => blk: {
                if (self.match('+')) break :blk self.makeToken(.plus_plus, "++");
                if (self.match('=')) break :blk self.makeToken(.plus_equal, "+=");
                break :blk self.makeToken(.plus, "+");
            },
            '-' => blk: {
                if (self.match('-')) break :blk self.makeToken(.minus_minus, "--");
                if (self.match('=')) break :blk self.makeToken(.minus_equal, "-=");
                break :blk self.makeToken(.minus, "-");
            },
            '*' => blk: {
                if (self.match('=')) break :blk self.makeToken(.star_equal, "*=");
                break :blk self.makeToken(.star, "*");
            },
            '/' => blk: {
                // Check for comments
                if (self.match('*')) {
                    self.blockComment();
                    return self.next();
                }
                if (self.match('=')) break :blk self.makeToken(.slash_equal, "/=");
                break :blk self.makeToken(.slash, "/");
            },
            '%' => blk: {
                if (self.match('=')) break :blk self.makeToken(.percent_equal, "%=");
                break :blk self.makeToken(.percent, "%");
            },
            '^' => blk: {
                if (self.match('=')) break :blk self.makeToken(.caret_equal, "^=");
                break :blk self.makeToken(.caret, "^");
            },
            '=' => blk: {
                if (self.match('=')) break :blk self.makeToken(.equal_equal, "==");
                break :blk self.makeToken(.equal, "=");
            },
            '!' => blk: {
                if (self.match('=')) break :blk self.makeToken(.bang_equal, "!=");
                break :blk self.makeToken(.err, "!");
            },
            '<' => blk: {
                if (self.match('=')) break :blk self.makeToken(.less_equal, "<=");
                break :blk self.makeToken(.less, "<");
            },
            '>' => blk: {
                if (self.match('=')) break :blk self.makeToken(.greater_equal, ">=");
                break :blk self.makeToken(.greater, ">");
            },
            '(' => self.makeToken(.left_paren, "("),
            ')' => self.makeToken(.right_paren, ")"),
            '{' => self.makeToken(.left_brace, "{"),
            '}' => self.makeToken(.right_brace, "}"),
            ']' => self.makeToken(.right_bracket, "]"),
            ';' => self.makeToken(.semicolon, ";"),
            ',' => self.makeToken(.comma, ","),
            '\n' => blk: {
                self.line += 1;
                self.column = 1;
                break :blk self.makeToken(.newline, "\n");
            },
            '#' => blk: {
                // Line comment
                self.lineComment();
                break :blk self.next();
            },
            else => self.makeToken(.err, self.source[self.pos - 1 .. self.pos]),
        };
    }

    /// Peek at current character without consuming
    pub fn peek(self: *Self) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    /// Peek at next character
    fn peekNext(self: *Self) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    /// Advance and return current character
    fn advance(self: *Self) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        self.column += 1;
        return c;
    }

    /// Match current character and advance if matched
    fn match(self: *Self, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        self.column += 1;
        return true;
    }

    /// Check if at end of input
    fn isAtEnd(self: *Self) bool {
        return self.pos >= self.source.len;
    }

    /// Skip whitespace (except newlines)
    fn skipWhitespace(self: *Self) void {
        while (!self.isAtEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r' => _ = self.advance(),
                '\\' => {
                    // Line continuation
                    if (self.peekNext() == '\n') {
                        _ = self.advance();
                        _ = self.advance();
                        self.line += 1;
                        self.column = 1;
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    /// Parse a number
    fn number(self: *Self) Token {
        const start = self.pos - 1;

        // Integer part
        while (!self.isAtEnd() and (isDigit(self.peek()) or isHexDigit(self.peek()))) {
            _ = self.advance();
        }

        // Decimal part
        if (!self.isAtEnd() and self.peek() == '.' and
            (self.pos + 1 >= self.source.len or isDigit(self.source[self.pos + 1])))
        {
            _ = self.advance(); // consume '.'
            while (!self.isAtEnd() and isDigit(self.peek())) {
                _ = self.advance();
            }
        }

        return self.makeToken(.number, self.source[start..self.pos]);
    }

    /// Parse an identifier or keyword
    fn identifier(self: *Self) Token {
        const start = self.pos - 1;

        while (!self.isAtEnd() and (isAlpha(self.peek()) or isDigit(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }

        const lexeme = self.source[start..self.pos];

        // Check for keywords
        if (Token.keywords.get(lexeme)) |kind| {
            return self.makeToken(kind, lexeme);
        }

        return self.makeToken(.identifier, lexeme);
    }

    /// Parse a string (dc-style bracket string)
    fn string(self: *Self) Token {
        const start = self.pos;
        var depth: usize = 1;

        while (!self.isAtEnd() and depth > 0) {
            const c = self.advance();
            if (c == '[') {
                depth += 1;
            } else if (c == ']') {
                depth -= 1;
            } else if (c == '\n') {
                self.line += 1;
                self.column = 1;
            }
        }

        if (depth > 0) {
            return self.makeToken(.err, "unterminated string");
        }

        // Exclude the closing bracket
        return self.makeToken(.string, self.source[start .. self.pos - 1]);
    }

    /// Skip a block comment /* ... */
    fn blockComment(self: *Self) void {
        while (!self.isAtEnd()) {
            if (self.peek() == '*' and self.peekNext() == '/') {
                _ = self.advance();
                _ = self.advance();
                return;
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 1;
            }
            _ = self.advance();
        }
    }

    /// Skip a line comment
    fn lineComment(self: *Self) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            _ = self.advance();
        }
    }

    /// Create a token
    fn makeToken(self: *Self, kind: Token.Kind, lexeme: []const u8) Token {
        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = self.line,
            .column = self.start_column,
        };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f');
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

// ============= Tests =============

test "Lexer basic tokens" {
    var lexer = Lexer.init("1 + 2 * 3");

    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.plus, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.star, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "Lexer numbers" {
    var lexer = Lexer.init("123 45.67 .5 0.123");

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Kind.number, t1.kind);
    try std.testing.expectEqualStrings("123", t1.lexeme);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Kind.number, t2.kind);
    try std.testing.expectEqualStrings("45.67", t2.lexeme);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Kind.number, t3.kind);
    try std.testing.expectEqualStrings(".5", t3.lexeme);

    const t4 = lexer.next();
    try std.testing.expectEqual(Token.Kind.number, t4.kind);
    try std.testing.expectEqualStrings("0.123", t4.lexeme);
}

test "Lexer operators" {
    var lexer = Lexer.init("+ - * / % ^ = == != < <= > >=");

    try std.testing.expectEqual(Token.Kind.plus, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.minus, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.star, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.slash, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.percent, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.caret, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.equal, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.equal_equal, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.bang_equal, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.less, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.less_equal, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.greater, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.greater_equal, lexer.next().kind);
}

test "Lexer keywords" {
    var lexer = Lexer.init("if else while scale ibase obase");

    try std.testing.expectEqual(Token.Kind.kw_if, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_else, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_while, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_scale, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_ibase, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_obase, lexer.next().kind);
}

test "Lexer identifiers" {
    var lexer = Lexer.init("x foo bar123");

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t1.kind);
    try std.testing.expectEqualStrings("x", t1.lexeme);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t2.kind);
    try std.testing.expectEqualStrings("foo", t2.lexeme);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t3.kind);
    try std.testing.expectEqualStrings("bar123", t3.lexeme);
}

test "Lexer comments" {
    var lexer = Lexer.init("1 + /* comment */ 2 # line comment\n3");

    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.plus, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.number, lexer.next().kind);
}
