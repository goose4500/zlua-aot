const std = @import("std");
const lex = @import("lexer.zig");

pub const UnaryOp = enum { positive, negative };
pub const BinaryOp = enum { add, subtract, multiply, divide };
pub const Expr = union(enum) {
    number: lex.Token,
    symbol: usize,
    unary: struct { op: UnaryOp, operand: usize },
    binary: struct { op: BinaryOp, left: usize, right: usize },
};
pub const Statement = union(enum) {
    local: struct { symbol: usize, value: usize },
    assign: struct { symbol: usize, value: usize },
    print: usize,
    return_value: usize,
};
pub const Symbol = struct { token: lex.Token };

/// A small typed IR owned by one allocator. Every value in this initial IR has
/// the proven type `number`; unsupported/dynamic syntax never enters the IR.
pub const Ir = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    expressions: std.ArrayList(Expr) = .empty,
    statements: std.ArrayList(Statement) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn deinit(self: *Ir) void {
        self.expressions.deinit(self.allocator);
        self.statements.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }
};

const IrParser = struct {
    ir: *Ir,
    lexer: lex.Lexer,
    current: lex.Token,

    fn init(ir: *Ir) !IrParser {
        var lexer = lex.Lexer.init(ir.source);
        const current = try lexer.next();
        return .{ .ir = ir, .lexer = lexer, .current = current };
    }

    fn parse(self: *IrParser) !bool {
        var saw_statement = false;
        var returned = false;
        while (self.current.tag != .eof) {
            if (returned) return false;
            if (self.current.tag == .semicolon) {
                try self.advance();
                continue;
            }
            saw_statement = true;
            if (self.current.tag == .kw_local) {
                try self.advance();
                if (self.current.tag != .name or !validCName(self.current.text(self.ir.source))) return false;
                if (self.findSymbol(self.current.text(self.ir.source)) != null) return false;
                const name = self.current;
                try self.advance();
                if (self.current.tag != .assign) return false;
                try self.advance();
                const value = (try self.expression(0)) orelse return false;
                // Lua locals are not visible in their own initializer.
                const symbol = self.ir.symbols.items.len;
                try self.ir.symbols.append(self.ir.allocator, .{ .token = name });
                try self.ir.statements.append(self.ir.allocator, .{ .local = .{ .symbol = symbol, .value = value } });
            } else if (self.current.tag == .kw_return) {
                try self.advance();
                const value = (try self.expression(0)) orelse return false;
                try self.ir.statements.append(self.ir.allocator, .{ .return_value = value });
                returned = true;
            } else if (self.current.tag == .name) {
                const name = self.current.text(self.ir.source);
                if (std.mem.eql(u8, name, "print")) {
                    try self.advance();
                    if (self.current.tag != .l_paren) return false;
                    try self.advance();
                    const value = (try self.expression(0)) orelse return false;
                    if (self.current.tag != .r_paren) return false;
                    try self.advance();
                    try self.ir.statements.append(self.ir.allocator, .{ .print = value });
                } else {
                    const symbol = self.findSymbol(name) orelse return false;
                    try self.advance();
                    if (self.current.tag != .assign) return false;
                    try self.advance();
                    const value = (try self.expression(0)) orelse return false;
                    try self.ir.statements.append(self.ir.allocator, .{ .assign = .{ .symbol = symbol, .value = value } });
                }
            } else return false;
            if (self.current.tag == .semicolon) try self.advance();
        }
        return saw_statement;
    }

    fn expression(self: *IrParser, minimum: u8) !?usize {
        var left: usize = undefined;
        if (self.current.tag == .plus or self.current.tag == .minus) {
            const op: UnaryOp = if (self.current.tag == .plus) .positive else .negative;
            try self.advance();
            const operand = (try self.expression(3)) orelse return null;
            left = self.ir.expressions.items.len;
            try self.ir.expressions.append(self.ir.allocator, .{ .unary = .{ .op = op, .operand = operand } });
        } else if (self.current.tag == .number) {
            const token = self.current;
            if (!plainNumber(token.text(self.ir.source))) return null;
            try self.advance();
            left = self.ir.expressions.items.len;
            try self.ir.expressions.append(self.ir.allocator, .{ .number = token });
        } else if (self.current.tag == .name) {
            const symbol = self.findSymbol(self.current.text(self.ir.source)) orelse return null;
            try self.advance();
            left = self.ir.expressions.items.len;
            try self.ir.expressions.append(self.ir.allocator, .{ .symbol = symbol });
        } else if (self.current.tag == .l_paren) {
            try self.advance();
            left = (try self.expression(0)) orelse return null;
            if (self.current.tag != .r_paren) return null;
            try self.advance();
        } else return null;

        while (binary(self.current.tag)) |info| {
            if (info.precedence < minimum) break;
            const op = info.op;
            try self.advance();
            const right = (try self.expression(info.precedence + 1)) orelse return null;
            const result = self.ir.expressions.items.len;
            try self.ir.expressions.append(self.ir.allocator, .{ .binary = .{ .op = op, .left = left, .right = right } });
            left = result;
        }
        return left;
    }

    fn findSymbol(self: *const IrParser, name: []const u8) ?usize {
        var i = self.ir.symbols.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, name, self.ir.symbols.items[i].token.text(self.ir.source))) return i;
        }
        return null;
    }

    fn advance(self: *IrParser) !void {
        self.current = try self.lexer.next();
    }
};

/// Builds typed numeric IR and emits native C if the entire chunk is eligible.
/// Returns false without writing output when dynamic semantics require LuaJIT.
pub fn emitIfEligible(allocator: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) !bool {
    var ir: Ir = .{ .allocator = allocator, .source = source };
    defer ir.deinit();
    var parser = IrParser.init(&ir) catch return false;
    if (!(parser.parse() catch return false)) return false;

    try out.writeAll(
        \\/* zlua-aot typed native numeric IR: no Lua VM is used. */
        \\#include <stdio.h>
        \\int main(void) {
        \\
    );
    for (ir.statements.items) |statement| switch (statement) {
        .local => |local| {
            try out.print("  double {s} = ", .{ir.symbols.items[local.symbol].token.text(source)});
            try emitExpression(&ir, local.value, out);
            try out.writeAll(";\n");
        },
        .assign => |assign| {
            try out.print("  {s} = ", .{ir.symbols.items[assign.symbol].token.text(source)});
            try emitExpression(&ir, assign.value, out);
            try out.writeAll(";\n");
        },
        .print => |value| {
            try out.writeAll("  printf(\"%.17g\\n\", (double)(");
            try emitExpression(&ir, value, out);
            try out.writeAll("));\n");
        },
        .return_value => |value| {
            try out.writeAll("  (void)(");
            try emitExpression(&ir, value, out);
            try out.writeAll(");\n  return 0;\n");
        },
    };
    try out.writeAll("  return 0;\n}\n");
    return true;
}

fn emitExpression(ir: *const Ir, index: usize, out: *std.Io.Writer) !void {
    switch (ir.expressions.items[index]) {
        .number => |token| try out.writeAll(token.text(ir.source)),
        .symbol => |symbol| try out.writeAll(ir.symbols.items[symbol].token.text(ir.source)),
        .unary => |unary| {
            try out.writeByte(if (unary.op == .positive) '+' else '-');
            try out.writeByte('(');
            try emitExpression(ir, unary.operand, out);
            try out.writeByte(')');
        },
        .binary => |operation| {
            try out.writeByte('(');
            try emitExpression(ir, operation.left, out);
            try out.writeAll(switch (operation.op) {
                .add => " + ",
                .subtract => " - ",
                .multiply => " * ",
                .divide => " / ",
            });
            try emitExpression(ir, operation.right, out);
            try out.writeByte(')');
        },
    }
}

const BinaryInfo = struct { op: BinaryOp, precedence: u8 };
fn binary(tag: lex.Tag) ?BinaryInfo {
    return switch (tag) {
        .plus => .{ .op = .add, .precedence = 1 },
        .minus => .{ .op = .subtract, .precedence = 1 },
        .star => .{ .op = .multiply, .precedence = 2 },
        .slash => .{ .op = .divide, .precedence = 2 },
        else => null,
    };
}

fn plainNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    const last = text[text.len - 1];
    return !(last == 'u' or last == 'U' or last == 'l' or last == 'L' or last == 'i' or last == 'I');
}
fn validCName(name: []const u8) bool {
    if (name.len == 0 or !((name[0] >= 'a' and name[0] <= 'z') or (name[0] >= 'A' and name[0] <= 'Z') or name[0] == '_')) return false;
    for (name[1..]) |c| if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return false;
    const reserved = [_][]const u8{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while" };
    for (reserved) |word| if (std.mem.eql(u8, word, name)) return false;
    return true;
}

test "builds hierarchical typed numeric IR" {
    var ir: Ir = .{ .allocator = std.testing.allocator, .source = "local x = 2 + 3 * 4; print(x)" };
    defer ir.deinit();
    var parser = try IrParser.init(&ir);
    try std.testing.expect(try parser.parse());
    try std.testing.expectEqual(@as(usize, 1), ir.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 2), ir.statements.items.len);
    try std.testing.expect(ir.expressions.items.len >= 6);
}

test "rejects dynamic semantics without partial output" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(!try emitIfEligible(std.testing.allocator, "local t = {}\nprint(t)", &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.writer.end);
}
