const lex = @import("lexer.zig");

pub const ParseError = error{ MalformedToken, InvalidSyntax };

pub const Failure = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid syntax",
};

const PrefixKind = enum { value, assignable, call };

pub const Parser = struct {
    lexer: lex.Lexer,
    current: lex.Token = undefined,
    failure: Failure = .{},

    pub fn init(source: []const u8) error{MalformedToken}!Parser {
        var parser: Parser = .{ .lexer = lex.Lexer.init(source) };
        parser.current = parser.lexer.next() catch {
            parser.copyLexFailure();
            return error.MalformedToken;
        };
        return parser;
    }

    pub fn parse(self: *Parser) error{ MalformedToken, InvalidSyntax }!void {
        try self.block(&.{.eof});
        try self.expect(.eof, "expected end of file");
    }

    fn block(self: *Parser, stops: []const lex.Tag) ParseError!void {
        while (!contains(stops, self.current.tag) and self.current.tag != .eof) {
            try self.statement();
            _ = try self.accept(.semicolon);
        }
    }

    fn statement(self: *Parser) ParseError!void {
        switch (self.current.tag) {
            .kw_do => {
                try self.advance();
                try self.block(&.{.kw_end});
                try self.expect(.kw_end, "expected 'end' after do block");
            },
            .kw_while => {
                try self.advance();
                try self.expression();
                try self.expect(.kw_do, "expected 'do' after while condition");
                try self.block(&.{.kw_end});
                try self.expect(.kw_end, "expected 'end' after while loop");
            },
            .kw_repeat => {
                try self.advance();
                try self.block(&.{.kw_until});
                try self.expect(.kw_until, "expected 'until' after repeat block");
                try self.expression();
            },
            .kw_if => try self.ifStatement(),
            .kw_for => try self.forStatement(),
            .kw_function => {
                try self.advance();
                try self.expect(.name, "expected function name");
                while (try self.accept(.dot)) try self.expect(.name, "expected name after '.'");
                if (try self.accept(.colon)) try self.expect(.name, "expected method name");
                try self.functionBody();
            },
            .kw_local => try self.localStatement(),
            .kw_return => {
                try self.advance();
                if (!contains(&.{ .eof, .kw_end, .kw_else, .kw_elseif, .kw_until, .semicolon }, self.current.tag))
                    try self.expressionList();
            },
            .kw_break => try self.advance(),
            else => try self.assignmentOrCall(),
        }
    }

    fn ifStatement(self: *Parser) ParseError!void {
        try self.advance();
        try self.expression();
        try self.expect(.kw_then, "expected 'then'");
        try self.block(&.{ .kw_elseif, .kw_else, .kw_end });
        while (try self.accept(.kw_elseif)) {
            try self.expression();
            try self.expect(.kw_then, "expected 'then' after elseif condition");
            try self.block(&.{ .kw_elseif, .kw_else, .kw_end });
        }
        if (try self.accept(.kw_else)) try self.block(&.{.kw_end});
        try self.expect(.kw_end, "expected 'end' after if statement");
    }

    fn forStatement(self: *Parser) ParseError!void {
        try self.advance();
        try self.expect(.name, "expected loop variable");
        if (try self.accept(.assign)) {
            try self.expression();
            try self.expect(.comma, "expected ',' in numeric for loop");
            try self.expression();
            if (try self.accept(.comma)) try self.expression();
        } else {
            while (try self.accept(.comma)) try self.expect(.name, "expected loop variable");
            try self.expect(.kw_in, "expected 'in' in generic for loop");
            try self.expressionList();
        }
        try self.expect(.kw_do, "expected 'do' in for loop");
        try self.block(&.{.kw_end});
        try self.expect(.kw_end, "expected 'end' after for loop");
    }

    fn localStatement(self: *Parser) ParseError!void {
        try self.advance();
        if (try self.accept(.kw_function)) {
            try self.expect(.name, "expected local function name");
            return self.functionBody();
        }
        try self.expect(.name, "expected local variable name");
        while (try self.accept(.comma)) try self.expect(.name, "expected local variable name");
        if (try self.accept(.assign)) try self.expressionList();
    }

    fn assignmentOrCall(self: *Parser) ParseError!void {
        const first = try self.prefixExpression();
        if (first == .call and self.current.tag != .assign and self.current.tag != .comma) return;
        if (first != .assignable) return self.syntax("expected assignment or function call");
        while (try self.accept(.comma)) {
            if (try self.prefixExpression() != .assignable) return self.syntax("expected assignable expression");
        }
        try self.expect(.assign, "expected '=' in assignment");
        try self.expressionList();
    }

    fn expressionList(self: *Parser) ParseError!void {
        try self.expression();
        while (try self.accept(.comma)) try self.expression();
    }

    fn expression(self: *Parser) ParseError!void {
        try self.subExpression(0);
    }

    fn subExpression(self: *Parser, minimum: u8) ParseError!void {
        if (self.current.tag == .kw_not or self.current.tag == .minus or self.current.tag == .hash) {
            try self.advance();
            try self.subExpression(7);
        } else try self.simpleExpression();

        while (binaryPrecedence(self.current.tag)) |precedence| {
            if (precedence.left < minimum) break;
            try self.advance();
            try self.subExpression(precedence.right);
        }
    }

    fn simpleExpression(self: *Parser) ParseError!void {
        switch (self.current.tag) {
            .kw_nil, .kw_false, .kw_true, .number, .string, .varargs => try self.advance(),
            .kw_function => {
                try self.advance();
                try self.functionBody();
            },
            .l_brace => try self.tableConstructor(),
            .name, .l_paren => _ = try self.prefixExpression(),
            else => return self.syntax("expected expression"),
        }
    }

    fn prefixExpression(self: *Parser) ParseError!PrefixKind {
        var kind: PrefixKind = undefined;
        if (try self.accept(.l_paren)) {
            try self.expression();
            try self.expect(.r_paren, "expected ')' after expression");
            kind = .value;
        } else {
            try self.expect(.name, "expected name or parenthesized expression");
            kind = .assignable;
        }
        while (true) switch (self.current.tag) {
            .l_bracket => {
                try self.advance();
                try self.expression();
                try self.expect(.r_bracket, "expected ']' after index");
                kind = .assignable;
            },
            .dot => {
                try self.advance();
                try self.expect(.name, "expected field name");
                kind = .assignable;
            },
            .colon => {
                try self.advance();
                try self.expect(.name, "expected method name");
                try self.arguments();
                kind = .call;
            },
            .l_paren, .l_brace, .string => {
                try self.arguments();
                kind = .call;
            },
            else => return kind,
        };
    }

    fn arguments(self: *Parser) ParseError!void {
        if (try self.accept(.l_paren)) {
            if (self.current.tag != .r_paren) try self.expressionList();
            try self.expect(.r_paren, "expected ')' after arguments");
        } else if (self.current.tag == .l_brace) {
            try self.tableConstructor();
        } else try self.expect(.string, "expected function arguments");
    }

    fn functionBody(self: *Parser) ParseError!void {
        try self.expect(.l_paren, "expected '(' before parameters");
        if (self.current.tag != .r_paren) {
            if (!try self.accept(.varargs)) {
                try self.expect(.name, "expected parameter name");
                while (try self.accept(.comma)) {
                    if (try self.accept(.varargs)) break;
                    try self.expect(.name, "expected parameter name");
                }
            }
        }
        try self.expect(.r_paren, "expected ')' after parameters");
        try self.block(&.{.kw_end});
        try self.expect(.kw_end, "expected 'end' after function body");
    }

    fn tableConstructor(self: *Parser) ParseError!void {
        try self.expect(.l_brace, "expected '{'");
        while (self.current.tag != .r_brace) {
            if (try self.accept(.l_bracket)) {
                try self.expression();
                try self.expect(.r_bracket, "expected ']' in table field");
                try self.expect(.assign, "expected '=' in table field");
                try self.expression();
            } else if (self.current.tag == .name and try self.peekTag() == .assign) {
                try self.advance();
                try self.advance();
                try self.expression();
            } else try self.expression();
            if (!try self.accept(.comma) and !try self.accept(.semicolon)) break;
        }
        try self.expect(.r_brace, "expected '}' after table constructor");
    }

    fn peekTag(self: *Parser) error{MalformedToken}!lex.Tag {
        var copy = self.lexer;
        return (copy.next() catch return error.MalformedToken).tag;
    }

    fn accept(self: *Parser, tag: lex.Tag) ParseError!bool {
        if (self.current.tag != tag) return false;
        try self.advance();
        return true;
    }
    fn expect(self: *Parser, tag: lex.Tag, message: []const u8) ParseError!void {
        if (self.current.tag != tag) return self.syntax(message);
        try self.advance();
    }
    fn advance(self: *Parser) error{MalformedToken}!void {
        self.current = self.lexer.next() catch {
            self.copyLexFailure();
            return error.MalformedToken;
        };
    }
    fn syntax(self: *Parser, message: []const u8) error{InvalidSyntax} {
        self.failure = .{ .line = self.current.line, .column = self.current.column, .message = message };
        return error.InvalidSyntax;
    }
    fn copyLexFailure(self: *Parser) void {
        self.failure = .{ .line = self.lexer.failure.line, .column = self.lexer.failure.column, .message = self.lexer.failure.message };
    }
};

fn contains(tags: []const lex.Tag, tag: lex.Tag) bool {
    for (tags) |candidate| if (candidate == tag) return true;
    return false;
}

const Precedence = struct { left: u8, right: u8 };
fn binaryPrecedence(tag: lex.Tag) ?Precedence {
    return switch (tag) {
        .kw_or => .{ .left = 1, .right = 2 },
        .kw_and => .{ .left = 2, .right = 3 },
        .less, .less_eq, .greater, .greater_eq, .not_eq, .eq_eq => .{ .left = 3, .right = 4 },
        .concat => .{ .left = 5, .right = 4 }, // right associative
        .plus, .minus => .{ .left = 5, .right = 6 },
        .star, .slash, .percent => .{ .left = 6, .right = 7 },
        .caret => .{ .left = 8, .right = 7 }, // right associative
        else => null,
    };
}

const std = @import("std");
test "parses representative Lua 5.1 program" {
    const source =
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n-1) + fib(n-2)
        \\end
        \\local t = { answer = 42, [1] = fib(8), 9 }
        \\for k, v in pairs(t) do print(k, v) end
    ;
    var parser = try Parser.init(source);
    try parser.parse();
}

test "rejects incomplete blocks" {
    var parser = try Parser.init("if true then print(1)");
    try std.testing.expectError(error.InvalidSyntax, parser.parse());
}
