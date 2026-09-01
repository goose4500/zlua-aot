const std = @import("std");

pub const Tag = enum {
    eof,
    name,
    number,
    string,
    kw_and,
    kw_break,
    kw_do,
    kw_else,
    kw_elseif,
    kw_end,
    kw_false,
    kw_for,
    kw_function,
    kw_if,
    kw_in,
    kw_local,
    kw_nil,
    kw_not,
    kw_or,
    kw_repeat,
    kw_return,
    kw_then,
    kw_true,
    kw_until,
    kw_while,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    hash,
    eq,
    eq_eq,
    not_eq,
    less,
    less_eq,
    greater,
    greater_eq,
    assign,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semicolon,
    colon,
    comma,
    dot,
    concat,
    varargs,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
    line: usize,
    column: usize,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Failure = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid token",
};

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    failure: Failure = .{},

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) error{MalformedToken}!Token {
        try self.skipTrivia();
        const start = self.index;
        const line = self.line;
        const column = self.column;
        if (self.peek(0) == null) return .{ .tag = .eof, .start = start, .end = start, .line = line, .column = column };
        const c = self.peek(0).?;

        if (isNameStart(c)) {
            self.advance();
            while (self.peek(0)) |n| if (isNameContinue(n)) self.advance() else break;
            const text_value = self.source[start..self.index];
            return self.token(keyword(text_value) orelse .name, start, line, column);
        }
        if (isDigit(c) or (c == '.' and self.peek(1) != null and isDigit(self.peek(1).?)))
            return self.scanNumber(start, line, column);
        if (c == '\'' or c == '"') return self.scanQuoted(start, line, column, c);
        if (c == '[') if (longBracketLevel(self.source, self.index)) |level|
            return self.scanLong(start, line, column, level, .string);

        const tag: Tag = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '^' => .caret,
            '#' => .hash,
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ';' => .semicolon,
            ':' => .colon,
            ',' => .comma,
            '=' => if (self.peek(1) == '=') .eq_eq else .assign,
            '~' => if (self.peek(1) == '=') .not_eq else return self.fail("expected '=' after '~'"),
            '<' => if (self.peek(1) == '=') .less_eq else .less,
            '>' => if (self.peek(1) == '=') .greater_eq else .greater,
            '.' => if (self.peek(1) == '.' and self.peek(2) == '.') .varargs else if (self.peek(1) == '.') .concat else .dot,
            else => return self.fail("unexpected character"),
        };
        self.advance();
        if (tag == .eq_eq or tag == .not_eq or tag == .less_eq or tag == .greater_eq or tag == .concat) self.advance();
        if (tag == .varargs) {
            self.advance();
            self.advance();
        }
        return self.token(tag, start, line, column);
    }

    fn skipTrivia(self: *Lexer) error{MalformedToken}!void {
        while (true) {
            while (self.peek(0)) |c| if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0b' or c == '\x0c') self.advance() else break;
            if (self.peek(0) != '-' or self.peek(1) != '-') return;
            self.advance();
            self.advance();
            if (self.peek(0) == '[') if (longBracketLevel(self.source, self.index)) |level| {
                _ = try self.scanLong(self.index, self.line, self.column, level, .string);
                continue;
            };
            while (self.peek(0)) |c| {
                self.advance();
                if (c == '\n') break;
            }
        }
    }

    fn scanNumber(self: *Lexer, start: usize, line: usize, column: usize) error{MalformedToken}!Token {
        if (self.peek(0) == '0' and (self.peek(1) == 'x' or self.peek(1) == 'X')) {
            self.advance();
            self.advance();
            var has_digit = false;
            while (self.peek(0)) |c| if (isHex(c)) {
                has_digit = true;
                self.advance();
            } else break;
            if (self.peek(0) == '.') {
                self.advance();
                while (self.peek(0)) |c| if (isHex(c)) {
                    has_digit = true;
                    self.advance();
                } else break;
            }
            if (!has_digit) return self.fail("hexadecimal literal requires a digit");
            if (self.peek(0) == 'p' or self.peek(0) == 'P') try self.scanExponent();
        } else {
            while (self.peek(0)) |c| if (isDigit(c)) self.advance() else break;
            if (self.peek(0) == '.') {
                self.advance();
                while (self.peek(0)) |c| if (isDigit(c)) self.advance() else break;
            }
            if (self.peek(0) == 'e' or self.peek(0) == 'E') try self.scanExponent();
        }
        // LuaJIT cdata numeric extensions.
        if (self.peek(0) == 'u' or self.peek(0) == 'U') self.advance();
        if (self.peek(0) == 'l' or self.peek(0) == 'L') {
            self.advance();
            if (self.peek(0) == 'l' or self.peek(0) == 'L') self.advance();
        }
        if (self.peek(0) == 'i' or self.peek(0) == 'I') self.advance();
        if (self.peek(0)) |c| if (isNameStart(c)) return self.fail("malformed numeric literal");
        return self.token(.number, start, line, column);
    }

    fn scanExponent(self: *Lexer) error{MalformedToken}!void {
        self.advance();
        if (self.peek(0) == '+' or self.peek(0) == '-') self.advance();
        const digits = self.index;
        while (self.peek(0)) |c| if (isDigit(c)) self.advance() else break;
        if (self.index == digits) return self.fail("exponent requires a digit");
    }

    fn scanQuoted(self: *Lexer, start: usize, line: usize, column: usize, quote: u8) error{MalformedToken}!Token {
        self.advance();
        while (self.peek(0)) |c| {
            if (c == quote) {
                self.advance();
                return self.token(.string, start, line, column);
            }
            if (c == '\n' or c == '\r') return self.fail("unfinished string");
            self.advance();
            if (c == '\\') {
                if (self.peek(0) == null) return self.fail("unfinished escape sequence");
                if (self.peek(0) == '\r') {
                    self.advance();
                    if (self.peek(0) == '\n') self.advance();
                } else self.advance();
            }
        }
        return self.fail("unfinished string");
    }

    fn scanLong(self: *Lexer, start: usize, line: usize, column: usize, level: usize, tag: Tag) error{MalformedToken}!Token {
        self.advance();
        for (0..level) |_| self.advance();
        self.advance();
        while (self.peek(0) != null) {
            if (self.peek(0) == ']' and longCloseLevel(self.source, self.index, level)) {
                self.advance();
                for (0..level) |_| self.advance();
                self.advance();
                return self.token(tag, start, line, column);
            }
            self.advance();
        }
        return self.fail("unfinished long string or comment");
    }

    fn token(self: *Lexer, tag: Tag, start: usize, line: usize, column: usize) Token {
        return .{ .tag = tag, .start = start, .end = self.index, .line = line, .column = column };
    }
    fn fail(self: *Lexer, message: []const u8) error{MalformedToken} {
        self.failure = .{ .line = self.line, .column = self.column, .message = message };
        return error.MalformedToken;
    }
    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const at = self.index + offset;
        return if (at < self.source.len) self.source[at] else null;
    }
    fn advance(self: *Lexer) void {
        if (self.index >= self.source.len) return;
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else self.column += 1;
    }
};

fn longBracketLevel(source: []const u8, start: usize) ?usize {
    if (start >= source.len or source[start] != '[') return null;
    var i = start + 1;
    while (i < source.len and source[i] == '=') i += 1;
    return if (i < source.len and source[i] == '[') i - start - 1 else null;
}
fn longCloseLevel(source: []const u8, start: usize, level: usize) bool {
    if (start >= source.len or source[start] != ']') return false;
    var i = start + 1;
    for (0..level) |_| {
        if (i >= source.len or source[i] != '=') return false;
        i += 1;
    }
    return i < source.len and source[i] == ']';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isNameStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isNameContinue(c: u8) bool {
    return isNameStart(c) or isDigit(c);
}
fn keyword(s: []const u8) ?Tag {
    const words = .{
        .{ "and", Tag.kw_and },           .{ "break", Tag.kw_break }, .{ "do", Tag.kw_do },       .{ "else", Tag.kw_else },
        .{ "elseif", Tag.kw_elseif },     .{ "end", Tag.kw_end },     .{ "false", Tag.kw_false }, .{ "for", Tag.kw_for },
        .{ "function", Tag.kw_function }, .{ "if", Tag.kw_if },       .{ "in", Tag.kw_in },       .{ "local", Tag.kw_local },
        .{ "nil", Tag.kw_nil },           .{ "not", Tag.kw_not },     .{ "or", Tag.kw_or },       .{ "repeat", Tag.kw_repeat },
        .{ "return", Tag.kw_return },     .{ "then", Tag.kw_then },   .{ "true", Tag.kw_true },   .{ "until", Tag.kw_until },
        .{ "while", Tag.kw_while },
    };
    inline for (words) |entry| if (std.mem.eql(u8, s, entry[0])) return entry[1];
    return null;
}

test "lexes Lua 5.1 surface syntax" {
    var lexer = Lexer.init("local x = 0x2a + 1.5e2 .. [[ok]] -- comment\nreturn x ~= nil");
    var count: usize = 0;
    while (true) {
        const token_value = try lexer.next();
        count += 1;
        if (token_value.tag == .eof) break;
    }
    try std.testing.expectEqual(@as(usize, 13), count);
}

test "reports malformed strings" {
    var lexer = Lexer.init("'oops");
    try std.testing.expectError(error.MalformedToken, lexer.next());
    try std.testing.expectEqual(@as(usize, 1), lexer.failure.line);
}
