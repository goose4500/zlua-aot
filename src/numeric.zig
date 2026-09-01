const std = @import("std");
const lex = @import("lexer.zig");

/// Conservative whole-chunk native backend. It accepts only scalar-number
/// programs whose Lua and C double semantics coincide. Anything uncertain is
/// rejected so the caller can fall back to LuaJIT.
pub fn emitIfEligible(allocator: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) !bool {
    if (!try eligible(allocator, source)) return false;
    try out.writeAll(
        \\/* zlua-aot native numeric backend: no Lua VM is used. */
        \\#include <stdio.h>
        \\int main(void) {
        \\
    );
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.startsWith(u8, line, "local ")) {
            const rest = std.mem.trimStart(u8, line[6..], " \t");
            const eq = std.mem.indexOfScalar(u8, rest, '=').?;
            try out.print("  double {s} = {s};\n", .{ std.mem.trim(u8, rest[0..eq], " \t"), std.mem.trim(u8, rest[eq + 1 ..], " \t") });
        } else if (std.mem.startsWith(u8, line, "print(")) {
            try out.print("  printf(\"%.17g\\n\", (double)({s}));\n", .{std.mem.trim(u8, line[6 .. line.len - 1], " \t")});
        } else if (std.mem.startsWith(u8, line, "return ")) {
            // Standalone Lua return values have no observer; preserve execution
            // without incorrectly turning the value into a process exit code.
            try out.print("  (void)({s});\n  return 0;\n", .{std.mem.trim(u8, line[7..], " \t")});
        } else {
            const eq = std.mem.indexOfScalar(u8, line, '=').?;
            try out.print("  {s} = {s};\n", .{ std.mem.trim(u8, line[0..eq], " \t"), std.mem.trim(u8, line[eq + 1 ..], " \t") });
        }
    }
    try out.writeAll("  return 0;\n}\n");
    return true;
}

fn eligible(allocator: std.mem.Allocator, source: []const u8) !bool {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var saw_statement = false;
    var saw_return = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "--")) continue;
        if (saw_return or std.mem.indexOf(u8, line, "--") != null) return false;
        saw_statement = true;
        if (std.mem.startsWith(u8, line, "local ")) {
            const rest = std.mem.trimStart(u8, line[6..], " \t");
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return false;
            const name = std.mem.trim(u8, rest[0..eq], " \t");
            if (!validCName(name) or containsName(names.items, name)) return false;
            if (!try numericExpression(rest[eq + 1 ..], names.items)) return false;
            try names.append(allocator, name);
        } else if (std.mem.startsWith(u8, line, "print(")) {
            if (line.len < 7 or line[line.len - 1] != ')' or !try numericExpression(line[6 .. line.len - 1], names.items)) return false;
        } else if (std.mem.startsWith(u8, line, "return ")) {
            if (!try numericExpression(line[7..], names.items)) return false;
            saw_return = true;
        } else {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return false;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            if (!containsName(names.items, name) or !try numericExpression(line[eq + 1 ..], names.items)) return false;
        }
    }
    return saw_statement;
}

fn numericExpression(bytes: []const u8, names: []const []const u8) !bool {
    var lexer = lex.Lexer.init(std.mem.trim(u8, bytes, " \t"));
    var balance: usize = 0;
    var expect_value = true;
    var saw_value = false;
    while (true) {
        const token = lexer.next() catch return false;
        switch (token.tag) {
            .eof => return saw_value and !expect_value and balance == 0,
            .number => {
                if (!expect_value) return false;
                const text = token.text(lexer.source);
                const last = text[text.len - 1];
                // LuaJIT cdata suffixes do not have plain Lua-number semantics.
                if (last == 'u' or last == 'U' or last == 'l' or last == 'L' or last == 'i' or last == 'I') return false;
                expect_value = false;
                saw_value = true;
            },
            .name => {
                if (!expect_value or !containsName(names, token.text(lexer.source))) return false;
                expect_value = false;
                saw_value = true;
            },
            .l_paren => {
                if (!expect_value) return false;
                balance += 1;
            },
            .r_paren => {
                if (expect_value or balance == 0) return false;
                balance -= 1;
            },
            .plus, .minus => {
                // Unary +/- is accepted when a value is expected.
                if (!expect_value) expect_value = true;
            },
            .star, .slash => {
                if (expect_value) return false;
                expect_value = true;
            },
            else => return false,
        }
    }
}

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn validCName(name: []const u8) bool {
    if (name.len == 0 or !((name[0] >= 'a' and name[0] <= 'z') or (name[0] >= 'A' and name[0] <= 'Z') or name[0] == '_')) return false;
    for (name[1..]) |c| if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return false;
    const reserved = [_][]const u8{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while" };
    return !containsName(&reserved, name);
}

test "accepts numeric chunk and rejects dynamic chunk" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(try emitIfEligible(std.testing.allocator, "local x=2\nx=x*3\nprint(x)", &output.writer));
    var dynamic = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer dynamic.deinit();
    try std.testing.expect(!try emitIfEligible(std.testing.allocator, "local t = {}\nprint(t)", &dynamic.writer));
}
