//! Parser for ac calculator
//!
//! Uses Pratt parsing (top-down operator precedence) for infix expressions.

const std = @import("std");
const Lexer = @import("lex.zig").Lexer;
const Token = @import("lex.zig").Token;
const BigDec = @import("num.zig").BigDec;

/// Binary operators
pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    pow_assign,
};

/// Unary operators
pub const UnaryOp = enum {
    negate,
    pre_inc,
    pre_dec,
    post_inc,
    post_dec,
};

/// Function parameter kind: scalar, array copied in, or array copied
/// in and written back on return (bc's *a[] reference form).
pub const ParamKind = enum { scalar, array_copy, array_ref };
pub const ParamSpec = struct { name: []const u8, kind: ParamKind };
/// A name bound by 'auto'; array entries carry an optional size expr.
pub const AutoEntry = struct { name: []const u8, size: ?*Expr };

/// Expression AST node
pub const Expr = union(enum) {
    number: BigDec,
    variable: []const u8,
    builtin_var: BuiltinVar,
    last: void,
    string: []const u8,

    binary: struct {
        left: *Expr,
        op: BinaryOp,
        right: *Expr,
    },

    unary: struct {
        op: UnaryOp,
        operand: *Expr,
    },

    call: struct {
        name: []const u8,
        args: std.ArrayList(*Expr),
    },

    grouping: *Expr,

    /// Array element access a[expr]; name is owned.
    index: struct {
        name: []const u8,
        idx: *Expr,
    },

    /// Whole-array reference used as a call argument: f(a[]).
    array_ref: []const u8,

    pub const BuiltinVar = enum {
        scale,
        ibase,
        obase,
    };

    /// Free all memory associated with this expression
    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .number => |*n| n.deinit(),
            .binary => |b| {
                b.left.deinit(allocator);
                allocator.destroy(b.left);
                b.right.deinit(allocator);
                allocator.destroy(b.right);
            },
            .unary => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u.operand);
            },
            .call => |*c| {
                allocator.free(c.name);
                for (c.args.items) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                c.args.deinit(allocator);
            },
            .grouping => |g| {
                g.deinit(allocator);
                allocator.destroy(g);
            },
            .variable => |name| {
                allocator.free(name);
            },
            .builtin_var, .last => {},
            .string => |s| allocator.free(s),
            .index => |ix| {
                allocator.free(ix.name);
                ix.idx.deinit(allocator);
                allocator.destroy(ix.idx);
            },
            .array_ref => |name| allocator.free(name),
        }
    }
};


/// Statement AST node (bc control flow and definitions)
pub const Stmt = union(enum) {
    /// Neutralized statement (result already handled by the caller).
    noop: void,
    expr: *Expr,
    print: []*Expr,
    if_stmt: struct {
        cond: *Expr,
        then_branch: *Stmt,
        else_branch: ?*Stmt,
    },
    while_stmt: struct {
        cond: *Expr,
        body: *Stmt,
    },
    for_stmt: struct {
        init: ?*Expr,
        cond: ?*Expr,
        update: ?*Expr,
        body: *Stmt,
    },
    break_stmt: void,
    continue_stmt: void,
    halt: void,
    quit: void,
    block: []*Stmt,
    func_def: struct {
        name: []const u8,
        params: []ParamSpec,
        auto_vars: []AutoEntry,
        body: *Stmt,
    },
    return_stmt: ?*Expr,
    auto: []AutoEntry,

    pub fn deinit(self: *Stmt, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .noop => {},
            .auto => |entries| {
                for (entries) |entry| {
                    allocator.free(entry.name);
                    if (entry.size) |sz| {
                        sz.deinit(allocator);
                        allocator.destroy(sz);
                    }
                }
                allocator.free(entries);
            },
            .expr => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            .print => |exprs| {
                for (exprs) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
                allocator.free(exprs);
            },
            .if_stmt => |s| {
                s.cond.deinit(allocator);
                allocator.destroy(s.cond);
                s.then_branch.deinit(allocator);
                allocator.destroy(s.then_branch);
                if (s.else_branch) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
            },
            .while_stmt => |s| {
                s.cond.deinit(allocator);
                allocator.destroy(s.cond);
                s.body.deinit(allocator);
                allocator.destroy(s.body);
            },
            .for_stmt => |s| {
                if (s.init) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
                if (s.cond) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
                if (s.update) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
                s.body.deinit(allocator);
                allocator.destroy(s.body);
            },
            .block => |stmts| {
                for (stmts) |s| {
                    s.deinit(allocator);
                    allocator.destroy(s);
                }
                allocator.free(stmts);
            },
            .func_def => |f| {
                for (f.params) |ps| allocator.free(ps.name);
                if (f.params.len > 0) allocator.free(f.params);
                for (f.auto_vars) |av| {
                    allocator.free(av.name);
                    if (av.size) |sz| {
                        sz.deinit(allocator);
                        allocator.destroy(sz);
                    }
                }
                if (f.auto_vars.len > 0) allocator.free(f.auto_vars);
                f.body.deinit(allocator);
                allocator.destroy(f.body);
            },
            .return_stmt => |maybe_e| if (maybe_e) |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            else => {},
        }
    }
};

/// Operator precedence levels (higher = binds tighter)
const Precedence = enum(u8) {
    none = 0,
    assignment = 1, // = += -= etc
    comparison = 2, // == != < > <= >=
    additive = 3, // + -
    multiplicative = 4, // * / %
    power = 5, // ^
    unary = 6, // - (prefix)
    call = 7, // function()
    primary = 8,
};

pub const Parser = struct {
    lexer: *Lexer,
    current: Token,
    previous: Token,
    allocator: std.mem.Allocator,
    had_error: bool,
    /// Source column (1-based) of the token that caused the last error.
    err_column: u32 = 0,
    /// Lexeme of the offending token, for the message.
    err_lexeme: []const u8 = "",
    panic_mode: bool,
    ibase: u8 = 10,
    parse_scale: usize = 0,

    const Self = @This();

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Self {
        var parser = Self{
            .lexer = lexer,
            .current = undefined,
            .previous = undefined,
            .allocator = allocator,
            .had_error = false,
            .panic_mode = false,
        };
        // Prime the parser
        parser.advance();
        return parser;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



    /// Top-level: handles `define`, otherwise parses a statement.
    pub fn parseTopLevel(self: *Self) Error!?*Stmt {
        if (self.current.kind == .kw_define) {
            return try self.parseDefine();
        }
        return self.parseStatement();
    }

    fn parseDefine(self: *Self) Error!*Stmt {
        self.advance(); // consume 'define'
        if (self.current.kind != .identifier) return error.ExpectedExpression;
        const name = self.allocator.dupe(u8, self.current.lexeme) catch return error.OutOfMemory;
        errdefer self.allocator.free(name);
        self.advance();

        var params: std.ArrayList(ParamSpec) = .empty;
        // One errdefer: free the member names, then the list buffer.
        errdefer {
            for (params.items) |p| self.allocator.free(p.name);
            params.deinit(self.allocator);
        }
        if (self.current.kind != .left_paren) return error.ExpectedLeftParen;
        self.advance();
        while (self.current.kind != .right_paren) {
            // Forms: name | name[] | *name[]
            var kind: ParamKind = .scalar;
            if (self.current.kind == .star) {
                kind = .array_ref;
                self.advance();
            }
            if (self.current.kind != .identifier) return error.ExpectedExpression;
            // Block scope: on error before the append, pname is freed once
            // here; after the append, ownership sits in params and the
            // errdefer at the function level handles it.
            {
                const pname = self.allocator.dupe(u8, self.current.lexeme) catch return error.OutOfMemory;
                errdefer self.allocator.free(pname);
                self.advance();
                if (self.current.kind == .left_bracket) {
                    if (kind != .array_ref) kind = .array_copy;
                    self.advance(); // '['
                    if (self.current.kind != .right_bracket) return error.ExpectedExpression;
                    self.advance(); // ']'
                }
                params.append(self.allocator, .{ .name = pname, .kind = kind }) catch return error.OutOfMemory;
            }
            if (self.current.kind == .comma) {
                self.advance();
            } else if (self.current.kind != .right_paren) {
                return error.ExpectedRightParen;
            }
        }
        self.advance(); // consume ')'

        // Optional [auto a, b[n]] list directly after the params.
        var autos: std.ArrayList(AutoEntry) = .empty;
        // One errdefer: free the entries, then the list buffer.
        errdefer {
            for (autos.items) |a| self.freeAutoEntry(a);
            autos.deinit(self.allocator);
        }
        if (self.current.kind == .left_bracket) {
            self.advance();
            while (self.current.kind != .right_bracket) {
                const entry = (try self.parseAutoEntry()) orelse return error.ExpectedExpression;
                autos.append(self.allocator, entry) catch {
                    self.freeAutoEntry(entry);
                    return error.OutOfMemory;
                };
                if (self.current.kind == .comma) {
                    self.advance();
                } else if (self.current.kind != .right_bracket) {
                    return error.ExpectedRightParen;
                }
            }
            self.advance(); // consume ']'
        }

        const body = (try self.parseStatement()) orelse return error.ExpectedExpression;

        const plist = try params.toOwnedSlice(self.allocator);
        const alist = try autos.toOwnedSlice(self.allocator);
        return try self.newStmt(.{ .func_def = .{
            .name = name,
            .params = plist,
            .auto_vars = alist,
            .body = body,
        } });
    }

    /// Parse one auto list entry: name or name[expr].
    fn parseAutoEntry(self: *Self) Error!?AutoEntry {
        if (self.current.kind != .identifier) return null;
        const aname = self.allocator.dupe(u8, self.current.lexeme) catch return error.OutOfMemory;
        errdefer self.allocator.free(aname);
        self.advance();
        var size: ?*Expr = null;
        if (self.current.kind == .left_bracket) {
            self.advance(); // '['
            size = (try self.parsePrecedence(.assignment)) orelse return error.ExpectedExpression;
            errdefer if (size) |sz| {
                sz.deinit(self.allocator);
                self.allocator.destroy(sz);
            };
            if (self.current.kind != .right_bracket) return error.ExpectedExpression;
            self.advance(); // ']'
        }
        return .{ .name = aname, .size = size };
    }

    /// Free an AutoEntry whose ownership was never transferred.
    fn freeAutoEntry(self: *Self, entry: AutoEntry) void {
        self.allocator.free(entry.name);
        if (entry.size) |sz| {
            sz.deinit(self.allocator);
            self.allocator.destroy(sz);
        }
    }

    /// Parse 'auto a, b[10], c;' as a standalone statement (function scope).
    fn parseAutoStmt(self: *Self) Error!*Stmt {
        self.advance(); // consume 'auto'
        var autos: std.ArrayList(AutoEntry) = .empty;
        // One errdefer: free the entries, then the list buffer.
        errdefer {
            for (autos.items) |a| self.freeAutoEntry(a);
            autos.deinit(self.allocator);
        }
        while (true) {
            const entry = (try self.parseAutoEntry()) orelse return error.ExpectedExpression;
            autos.append(self.allocator, entry) catch {
                self.freeAutoEntry(entry);
                return error.OutOfMemory;
            };
            self.skipTerminators();
            if (self.current.kind != .comma) break;
            self.advance();
        }
        self.skipTerminators();
        const list = try autos.toOwnedSlice(self.allocator);
        return try self.newStmt(.{ .auto = list });
    }

    /// Parse one statement. Returns null on empty input (eof/newline/;).
    /// A bare expression becomes Stmt.expr.
    pub fn parseStatement(self: *Self) Error!?*Stmt {
        switch (self.current.kind) {
            .eof, .newline, .semicolon => return null,
            .kw_if => return try self.parseIf(),
            .kw_while => return try self.parseWhile(),
            .kw_for => return try self.parseFor(),
            .kw_break => {
                self.advance();
                self.skipTerminators();
                return try self.newStmt(.{ .break_stmt = {} });
            },
            .kw_continue => {
                self.advance();
                self.skipTerminators();
                return try self.newStmt(.{ .continue_stmt = {} });
            },
            .kw_halt => {
                self.advance();
                self.skipTerminators();
                return try self.newStmt(.{ .halt = {} });
            },
            .kw_quit => {
                self.advance();
                self.skipTerminators();
                return try self.newStmt(.{ .quit = {} });
            },
            .kw_auto => return try self.parseAutoStmt(),
            .kw_print => return try self.parsePrint(),
            .kw_return => return try self.parseReturn(),
            .left_brace => return try self.parseBlock(),
            else => {
                // Expression statement (also catches assignments).
                const e = (try self.parseExpression(0)) orelse return null;
                self.skipTerminators();
                return try self.newStmt(.{ .expr = e });
            },
        }
    }

    pub fn skipTerminators(self: *Self) void {
        while (self.current.kind == .newline or self.current.kind == .semicolon) {
            self.advance();
        }
    }

    fn newStmt(self: *Self, value: Stmt) Error!*Stmt {
        const s = try self.allocator.create(Stmt);
        s.* = value;
        return s;
    }

    fn parseParenExpr(self: *Self) Error!*Expr {
        if (self.current.kind != .left_paren) return error.ExpectedLeftParen;
        self.advance();
        const e = (try self.parseExpression(0)) orelse return error.ExpectedExpression;
        if (self.current.kind != .right_paren) return error.ExpectedRightParen;
        self.advance();
        return e;
    }

    fn parseIf(self: *Self) Error!*Stmt {
        self.advance(); // consume 'if'
        const cond = try self.parseParenExpr();
        const then_branch = (try self.parseStatement()) orelse {
            cond.deinit(self.allocator);
            self.allocator.destroy(cond);
            return error.ExpectedExpression;
        };
        var else_branch: ?*Stmt = null;
        if (self.current.kind == .kw_else) {
            self.advance();
            else_branch = try self.parseStatement();
        }
        return try self.newStmt(.{ .if_stmt = .{
            .cond = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } });
    }

    fn parseWhile(self: *Self) Error!*Stmt {
        self.advance(); // consume 'while'
        const cond = try self.parseParenExpr();
        const body = (try self.parseStatement()) orelse {
            cond.deinit(self.allocator);
            self.allocator.destroy(cond);
            return error.ExpectedExpression;
        };
        return try self.newStmt(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseFor(self: *Self) Error!*Stmt {
        self.advance(); // consume 'for'
        if (self.current.kind != .left_paren) return error.ExpectedLeftParen;
        self.advance();

        const init_e: ?*Expr = if (self.current.kind == .semicolon)
            null
        else
            try self.parseExpression(0);
        if (self.current.kind != .semicolon) return error.ExpectedRightParen; // reuse: expects ';'
        self.advance();

        const cond_e: ?*Expr = if (self.current.kind == .semicolon)
            null
        else
            try self.parseExpression(0);
        if (self.current.kind != .semicolon) return error.ExpectedRightParen;
        self.advance();

        const update_e: ?*Expr = if (self.current.kind == .right_paren)
            null
        else
            try self.parseExpression(0);
        if (self.current.kind != .right_paren) return error.ExpectedRightParen;
        self.advance();

        const body = (try self.parseStatement()) orelse return error.ExpectedExpression;

        return try self.newStmt(.{ .for_stmt = .{
            .init = init_e,
            .cond = cond_e,
            .update = update_e,
            .body = body,
        } });
    }

    fn parsePrint(self: *Self) Error!*Stmt {
        self.advance(); // consume 'print'
        var exprs: std.ArrayList(*Expr) = .empty;
        errdefer {
            for (exprs.items) |e| {
                e.deinit(self.allocator);
                self.allocator.destroy(e);
            }
            exprs.deinit(self.allocator);
        }
        while (true) {
            const e = (try self.parseExpression(0)) orelse break;
            try exprs.append(self.allocator, e);
            self.skipTerminators();
            if (self.current.kind != .comma) break;
            self.advance();
        }
        const list = try exprs.toOwnedSlice(self.allocator);
        return try self.newStmt(.{ .print = list });
    }

    fn parseReturn(self: *Self) Error!*Stmt {
        self.advance(); // consume 'return'
        if (self.current.kind == .newline or self.current.kind == .semicolon or
            self.current.kind == .eof or self.current.kind == .right_brace)
        {
            self.skipTerminators();
            return try self.newStmt(.{ .return_stmt = null });
        }
        const e = (try self.parseExpression(0)) orelse return error.ExpectedExpression;
        self.skipTerminators();
        return try self.newStmt(.{ .return_stmt = e });
    }

    fn parseBlock(self: *Self) Error!*Stmt {
        if (self.current.kind != .left_brace) return error.ExpectedLeftParen;
        self.advance();
        self.skipTerminators();

        var stmts: std.ArrayList(*Stmt) = .empty;
        errdefer {
            for (stmts.items) |s| {
                s.deinit(self.allocator);
                self.allocator.destroy(s);
            }
            stmts.deinit(self.allocator);
        }

        while (true) {
            if (self.current.kind == .right_brace) {
                self.advance();
                break;
            }
            if (self.current.kind == .eof) return error.ExpectedRightParen;
            const before = self.current.kind;
            const s = try self.parseStatement();
            if (s == null) {
                // parseStatement consumed nothing for terminators; skip one
                // to guarantee progress.
                if (before == .newline or before == .semicolon) self.advance();
                continue;
            }
            try stmts.append(self.allocator, s.?);
        }

        const list = try stmts.toOwnedSlice(self.allocator);
        return try self.newStmt(.{ .block = list });
    }

    /// Parse an expression with given minimum precedence
    pub fn parseExpression(self: *Self, min_prec: u8) !?*Expr {
        return self.parsePrecedence(@enumFromInt(min_prec));
    }

    /// Error set shared by recursive parser functions
    pub const Error = error{
        OutOfMemory,
        InvalidOperand,
        UnexpectedToken,
        ExpectedLeftParen,
        ExpectedRightParen,
        ExpectedExpression,
        InvalidFunctionCall,
        InvalidBase,
        DivisionByZero,
        InternalDivisionOverflow,
        NegativeSquareRoot,
        NonIntegerExponent,
        ExpectedSemicolon,
    };

    /// Pratt parser core - parse at given precedence level
    fn parsePrecedence(self: *Self, precedence: Precedence) Error!?*Expr {
        // Get prefix rule for current token
        var left = try self.parsePrefix() orelse return null;

        // Parse infix operators while precedence allows:
        // continue while the current token is an operator whose
        // precedence is >= the minimum for this position.
        while (true) {
            const infix_prec = self.getInfixPrecedence();
            if (infix_prec == .none or @intFromEnum(precedence) > @intFromEnum(infix_prec)) {
                break;
            }
            left = try self.parseInfix(left);
        }

        return left;
    }

    /// Parse prefix expression (numbers, unary ops, grouping)
    fn parsePrefix(self: *Self) Error!?*Expr {
        return switch (self.current.kind) {
            .number => try self.parseNumber(),
            .identifier => try self.parseIdentifier(),
            .string => try self.parseStringLit(),
            .kw_scale => try self.parseScaleToken(),
            .kw_ibase => try self.parseBuiltinVar(.ibase),
            .kw_obase => try self.parseBuiltinVar(.obase),
            .kw_last => try self.parseLast(),
            .kw_sqrt => try self.parseBuiltinCall("sqrt"),
            .kw_length => try self.parseBuiltinCall("length"),
            .minus => try self.parseUnary(.negate),
            .plus_plus => try self.parsePrefixIncDec(.pre_inc),
            .minus_minus => try self.parsePrefixIncDec(.pre_dec),
            .left_paren => try self.parseGrouping(),
            .left_bracket => try self.parseStringLit(),
            .eof, .newline, .semicolon => null,
            else => {
                self.had_error = true;
                self.err_column = self.current.column;
                self.err_lexeme = self.current.lexeme;
                return error.UnexpectedToken;
            },
        };
    }

    /// Parse infix expression (binary operators)
    fn parseInfix(self: *Self, left: *Expr) Error!*Expr {
        return switch (self.current.kind) {
            .plus => try self.parseBinary(left, .add),
            .minus => try self.parseBinary(left, .sub),
            .star => try self.parseBinary(left, .mul),
            .slash => try self.parseBinary(left, .div),
            .percent => try self.parseBinary(left, .mod),
            .caret => try self.parseBinaryRightAssoc(left, .pow),
            .left_bracket => try self.parseIndexAccess(left),
            .equal => try self.parseBinaryRightAssoc(left, .assign),
            .plus_equal => try self.parseBinaryRightAssoc(left, .add_assign),
            .minus_equal => try self.parseBinaryRightAssoc(left, .sub_assign),
            .star_equal => try self.parseBinaryRightAssoc(left, .mul_assign),
            .slash_equal => try self.parseBinaryRightAssoc(left, .div_assign),
            .percent_equal => try self.parseBinaryRightAssoc(left, .mod_assign),
            .caret_equal => try self.parseBinaryRightAssoc(left, .pow_assign),
            .equal_equal => try self.parseBinary(left, .eq),
            .bang_equal => try self.parseBinary(left, .ne),
            .less => try self.parseBinary(left, .lt),
            .less_equal => try self.parseBinary(left, .le),
            .greater => try self.parseBinary(left, .gt),
            .greater_equal => try self.parseBinary(left, .ge),
            .plus_plus => try self.parsePostfixIncDec(left, .post_inc),
            .minus_minus => try self.parsePostfixIncDec(left, .post_dec),
            .left_paren => try self.parseFunctionCall(left),
            else => left,
        };
    }

    /// Get precedence of current token as infix operator
    fn getInfixPrecedence(self: *Self) Precedence {
        return switch (self.current.kind) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .caret_equal => .assignment,
            .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal => .comparison,
            .plus, .minus => .additive,
            .star, .slash, .percent => .multiplicative,
            .caret => .power,
            .plus_plus, .minus_minus => .unary,
            .left_paren => .call,
            .left_bracket => .call,
            else => .none,
        };
    }

    /// Parse a number literal
    fn parseNumber(self: *Self) !*Expr {
        const lexeme = self.current.lexeme;
        self.advance();

        var num = if (self.ibase == 10)
            try BigDec.parse(self.allocator, lexeme, 10)
        else
            try BigDec.parseBase(self.allocator, lexeme, self.ibase, self.parse_scale);
        errdefer num.deinit();

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .number = num };
        return expr;
    }

    /// Parse a dc-style bracket string: scan raw source for the matching
    /// ']' (nesting-aware), then resync the lexer past it.
    fn parseStringLit(self: *Self) Error!*Expr {
        const open_off = @intFromPtr(self.current.lexeme.ptr) - @intFromPtr(self.lexer.source.ptr);
        var depth: usize = 1;
        var i = open_off + 1;
        while (i < self.lexer.source.len and depth > 0) : (i += 1) {
            switch (self.lexer.source[i]) {
                '[' => depth += 1,
                ']' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) return error.UnexpectedToken;
        const content = self.lexer.source[open_off + 1 .. i - 1];
        const owned = self.allocator.dupe(u8, content) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        // Resync: skip the lexer past the string body.
        self.lexer.pos = i;
        self.advance();
        const expr = self.allocator.create(Expr) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .string = owned };
        return expr;
    }

    /// Parse a[i] (element index) or a[] (whole-array reference).
    fn parseIndexAccess(self: *Self, left: *Expr) Error!*Expr {
        // Take ownership of the variable node's heap name; the shell is
        // destroyed and the name moves into the new node.
        const name = switch (left.*) {
            .variable => |n| n,
            else => {
                left.deinit(self.allocator);
                self.allocator.destroy(left);
                return error.InvalidOperand;
            },
        };
        self.allocator.destroy(left);
        errdefer self.allocator.free(name);
        self.advance(); // consume '['
        if (self.current.kind == .right_bracket) {
            self.advance(); // consume ']'
            const expr = try self.allocator.create(Expr);
            errdefer self.allocator.destroy(expr);
            expr.* = .{ .array_ref = name };
            return expr;
        }
        const idx = (try self.parsePrecedence(.assignment)) orelse return error.ExpectedExpression;
        if (self.current.kind != .right_bracket) return error.ExpectedExpression;
        self.advance(); // consume ']'
        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .index = .{ .name = name, .idx = idx } };
        return expr;
    }

    /// Parse an identifier (variable). The name is duplicated so ASTs
    /// stored beyond the current line (function bodies) stay valid.
    fn parseIdentifier(self: *Self) !*Expr {
        // bc: with ibase > 10, uppercase A-F lexemes are number literals.
        if (self.ibase > 10 and self.current.lexeme.len > 0) {
            var all_digits = true;
            for (self.current.lexeme) |ch| {
                if (ch < 'A' or ch > 'F') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                const lexeme = self.current.lexeme;
                self.advance();
                var num = try BigDec.parseBase(self.allocator, lexeme, self.ibase, self.parse_scale);
                errdefer num.deinit();
                const expr = try self.allocator.create(Expr);
                errdefer self.allocator.destroy(expr);
                expr.* = .{ .number = num };
                return expr;
            }
        }
        const name = try self.allocator.dupe(u8, self.current.lexeme);
        errdefer self.allocator.free(name);
        self.advance();

        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .variable = name };
        return expr;
    }

    /// `scale` is both a special variable and the scale(x) builtin.
    /// `scale(` starts a call; bare `scale` is the variable.
    fn parseScaleToken(self: *Self) Error!*Expr {
        self.advance();
        if (self.current.kind == .left_paren) {
            return self.parseCallParenArgs("scale");
        }
        const expr = try self.allocator.create(Expr);
        expr.* = .{ .builtin_var = .scale };
        return expr;
    }

    /// Parse a builtin variable (scale, ibase, obase)
    fn parseBuiltinVar(self: *Self, which: Expr.BuiltinVar) !*Expr {
        self.advance();

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .builtin_var = which };
        return expr;
    }

    /// Parse 'last' keyword
    fn parseLast(self: *Self) !*Expr {
        self.advance();

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .last = {} };
        return expr;
    }

    /// Parse builtin function call (sqrt, length)
    fn parseBuiltinCall(self: *Self, name: []const u8) Error!*Expr {
        self.advance(); // consume keyword

        if (self.current.kind != .left_paren) {
            return error.ExpectedLeftParen;
        }
        return self.parseCallParenArgs(name);
    }

    /// Current token must be '('. Parse `(args...)` into a call named `name`.
    fn parseCallParenArgs(self: *Self, name: []const u8) Error!*Expr {
        if (self.current.kind != .left_paren) {
            return error.ExpectedLeftParen;
        }
        self.advance();

        var args: std.ArrayList(*Expr) = .empty;
        errdefer {
            for (args.items) |arg| {
                arg.deinit(self.allocator);
                self.allocator.destroy(arg);
            }
            args.deinit(self.allocator);
        }

        // Parse arguments
        if (self.current.kind != .right_paren) {
            const arg = try self.parsePrecedence(.assignment) orelse return error.ExpectedExpression;
            try args.append(self.allocator, arg);

            while (self.current.kind == .comma) {
                self.advance();
                const next_arg = try self.parsePrecedence(.assignment) orelse return error.ExpectedExpression;
                try args.append(self.allocator, next_arg);
            }
        }

        if (self.current.kind != .right_paren) {
            return error.ExpectedRightParen;
        }
        self.advance();

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .call = .{ .name = owned_name, .args = args } };
        return expr;
    }

    /// Parse unary operator
    fn parseUnary(self: *Self, op: UnaryOp) !*Expr {
        self.advance();

        const operand = try self.parsePrecedence(.unary) orelse return error.ExpectedExpression;

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .unary = .{ .op = op, .operand = operand } };
        return expr;
    }

    /// Parse prefix increment/decrement
    fn parsePrefixIncDec(self: *Self, op: UnaryOp) !*Expr {
        self.advance();

        const operand = try self.parsePrecedence(.unary) orelse return error.ExpectedExpression;

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .unary = .{ .op = op, .operand = operand } };
        return expr;
    }

    /// Parse postfix increment/decrement
    fn parsePostfixIncDec(self: *Self, left: *Expr, op: UnaryOp) !*Expr {
        self.advance();

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .unary = .{ .op = op, .operand = left } };
        return expr;
    }

    /// Parse grouping expression
    fn parseGrouping(self: *Self) !*Expr {
        self.advance(); // consume '('

        const inner = try self.parsePrecedence(.assignment) orelse return error.ExpectedExpression;

        if (self.current.kind != .right_paren) {
            inner.deinit(self.allocator);
            self.allocator.destroy(inner);
            return error.ExpectedRightParen;
        }
        self.advance();

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .grouping = inner };
        return expr;
    }

    /// Parse binary operator (left associative)
    fn parseBinary(self: *Self, left: *Expr, op: BinaryOp) !*Expr {
        errdefer {
            left.deinit(self.allocator);
            self.allocator.destroy(left);
        }
        const prec = self.getInfixPrecedence();
        self.advance();

        // Parse right side with higher precedence (left associative)
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(prec) + 1)) orelse {
            return error.ExpectedExpression;
        };
        errdefer {
            right.deinit(self.allocator);
            self.allocator.destroy(right);
        }

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .binary = .{ .left = left, .op = op, .right = right } };
        return expr;
    }

    /// Parse binary operator (right associative - power, assignment)
    fn parseBinaryRightAssoc(self: *Self, left: *Expr, op: BinaryOp) !*Expr {
        errdefer {
            left.deinit(self.allocator);
            self.allocator.destroy(left);
        }
        const prec = self.getInfixPrecedence();
        self.advance();

        // Parse right side with same precedence (right associative)
        const right = try self.parsePrecedence(prec) orelse {
            return error.ExpectedExpression;
        };
        errdefer {
            right.deinit(self.allocator);
            self.allocator.destroy(right);
        }

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .binary = .{ .left = left, .op = op, .right = right } };
        return expr;
    }

    /// Parse function call
    fn parseFunctionCall(self: *Self, callee: *Expr) Error!*Expr {
        // Callee should be a variable (function name)
        const name = switch (callee.*) {
            .variable => |n| n,
            else => return error.InvalidFunctionCall,
        };

        self.advance(); // consume '('

        var args: std.ArrayList(*Expr) = .empty;
        errdefer {
            for (args.items) |arg| {
                arg.deinit(self.allocator);
                self.allocator.destroy(arg);
            }
            args.deinit(self.allocator);
        }

        // Parse arguments
        if (self.current.kind != .right_paren) {
            const arg = try self.parsePrecedence(.assignment) orelse return error.ExpectedExpression;
            try args.append(self.allocator, arg);

            while (self.current.kind == .comma) {
                self.advance();
                const next_arg = try self.parsePrecedence(.assignment) orelse return error.ExpectedExpression;
                try args.append(self.allocator, next_arg);
            }
        }

        if (self.current.kind != .right_paren) {
            return error.ExpectedRightParen;
        }
        self.advance();

        // Free the callee variable node; its (owned) name slice is reused
        // by the call expression and eventually freed with the AST.
        self.allocator.destroy(callee);

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .call = .{ .name = name, .args = args } };
        return expr;
    }

    /// Advance to next token
    fn advance(self: *Self) void {
        self.previous = self.current;
        self.current = self.lexer.next();
    }
};

// ============= Tests =============

test "Parser simple number" {
    const allocator = std.testing.allocator;

    var lexer = Lexer.init("42");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const expr = try parser.parseExpression(0);
    try std.testing.expect(expr != null);

    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        try std.testing.expect(e.* == .number);
    }
}

test "Parser binary expression" {
    const allocator = std.testing.allocator;

    var lexer = Lexer.init("1 + 2");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const expr = try parser.parseExpression(0);
    try std.testing.expect(expr != null);

    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        try std.testing.expect(e.* == .binary);
        try std.testing.expectEqual(BinaryOp.add, e.binary.op);
    }
}

test "Parser scale is variable, scale() is call" {
    const allocator = std.testing.allocator;

    {
        var lexer = Lexer.init("scale");
        var parser = Parser.init(&lexer, allocator);
        defer parser.deinit();
        const expr = try parser.parseExpression(0);
        try std.testing.expect(expr != null);
        if (expr) |e| {
            defer {
                e.deinit(allocator);
                allocator.destroy(e);
            }
            try std.testing.expect(e.* == .builtin_var);
            try std.testing.expectEqual(Expr.BuiltinVar.scale, e.builtin_var);
        }
    }

    {
        var lexer = Lexer.init("scale(0.25)");
        var parser = Parser.init(&lexer, allocator);
        defer parser.deinit();
        const expr = try parser.parseExpression(0);
        try std.testing.expect(expr != null);
        if (expr) |e| {
            defer {
                e.deinit(allocator);
                allocator.destroy(e);
            }
            try std.testing.expect(e.* == .call);
            try std.testing.expectEqualStrings("scale", e.call.name);
            try std.testing.expectEqual(@as(usize, 1), e.call.args.items.len);
        }
    }
}

test "Parser precedence" {
    const allocator = std.testing.allocator;

    // 1 + 2 * 3 should parse as 1 + (2 * 3)
    var lexer = Lexer.init("1 + 2 * 3");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const expr = try parser.parseExpression(0);
    try std.testing.expect(expr != null);

    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        // Top level should be +
        try std.testing.expect(e.* == .binary);
        try std.testing.expectEqual(BinaryOp.add, e.binary.op);
        // Right side should be *
        try std.testing.expect(e.binary.right.* == .binary);
        try std.testing.expectEqual(BinaryOp.mul, e.binary.right.binary.op);
    }
}

test "Parser grouping" {
    const allocator = std.testing.allocator;

    var lexer = Lexer.init("(1 + 2) * 3");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const expr = try parser.parseExpression(0);
    try std.testing.expect(expr != null);

    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        // Top level should be *
        try std.testing.expect(e.* == .binary);
        try std.testing.expectEqual(BinaryOp.mul, e.binary.op);
        // Left side should be grouping
        try std.testing.expect(e.binary.left.* == .grouping);
    }
}

test "Parser unary minus" {
    const allocator = std.testing.allocator;

    var lexer = Lexer.init("-5");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();

    const expr = try parser.parseExpression(0);
    try std.testing.expect(expr != null);

    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        try std.testing.expect(e.* == .unary);
        try std.testing.expectEqual(UnaryOp.negate, e.unary.op);
    }
}

test "parseDefine error frees params and autos" {
    const allocator = std.testing.allocator;

    // Missing body after collected params: the errdefer must free the
    // appended param names.
    var lexer = Lexer.init("define f(a, )");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();
    try std.testing.expectError(error.ExpectedExpression, parser.parseTopLevel());

    // In-loop failure after a param was appended.
    var lexer2 = Lexer.init("define f(a 1)");
    var parser2 = Parser.init(&lexer2, allocator);
    defer parser2.deinit();
    try std.testing.expectError(error.ExpectedRightParen, parser2.parseTopLevel());

    // Autos list: an appended entry must be freed when a later entry fails.
    var lexer3 = Lexer.init("define f() [x, ]");
    var parser3 = Parser.init(&lexer3, allocator);
    defer parser3.deinit();
    try std.testing.expectError(error.ExpectedExpression, parser3.parseTopLevel());
}

test "infix error frees left operand" {
    const allocator = std.testing.allocator;

    // Quote is not a token: RHS of assignment raises UnexpectedToken.
    // The already-built left operand (scale) must still be freed.
    var lexer = Lexer.init("scale = \"s\"");
    var parser = Parser.init(&lexer, allocator);
    defer parser.deinit();
    try std.testing.expectError(error.UnexpectedToken, parser.parseTopLevel());
}
