const std = @import("std");
const lex = @import("lexer.zig");
const ast_types = @import("ast.zig");

pub const NodeKind = ast_types.NodeKind;
pub const Node = ast_types.Node;
pub const SymbolKind = ast_types.SymbolKind;
pub const Symbol = ast_types.Symbol;
pub const Resolution = ast_types.Resolution;
pub const Reference = ast_types.Reference;
pub const Ast = ast_types.Ast;

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
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    references: std.ArrayList(Reference) = .empty,
    active_symbols: std.ArrayList(usize) = .empty,
    loop_depth: usize = 0,
    function_depth: usize = 0,
    vararg_function: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) error{MalformedToken}!Parser {
        var parser: Parser = .{ .lexer = lex.Lexer.init(source), .allocator = allocator };
        parser.current = parser.lexer.next() catch {
            parser.copyLexFailure();
            return error.MalformedToken;
        };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.references.deinit(self.allocator);
        self.active_symbols.deinit(self.allocator);
    }

    pub fn takeAst(self: *Parser) Ast {
        const result: Ast = .{ .allocator = self.allocator, .nodes = self.nodes, .symbols = self.symbols, .references = self.references };
        self.nodes = .empty;
        self.symbols = .empty;
        self.references = .empty;
        return result;
    }

    pub fn parse(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        const start = self.current.start;
        try self.block(&.{.eof});
        try self.addNode(.chunk, start);
        try self.expect(.eof, "expected end of file");
    }

    fn addNode(self: *Parser, kind: NodeKind, start: usize) std.mem.Allocator.Error!void {
        try self.nodes.append(self.allocator, .{ .kind = kind, .start = start, .end = self.current.start });
    }

    fn block(self: *Parser, stops: []const lex.Tag) (ParseError || std.mem.Allocator.Error)!void {
        const symbol_mark = self.active_symbols.items.len;
        defer self.active_symbols.items.len = symbol_mark;
        try self.blockContents(stops);
    }

    fn blockContents(self: *Parser, stops: []const lex.Tag) (ParseError || std.mem.Allocator.Error)!void {
        while (!contains(stops, self.current.tag) and self.current.tag != .eof) {
            try self.statement();
            _ = try self.accept(.semicolon);
        }
    }

    fn statement(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        const start = self.current.start;
        const kind: NodeKind = switch (self.current.tag) {
            .kw_do => blk: {
                try self.advance();
                try self.block(&.{.kw_end});
                try self.expect(.kw_end, "expected 'end' after do block");
                break :blk .block;
            },
            .kw_while => blk: {
                try self.advance();
                try self.expression();
                try self.expect(.kw_do, "expected 'do' after while condition");
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.block(&.{.kw_end});
                try self.expect(.kw_end, "expected 'end' after while loop");
                break :blk .while_loop;
            },
            .kw_repeat => blk: {
                try self.advance();
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                const active_mark = self.active_symbols.items.len;
                defer self.active_symbols.items.len = active_mark;
                try self.blockContents(&.{.kw_until});
                try self.expect(.kw_until, "expected 'until' after repeat block");
                try self.expression();
                break :blk .repeat_loop;
            },
            .kw_if => blk: {
                try self.ifStatement();
                break :blk .if_statement;
            },
            .kw_for => blk: {
                try self.forStatement();
                break :blk .for_loop;
            },
            .kw_function => blk: {
                try self.advance();
                if (self.current.tag != .name) return self.syntax("expected function name");
                try self.recordReference(self.current);
                try self.advance();
                while (try self.accept(.dot)) try self.expect(.name, "expected name after '.'");
                if (try self.accept(.colon)) try self.expect(.name, "expected method name");
                try self.functionBody();
                break :blk .function;
            },
            .kw_local => blk: {
                try self.localStatement();
                break :blk .local;
            },
            .kw_return => blk: {
                try self.advance();
                if (!contains(&.{ .eof, .kw_end, .kw_else, .kw_elseif, .kw_until, .semicolon }, self.current.tag)) try self.expressionList();
                break :blk .return_statement;
            },
            .kw_break => blk: {
                if (self.loop_depth == 0) return self.syntax("'break' is only valid inside a loop");
                try self.advance();
                break :blk .break_statement;
            },
            else => blk: {
                const assignment = try self.assignmentOrCall();
                break :blk if (assignment) .assignment else .call;
            },
        };
        try self.addNode(kind, start);
    }

    fn ifStatement(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
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

    fn forStatement(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        try self.advance();
        var names: std.ArrayList(lex.Token) = .empty;
        defer names.deinit(self.allocator);
        if (self.current.tag != .name) return self.syntax("expected loop variable");
        try names.append(self.allocator, self.current);
        try self.advance();
        if (try self.accept(.assign)) {
            try self.expression();
            try self.expect(.comma, "expected ',' in numeric for loop");
            try self.expression();
            if (try self.accept(.comma)) try self.expression();
        } else {
            while (try self.accept(.comma)) {
                if (self.current.tag != .name) return self.syntax("expected loop variable");
                try names.append(self.allocator, self.current);
                try self.advance();
            }
            try self.expect(.kw_in, "expected 'in' in generic for loop");
            try self.expressionList();
        }
        try self.expect(.kw_do, "expected 'do' in for loop");
        const active_mark = self.active_symbols.items.len;
        defer self.active_symbols.items.len = active_mark;
        for (names.items) |name| try self.declare(name, .local);
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        try self.block(&.{.kw_end});
        try self.expect(.kw_end, "expected 'end' after for loop");
    }

    fn localStatement(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        try self.advance();
        if (try self.accept(.kw_function)) {
            if (self.current.tag != .name) return self.syntax("expected local function name");
            const name = self.current;
            try self.advance();
            try self.declare(name, .local); // recursive local function sees itself
            return self.functionBody();
        }
        var names: std.ArrayList(lex.Token) = .empty;
        defer names.deinit(self.allocator);
        if (self.current.tag != .name) return self.syntax("expected local variable name");
        try names.append(self.allocator, self.current);
        try self.advance();
        while (try self.accept(.comma)) {
            if (self.current.tag != .name) return self.syntax("expected local variable name");
            try names.append(self.allocator, self.current);
            try self.advance();
        }
        if (try self.accept(.assign)) try self.expressionList();
        for (names.items) |name| try self.declare(name, .local);
    }

    fn assignmentOrCall(self: *Parser) (ParseError || std.mem.Allocator.Error)!bool {
        const first = try self.prefixExpression();
        if (first == .call and self.current.tag != .assign and self.current.tag != .comma) return false;
        if (first != .assignable) return self.syntax("expected assignment or function call");
        while (try self.accept(.comma)) {
            if (try self.prefixExpression() != .assignable) return self.syntax("expected assignable expression");
        }
        try self.expect(.assign, "expected '=' in assignment");
        try self.expressionList();
        return true;
    }

    fn expressionList(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        try self.expression();
        while (try self.accept(.comma)) try self.expression();
    }

    fn expression(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        const start = self.current.start;
        try self.subExpression(0);
        try self.addNode(.expression, start);
    }

    fn subExpression(self: *Parser, minimum: u8) (ParseError || std.mem.Allocator.Error)!void {
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

    fn simpleExpression(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        switch (self.current.tag) {
            .kw_nil, .kw_false, .kw_true, .number, .string => try self.advance(),
            .varargs => {
                if (!self.vararg_function) return self.syntax("'...' is only valid inside a vararg function");
                try self.advance();
            },
            .kw_function => {
                try self.advance();
                try self.functionBody();
            },
            .l_brace => try self.tableConstructor(),
            .name, .l_paren => _ = try self.prefixExpression(),
            else => return self.syntax("expected expression"),
        }
    }

    fn prefixExpression(self: *Parser) (ParseError || std.mem.Allocator.Error)!PrefixKind {
        var kind: PrefixKind = undefined;
        if (try self.accept(.l_paren)) {
            try self.expression();
            try self.expect(.r_paren, "expected ')' after expression");
            kind = .value;
        } else {
            if (self.current.tag != .name) return self.syntax("expected name or parenthesized expression");
            try self.recordReference(self.current);
            try self.advance();
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

    fn arguments(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        if (try self.accept(.l_paren)) {
            if (self.current.tag != .r_paren) try self.expressionList();
            try self.expect(.r_paren, "expected ')' after arguments");
        } else if (self.current.tag == .l_brace) {
            try self.tableConstructor();
        } else try self.expect(.string, "expected function arguments");
    }

    fn functionBody(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
        try self.expect(.l_paren, "expected '(' before parameters");
        var parameters: std.ArrayList(lex.Token) = .empty;
        defer parameters.deinit(self.allocator);
        var is_vararg = false;
        if (self.current.tag != .r_paren) {
            if (try self.accept(.varargs)) {
                is_vararg = true;
            } else {
                if (self.current.tag != .name) return self.syntax("expected parameter name");
                try parameters.append(self.allocator, self.current);
                try self.advance();
                while (try self.accept(.comma)) {
                    if (try self.accept(.varargs)) {
                        is_vararg = true;
                        break;
                    }
                    if (self.current.tag != .name) return self.syntax("expected parameter name");
                    try parameters.append(self.allocator, self.current);
                    try self.advance();
                }
            }
        }
        try self.expect(.r_paren, "expected ')' after parameters");
        const old_vararg = self.vararg_function;
        const old_loop_depth = self.loop_depth;
        const active_mark = self.active_symbols.items.len;
        self.function_depth += 1;
        self.vararg_function = is_vararg;
        self.loop_depth = 0;
        defer {
            self.active_symbols.items.len = active_mark;
            self.function_depth -= 1;
            self.vararg_function = old_vararg;
            self.loop_depth = old_loop_depth;
        }
        for (parameters.items) |parameter| try self.declare(parameter, .parameter);
        try self.block(&.{.kw_end});
        try self.expect(.kw_end, "expected 'end' after function body");
    }

    fn tableConstructor(self: *Parser) (ParseError || std.mem.Allocator.Error)!void {
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

    fn declare(self: *Parser, token_value: lex.Token, kind: SymbolKind) std.mem.Allocator.Error!void {
        const index = self.symbols.items.len;
        try self.symbols.append(self.allocator, .{
            .name_start = token_value.start,
            .name_end = token_value.end,
            .kind = kind,
            .function_depth = self.function_depth,
        });
        try self.active_symbols.append(self.allocator, index);
    }

    fn recordReference(self: *Parser, token_value: lex.Token) std.mem.Allocator.Error!void {
        const name = token_value.text(self.lexer.source);
        var found: ?usize = null;
        var i = self.active_symbols.items.len;
        while (i > 0) {
            i -= 1;
            const symbol_index = self.active_symbols.items[i];
            const symbol = &self.symbols.items[symbol_index];
            if (std.mem.eql(u8, name, self.lexer.source[symbol.name_start..symbol.name_end])) {
                found = symbol_index;
                break;
            }
        }
        var resolution: Resolution = .global;
        if (found) |symbol_index| {
            const symbol = &self.symbols.items[symbol_index];
            if (symbol.function_depth == self.function_depth) resolution = .local else {
                resolution = .upvalue;
                symbol.captured = true;
            }
        }
        try self.references.append(self.allocator, .{
            .name_start = token_value.start,
            .name_end = token_value.end,
            .resolution = resolution,
            .symbol = found,
        });
    }

    fn peekTag(self: *Parser) error{MalformedToken}!lex.Tag {
        var copy = self.lexer;
        return (copy.next() catch return error.MalformedToken).tag;
    }

    fn accept(self: *Parser, tag: lex.Tag) (ParseError || std.mem.Allocator.Error)!bool {
        if (self.current.tag != tag) return false;
        try self.advance();
        return true;
    }
    fn expect(self: *Parser, tag: lex.Tag, message: []const u8) (ParseError || std.mem.Allocator.Error)!void {
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

test "parses representative Lua 5.1 program" {
    const source =
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n-1) + fib(n-2)
        \\end
        \\local t = { answer = 42, [1] = fib(8), 9 }
        \\for k, v in pairs(t) do print(k, v) end
    ;
    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expect(parser.nodes.items.len > 5);
}

test "rejects incomplete blocks" {
    var parser = try Parser.init(std.testing.allocator, "if true then print(1)");
    defer parser.deinit();
    try std.testing.expectError(error.InvalidSyntax, parser.parse());
}

test "semantic control-flow checks" {
    var outside_loop = try Parser.init(std.testing.allocator, "break");
    defer outside_loop.deinit();
    try std.testing.expectError(error.InvalidSyntax, outside_loop.parse());

    var outside_vararg = try Parser.init(std.testing.allocator, "return ...");
    defer outside_vararg.deinit();
    try std.testing.expectError(error.InvalidSyntax, outside_vararg.parse());

    var valid = try Parser.init(std.testing.allocator, "while true do break end; return function(...) return ... end");
    defer valid.deinit();
    try valid.parse();
}

test "AST ownership transfers from parser" {
    var parser = try Parser.init(std.testing.allocator, "local x = 1 + 2; print(x)");
    defer parser.deinit();
    try parser.parse();
    var ast = parser.takeAst();
    defer ast.deinit();
    try std.testing.expect(ast.nodes.items.len >= 5);
    try std.testing.expectEqual(@as(usize, 1), ast.symbols.items.len);
}

test "local visibility follows Lua initializer and block rules" {
    const source = "local x = x; do local hidden = x end; print(hidden)";
    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    try parser.parse();
    var ast = parser.takeAst();
    defer ast.deinit();
    try std.testing.expectEqual(Resolution.global, ast.references.items[0].resolution); // initializer x
    try std.testing.expectEqual(Resolution.local, ast.references.items[1].resolution); // block sees x
    try std.testing.expectEqual(Resolution.global, ast.references.items[2].resolution); // print
    try std.testing.expectEqual(Resolution.global, ast.references.items[3].resolution); // hidden expired
}

test "resolves locals upvalues globals and captures" {
    const source = "local x = 1; function outer(a) local y = x+a; return function(b) return x+y+b+g end end";
    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    try parser.parse();
    var ast = parser.takeAst();
    defer ast.deinit();

    var locals: usize = 0;
    var upvalues: usize = 0;
    var globals: usize = 0;
    for (ast.references.items) |reference| switch (reference.resolution) {
        .local => locals += 1,
        .upvalue => upvalues += 1,
        .global => globals += 1,
    };
    try std.testing.expectEqual(@as(usize, 2), locals);
    try std.testing.expectEqual(@as(usize, 3), upvalues);
    try std.testing.expect(globals >= 2);

    var captured: usize = 0;
    for (ast.symbols.items) |symbol| if (symbol.captured) {
        captured += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), captured);
}
