# ac - A Calculator

**A modern reimagining of the classic UNIX bc/dc calculators**

> "bc" = basic calculator, "dc" = desk calculator, "ac" = a calculator

---

## Vision

`ac` is a modern CLI calculator built in Zig 0.16.0, designed as a faithful successor to the venerable `bc` and `dc` UNIX utilities. It combines the power of arbitrary-precision arithmetic with modern ergonomics, colorful TUI output, and a unified dual-mode interface supporting both infix (bc-style) and RPN (dc-style) notation.

### Design Philosophy

1. **Data-Driven Design**: Leverage Zig's comptime for lookup tables, operator precedence, and token mappings
2. **Zero Dependencies**: Pure Zig implementation, no C dependencies
3. **Modern UX**: ANSI colors, syntax highlighting, improved error messages
4. **Dual-Mode**: Seamless switching between infix and RPN modes
5. **Compatible**: Support existing bc/dc scripts where practical

---

## Architecture Overview

```
ac/
  src/
    main.zig         # Entry point, CLI parsing, REPL loop, State
    num.zig          # Arbitrary precision decimal arithmetic (BigDec)
    lex.zig          # Unified lexer for both modes
    parse.zig        # Infix parser (Pratt)
    eval.zig         # AST evaluator for infix mode
    dc.zig           # RPN (dc) evaluator and macros
    mathlib.zig      # Hardcoded -l math library (s, c, a, l, e, pi, j) plus extras
    repl_edit.zig    # Interactive line editing, ~/.ac_history, Tab, syntax colors
    # (POSIX fixtures live in tests/posix/, run via tests/posix/runner.zig)
  tests/posix/       # Small POSIX fixture pack (.ac/.dc + expected .out)
  build.zig
  build.zig.zon
```

---

## Core Data Structures

### 1. BigDec - Arbitrary Precision Decimal

```zig
/// Arbitrary precision decimal number
/// Based on gavinhoward/bc's BcNum design
pub const BigDec = struct {
    /// Limbs array - each limb holds BC_BASE_DIGS decimal digits
    /// On 64-bit: 9 digits per i32 limb (max value 999,999,999)
    limbs: []Limb,
    
    /// Number of limbs currently in use
    len: usize,
    
    /// Allocated capacity
    cap: usize,
    
    /// Radix position (decimal point location) + sign bit in LSB
    /// rdx >> 1 = radix position, rdx & 1 = is_negative
    rdx: usize,
    
    /// Scale (number of digits after decimal point)
    scale: usize,

    pub const Limb = i32;
    pub const BASE_DIGS = 9;  // digits per limb
    pub const BASE: i64 = 1_000_000_000;  // 10^9

    // Core operations
    pub fn add(self: *BigDec, a: BigDec, b: BigDec, scale: usize) !void;
    pub fn sub(self: *BigDec, a: BigDec, b: BigDec, scale: usize) !void;
    pub fn mul(self: *BigDec, a: BigDec, b: BigDec, scale: usize) !void;
    pub fn div(self: *BigDec, a: BigDec, b: BigDec, scale: usize) !void;
    pub fn mod(self: *BigDec, a: BigDec, b: BigDec, scale: usize) !void;
    pub fn pow(self: *BigDec, base: BigDec, exp: BigDec, scale: usize) !void;
    pub fn sqrt(self: *BigDec, a: BigDec, scale: usize) !void;
    
    // Comparison
    pub fn cmp(a: BigDec, b: BigDec) std.math.Order;
    
    // Parsing/Formatting
    pub fn parse(str: []const u8, ibase: u8) !BigDec;
    pub fn format(self: BigDec, writer: *std.Io.Writer, obase: u8) !void;
};
```

**Algorithm Complexity (from bc-dc-reference):**

| Operation | Algorithm | Complexity |
|-----------|-----------|------------|
| add/sub | Brute force | O(n) |
| mul | Karatsuba (large) / Brute force (small) | O(n^1.585) / O(n^2) |
| div | Long division (Algorithm D) | O(n^2) |
| pow | Exponentiation by squaring | O((n*log(n))^1.585) |
| sqrt | Newton-Raphson | O(log(n)*n^2) |

### 2. Token - Lexer Output

```zig
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
        
        // Operators (shared)
        plus,           // +
        minus,          // -
        star,           // *
        slash,          // /
        percent,        // %
        caret,          // ^
        
        // Comparison
        equal_equal,    // ==
        bang_equal,     // !=
        less,           // <
        less_equal,     // <=
        greater,        // >
        greater_equal,  // >=
        
        // Assignment
        equal,          // =
        plus_equal,     // +=
        minus_equal,    // -=
        // ... etc
        
        // Grouping
        left_paren,
        right_paren,
        left_brace,
        right_brace,
        left_bracket,   // dc string/macro
        right_bracket,
        
        // Keywords (bc mode)
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
        // ... math library functions
        
        // dc commands (single char)
        dc_print,       // p
        dc_print_pop,   // n  
        dc_dup,         // d
        dc_swap,        // r
        dc_clear,       // c
        dc_depth,       // z
        dc_exec,        // x
        dc_store,       // s
        dc_load,        // l
        dc_store_push,  // S
        dc_load_pop,    // L
        // ... etc
        
        // Special
        newline,
        semicolon,
        eof,
        err,
    };
};
```

### 3. Expr - AST for Infix Mode

```zig
pub const Expr = union(enum) {
    number: BigDec,
    variable: []const u8,
    last: void,  // the '.' or 'last' keyword
    
    binary: struct {
        left: *Expr,
        operator: BinaryOp,
        right: *Expr,
    },
    
    unary: struct {
        operator: UnaryOp,
        operand: *Expr,
    },
    
    call: struct {
        name: []const u8,
        args: []const *Expr,
    },
    
    assign: struct {
        target: []const u8,
        value: *Expr,
    },
    
    grouping: *Expr,
    
    array_access: struct {
        array: []const u8,
        index: *Expr,
    },

    pub const BinaryOp = enum {
        add, sub, mul, div, mod, pow,
        eq, ne, lt, le, gt, ge,
        bool_and, bool_or,
        shift_left, shift_right,  // decimal shift
        at_scale,  // @ operator
    };

    pub const UnaryOp = enum {
        negate,
        bool_not,
        pre_inc, pre_dec,
        post_inc, post_dec,
        truncate,  // $ operator
    };
};
```

### 4. Stmt - Statement AST

```zig
pub const Stmt = union(enum) {
    expr: *Expr,
    
    print: []const *Expr,
    
    if_stmt: struct {
        condition: *Expr,
        then_branch: *Stmt,
        else_branch: ?*Stmt,
    },
    
    while_stmt: struct {
        condition: *Expr,
        body: *Stmt,
    },
    
    for_stmt: struct {
        init: ?*Expr,
        condition: ?*Expr,
        update: ?*Expr,
        body: *Stmt,
    },
    
    func_def: struct {
        name: []const u8,
        params: []const []const u8,
        auto_vars: []const []const u8,
        body: *Stmt,
        is_void: bool,
    },
    
    return_stmt: ?*Expr,
    
    break_stmt: void,
    continue_stmt: void,
    halt: void,
    quit: void,
    
    block: []const *Stmt,
};
```

### 5. VM - Virtual Machine State

```zig
pub const VM = struct {
    /// Allocator for all runtime allocations
    allocator: std.mem.Allocator,
    
    /// Global variables
    ibase: u8 = 10,
    obase: u8 = 10,
    scale: usize = 0,
    last: BigDec,
    
    /// User variables (a-z in dc, named in bc)
    variables: std.StringHashMap(BigDec),
    
    /// Arrays
    arrays: std.StringHashMap(std.ArrayList(BigDec)),
    
    /// User-defined functions
    functions: std.StringHashMap(Function),
    
    /// RPN stack (dc mode)
    stack: std.ArrayList(Value),
    
    /// Register stacks (dc mode) - each register is a stack
    registers: [256]std.ArrayList(Value),
    
    /// Execution stack for function calls
    call_stack: std.ArrayList(CallFrame),
    
    /// PRNG state
    rng: std.Random,
    seed: u64,
    
    /// I/O handles
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    
    /// Mode and flags
    mode: Mode,
    interactive: bool,
    color_enabled: bool,
    
    pub const Mode = enum { infix, rpn };
    
    pub const Value = union(enum) {
        number: BigDec,
        string: []const u8,
    };
    
    pub const CallFrame = struct {
        func: *const Function,
        locals: std.StringHashMap(BigDec),
        return_addr: usize,
    };
    
    pub const Function = struct {
        name: []const u8,
        params: []const []const u8,
        auto_vars: []const []const u8,
        body: *Stmt,
        is_void: bool,
    };
};
```

---

## Operator Precedence (Infix Mode)

Using comptime lookup tables:

```zig
pub const OpInfo = struct {
    prec: u8,
    assoc: Assoc,
    
    pub const Assoc = enum { left, right };
};

/// Operator precedence table (highest = 12)
/// Based on bc specification
pub const precedence = comptime blk: {
    var table = std.mem.zeroes([256]?OpInfo);
    
    // Precedence 12 (highest): Unary operators handled separately
    
    // Precedence 11: Power (right associative)
    table['^'] = .{ .prec = 11, .assoc = .right };
    
    // Precedence 10: Multiplicative
    table['*'] = .{ .prec = 10, .assoc = .left };
    table['/'] = .{ .prec = 10, .assoc = .left };
    table['%'] = .{ .prec = 10, .assoc = .left };
    
    // Precedence 9: Additive
    table['+'] = .{ .prec = 9, .assoc = .left };
    table['-'] = .{ .prec = 9, .assoc = .left };
    
    // Precedence 8: Shift (extension)
    // << and >> handled as compound tokens
    
    // Precedence 7: Relational
    // < > <= >= handled as compound tokens
    
    // Precedence 6: Equality
    // == != handled as compound tokens
    
    // Precedence 5: Boolean AND (extension)
    // && handled as compound token
    
    // Precedence 4: Boolean OR (extension)
    // || handled as compound token
    
    // Precedence 3: Assignment (right associative)
    table['='] = .{ .prec = 3, .assoc = .right };
    
    break :blk table;
};

/// Compound operator lookup
pub const compound_ops = std.StaticStringMap(OpInfo).initComptime(.{
    .{ "<<", .{ .prec = 8, .assoc = .left } },
    .{ ">>", .{ .prec = 8, .assoc = .left } },
    .{ "<",  .{ .prec = 7, .assoc = .left } },
    .{ ">",  .{ .prec = 7, .assoc = .left } },
    .{ "<=", .{ .prec = 7, .assoc = .left } },
    .{ ">=", .{ .prec = 7, .assoc = .left } },
    .{ "==", .{ .prec = 6, .assoc = .left } },
    .{ "!=", .{ .prec = 6, .assoc = .left } },
    .{ "&&", .{ .prec = 5, .assoc = .left } },
    .{ "||", .{ .prec = 4, .assoc = .left } },
    .{ "+=", .{ .prec = 3, .assoc = .right } },
    .{ "-=", .{ .prec = 3, .assoc = .right } },
    .{ "*=", .{ .prec = 3, .assoc = .right } },
    .{ "/=", .{ .prec = 3, .assoc = .right } },
    .{ "%=", .{ .prec = 3, .assoc = .right } },
    .{ "^=", .{ .prec = 3, .assoc = .right } },
});
```

---

## RPN Mode (dc-style)

Direct token-to-action mapping:

```zig
/// dc command table
pub const dc_commands = std.StaticStringMap(DcAction).initComptime(.{
    // Arithmetic
    .{ "+", .{ .action = .binary_op, .op = .add } },
    .{ "-", .{ .action = .binary_op, .op = .sub } },
    .{ "*", .{ .action = .binary_op, .op = .mul } },
    .{ "/", .{ .action = .binary_op, .op = .div } },
    .{ "%", .{ .action = .binary_op, .op = .mod } },
    .{ "^", .{ .action = .binary_op, .op = .pow } },
    .{ "v", .{ .action = .unary_op, .op = .sqrt } },
    .{ "|", .{ .action = .ternary_op, .op = .modexp } },
    
    // Stack
    .{ "c", .{ .action = .clear_stack } },
    .{ "d", .{ .action = .duplicate } },
    .{ "r", .{ .action = .swap } },
    .{ "R", .{ .action = .pop } },
    .{ "z", .{ .action = .push_depth } },
    
    // Printing
    .{ "p", .{ .action = .print_peek } },
    .{ "n", .{ .action = .print_pop } },
    .{ "f", .{ .action = .print_stack } },
    .{ "P", .{ .action = .print_string } },
    
    // Parameters
    .{ "i", .{ .action = .set_ibase } },
    .{ "o", .{ .action = .set_obase } },
    .{ "k", .{ .action = .set_scale } },
    .{ "I", .{ .action = .push_ibase } },
    .{ "O", .{ .action = .push_obase } },
    .{ "K", .{ .action = .push_scale } },
    
    // Registers (s, l, S, L followed by register name)
    .{ "s", .{ .action = .store_register } },
    .{ "l", .{ .action = .load_register } },
    .{ "S", .{ .action = .push_register } },
    .{ "L", .{ .action = .pop_register } },
    
    // Comparison
    .{ "G", .{ .action = .compare, .cmp = .eq } },
    .{ "(", .{ .action = .compare, .cmp = .lt } },
    .{ ")", .{ .action = .compare, .cmp = .gt } },
    .{ "{", .{ .action = .compare, .cmp = .le } },
    .{ "}", .{ .action = .compare, .cmp = .ge } },
    
    // Execution
    .{ "x", .{ .action = .execute } },
    .{ "?", .{ .action = .read_input } },
    .{ "q", .{ .action = .quit } },
    .{ "Q", .{ .action = .quit_n } },
    
    // Status
    .{ "Z", .{ .action = .push_digits } },
    .{ "X", .{ .action = .push_scale_of } },
});
```

---

## Zig 0.16.0 I/O Patterns

**IMPORTANT**: Zig 0.16.0 uses the new "Writergate" I/O APIs. Buffers are in the interface, not the implementation.

The shipped REPL reads stdin byte-by-byte with `takeByte` (Zig 0.16 Windows EOF workaround). Do not switch it to `takeDelimiterExclusive`. In infix mode, the REPL joins lines while `{` / `}` stay unbalanced (skipping braces inside comments and `[...]` strings) and prints a `..>` continuation prompt. A trailing `\` splices the next line. Meta commands that start with `:` abort a partial define. Assignment statements store the value and do not print it (POSIX bc). GNU bc prints the stored value as an extension.

```zig
const std = @import("std");

pub fn main() !void {
    // Allocate buffers for I/O
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_buffer: [4096]u8 = undefined;
    
    // Create writers/readers with buffers
    var stdout_wrapper = std.fs.File.stdout().writer(&stdout_buffer);
    var stdin_wrapper = std.fs.File.stdin().reader(&stdin_buffer);
    
    // Get the interface pointers
    const stdout: *std.Io.Writer = &stdout_wrapper.interface;
    const stdin: *std.Io.Reader = &stdin_wrapper.interface;
    
    // REPL loop
    while (true) {
        // Write prompt with color
        try stdout.writeAll("\x1b[32mac>\x1b[0m ");
        try stdout.flush();  // CRITICAL: Must flush!
        
        // Read input
        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        
        // Process line...
        try stdout.print("Result: {s}\n", .{result});
        try stdout.flush();
    }
}
```

---

## Built-in Functions

### POSIX bc Standard Library (`-l`)

| Function | Description | Implementation |
|----------|-------------|----------------|
| `s(x)` | sin(x) in radians | Taylor series |
| `c(x)` | cos(x) in radians | sin(x + pi/2) |
| `a(x)` | atan(x) | Taylor series |
| `l(x)` | ln(x) | Series + reduction |
| `e(x)` | e^x | Taylor series + reduction |
| `j(n,x)` | Bessel J_n(x) | Series |

### Extended Library (Non-POSIX)

| Function | Description |
|----------|-------------|
| `abs(x)` | Absolute value |
| `sqrt(x)` | Square root (also builtin) |
| `pi(s)` | Pi to s decimal places |
| `t(x)` / `tan(x)` | Tangent |
| `sin(x)` / `cos(x)` | Aliases |
| `r(x,p)` | Round to p places |
| `ceil(x,p)` | Ceiling to p places |
| `f(n)` | Factorial |
| `perm(n,k)` | Permutations |
| `comb(n,k)` | Combinations |
| `gcd(a,b)` | GCD |
| `lcm(a,b)` | LCM |
| `log(x,b)` | Log base b |
| `l2(x)` / `l10(x)` | Log base 2/10 |
| `root(x,n)` | Nth root |
| `cbrt(x)` | Cube root |
| `max(a,b)` / `min(a,b)` | Maximum/minimum |
| `rand()` | Random [0, RAND_MAX] |
| `irand(n)` | Random [0, n-1] |
| `modexp(b,e,m)` | Modular exponentiation |

### Bitwise Functions (Extension)

| Function | Description |
|----------|-------------|
| `band(a,b)` | Bitwise AND |
| `bor(a,b)` | Bitwise OR |
| `bxor(a,b)` | Bitwise XOR |
| `bnot8/16/32/64(x)` | Bitwise NOT |
| `bshl(a,b)` | Bitwise shift left |
| `bshr(a,b)` | Bitwise shift right |

---

## Color Scheme (TUI)

```zig
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    
    // Prompt
    pub const prompt = "\x1b[32m";        // green
    pub const prompt_rpn = "\x1b[36m";    // cyan
    
    // Numbers
    pub const number = "\x1b[33m";        // yellow
    pub const number_neg = "\x1b[31m";    // red for negative
    
    // Operators
    pub const operator = "\x1b[35m";      // magenta
    
    // Errors
    pub const err = "\x1b[31;1m";         // bold red
    
    // Keywords
    pub const keyword = "\x1b[34;1m";     // bold blue
    
    // Strings
    pub const string = "\x1b[32m";        // green
    
    // Comments
    pub const comment = "\x1b[90m";       // gray
};
```

---

## Error Handling

```zig
pub const Error = error{
    // Parse errors
    UnexpectedToken,
    UnterminatedString,
    InvalidNumber,
    InvalidBase,
    
    // Runtime errors
    DivisionByZero,
    NegativeSquareRoot,
    NonIntegerExponent,
    StackUnderflow,
    UndefinedVariable,
    UndefinedFunction,
    WrongArgCount,
    InvalidScale,
    
    // System errors
    OutOfMemory,
    IoError,
};

pub const ErrorInfo = struct {
    err: Error,
    message: []const u8,
    line: u32,
    column: u32,
    source_line: ?[]const u8,
};
```

---

## CLI Interface

```
USAGE:
    ac [OPTIONS] [FILE...]

OPTIONS:
    -h, --help          Show this help
    -v, --version       Show version
    -l, --mathlib       Load standard math library
    -q, --quiet         Don't print version on startup
    -s, --standard      POSIX-compliant mode only
    -w, --warn          Warn on non-standard extensions
    -e EXPR             Evaluate expression and exit
    
    --rpn               Start in RPN (dc) mode
    --infix             Start in infix (bc) mode [default]
    --no-color          Disable colored output
    --gnu               Print assignment values (GNU bc)
    --scale=N           Set initial scale
    --ibase=N           Set initial input base
    --obase=N           Set initial output base

INTERACTIVE COMMANDS:
    :rpn, :dc           Switch to RPN mode
    :infix, :bc         Switch to infix mode
    :help               Show help
    :quit, :q           Exit
    :clear              Clear screen
    :vars               Show all variables
    :funcs              Show all functions
```

---

## Implementation Phases

### Phase 1: MVP (Core Calculator)
- [x] Project setup (build.zig, build.zig.zon)
- [x] BigDec: add, sub, mul, div, mod, pow, sqrt (add/sub/mul exact; clip on print and / % sqrt pow)
- [x] Lexer for numbers and basic operators
- [x] Infix parser (Pratt parsing)
- [x] Basic evaluator
- [x] REPL with Zig 0.16.0 I/O (byte-by-byte takeByte; Windows EOF workaround)
- [x] Variables: scale, ibase, obase, last (ibase/obase clamped 2..=16)

### Phase 2: RPN Mode
- [x] RPN lexer (single-char commands)
- [x] Stack operations
- [x] Register operations (s/l share infix vars; S/L hidden stacks)
- [x] dc macros: x, >r <r =r, ?, q/Q
- [x] Mode switching (:rpn / :infix)
- [x] dc leftovers used in real scripts: Z (digit count), X (scale-of), | (modexp), array registers :/;

### Phase 3: Control Flow
- [x] if/else statements
- [x] while loops
- [x] for loops
- [x] User-defined functions (recursive auto/arrays via Frame stack)
- [x] break/continue

### Phase 4: Math Library
- [x] POSIX -l: s(x), c(x), a(x), l(x), e(x), j(n,x); also pi() (hardcoded Zig, gated by -l; -l sets scale=20)
- [x] tan, asin, acos aliases; longer names (sin, cos, atan, t)
- [x] Logarithmic extras: log, log2, log10
- [x] Utility: abs, ceil, floor, round
- [x] Number theory: gcd, lcm, factorial builtin

### Phase 5: TUI Polish
- [x] ANSI color output (disabled when stdin is not a tty; --no-color)
- [x] Syntax highlighting (REPL input: keywords, numbers, operators, comments, strings)
- [x] Line editing with history (`~/.ac_history`; arrows, backspace)
- [x] Tab completion
- [x] Better error messages with context (caret diagnostics)

### Phase 6: Extensions
- [x] Bitwise operations
- [x] Random number generation
- [x] Modular exponentiation (dc `|`)
- [x] Scientific/engineering notation I/O (`1.5e-3` input; `sci(x)` / `eng(x)` strings)
- [x] Strings as bounded values (assign/print/dc stack; no arithmetic)

---

## Testing Strategy

1. **Unit Tests**: Each module has inline tests
2. **Integration Tests**: Full expression evaluation
3. **Compatibility Tests**: `tests/posix/` fixture pack (arith, scale, obase, fact, REPL multiline define, length, arrays, loops, extras, extras_mathlib, -l mathlib including j(), dc macros, dc Z/X/|/arrays)
4. **Fuzz Testing**: Random integer `+` `-` `*` in `eval.zig`
5. **Benchmarks**: Karatsuba vs schoolbook mul in `num.zig` (`zig build test`)

---

## References

- [POSIX bc specification](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/bc.html)
- [gavinhoward/bc](https://github.com/gavinhoward/bc) - Reference implementation
- [GNU bc manual](https://www.gnu.org/software/bc/manual/bc.html)
- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html) - Writergate
- [Karatsuba algorithm](https://en.wikipedia.org/wiki/Karatsuba_algorithm)
- [Newton-Raphson method](https://en.wikipedia.org/wiki/Newton%27s_method)
