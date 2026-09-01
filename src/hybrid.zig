const std = @import("std");
const lex = @import("lexer.zig");

pub const Op = enum { add, sub, mul, div };
pub const Expr = union(enum) { number: lex.Token, parameter: usize, unary_minus: usize, binary: struct { op: Op, left: usize, right: usize } };
pub const Kernel = struct {
    name: lex.Token,
    params: std.ArrayList(lex.Token) = .empty,
    exprs: std.ArrayList(Expr) = .empty,
    result: usize,
    declaration_start: usize,
    declaration_end: usize,

    fn deinit(self: *Kernel, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
        self.exprs.deinit(allocator);
    }
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    kernels: std.ArrayList(Kernel) = .empty,
    transformed: []u8 = &.{},
    pub fn deinit(self: *Plan) void {
        for (self.kernels.items) |*kernel| kernel.deinit(self.allocator);
        self.kernels.deinit(self.allocator);
        if (self.transformed.len != 0) self.allocator.free(self.transformed);
    }
};

const Parser = struct {
    source: []const u8,
    lexer: lex.Lexer,
    current: lex.Token,
    kernel: *Kernel,
    allocator: std.mem.Allocator,

    fn advance(self: *Parser) !void {
        self.current = try self.lexer.next();
    }
    fn parameter(self: *Parser, name: []const u8) ?usize {
        for (self.kernel.params.items, 0..) |token, i| if (std.mem.eql(u8, token.text(self.source), name)) return i;
        return null;
    }
    fn expression(self: *Parser, minimum: u8) !?usize {
        var left: usize = undefined;
        if (self.current.tag == .minus or self.current.tag == .plus) {
            const minus = self.current.tag == .minus;
            try self.advance();
            left = (try self.expression(3)) orelse return null;
            if (minus) {
                const i = self.kernel.exprs.items.len;
                try self.kernel.exprs.append(self.allocator, .{ .unary_minus = left });
                left = i;
            }
        } else if (self.current.tag == .number) {
            const token = self.current;
            const spelling = token.text(self.source);
            const last = spelling[spelling.len - 1];
            if (last == 'u' or last == 'U' or last == 'l' or last == 'L' or last == 'i' or last == 'I') return null;
            try self.advance();
            left = self.kernel.exprs.items.len;
            try self.kernel.exprs.append(self.allocator, .{ .number = token });
        } else if (self.current.tag == .name) {
            const p = self.parameter(self.current.text(self.source)) orelse return null;
            try self.advance();
            left = self.kernel.exprs.items.len;
            try self.kernel.exprs.append(self.allocator, .{ .parameter = p });
        } else if (self.current.tag == .l_paren) {
            try self.advance();
            left = (try self.expression(0)) orelse return null;
            if (self.current.tag != .r_paren) return null;
            try self.advance();
        } else return null;
        while (opInfo(self.current.tag)) |info| {
            if (info.prec < minimum) break;
            try self.advance();
            const right = (try self.expression(info.prec + 1)) orelse return null;
            const i = self.kernel.exprs.items.len;
            try self.kernel.exprs.append(self.allocator, .{ .binary = .{ .op = info.op, .left = left, .right = right } });
            left = i;
        }
        return left;
    }
};

pub fn analyze(allocator: std.mem.Allocator, source: []const u8) !Plan {
    var plan: Plan = .{ .allocator = allocator, .source = source };
    errdefer plan.deinit();
    var search: usize = 0;
    while (nextDirective(source, search)) |directive| {
        var lexer = lex.Lexer.init(source);
        lexer.index = directive + "--@aot-number".len;
        // Recompute locations is unnecessary: full parser already validated and
        // byte spans are authoritative for rewrites.
        var token = try lexer.next();
        if (token.tag != .kw_function) {
            search = directive + "--@aot-number".len;
            continue;
        }
        const declaration_start = token.start;
        token = try lexer.next();
        if (token.tag != .name) return error.InvalidAotFunction;
        var kernel: Kernel = .{ .name = token, .result = undefined, .declaration_start = declaration_start, .declaration_end = undefined };
        errdefer kernel.deinit(allocator);
        token = try lexer.next();
        if (token.tag != .l_paren) return error.InvalidAotFunction;
        token = try lexer.next();
        if (token.tag != .r_paren) while (true) {
            if (token.tag != .name) return error.InvalidAotFunction;
            for (kernel.params.items) |existing| if (std.mem.eql(u8, existing.text(source), token.text(source))) return error.InvalidAotFunction;
            try kernel.params.append(allocator, token);
            token = try lexer.next();
            if (token.tag == .r_paren) break;
            if (token.tag != .comma) return error.InvalidAotFunction;
            token = try lexer.next();
        };
        token = try lexer.next();
        if (token.tag != .kw_return) return error.InvalidAotFunction;
        token = try lexer.next();
        var parser: Parser = .{ .source = source, .lexer = lexer, .current = token, .kernel = &kernel, .allocator = allocator };
        kernel.result = (try parser.expression(0)) orelse return error.InvalidAotFunction;
        if (parser.current.tag == .semicolon) try parser.advance();
        if (parser.current.tag != .kw_end) return error.InvalidAotFunction;
        kernel.declaration_end = parser.current.end;
        search = kernel.declaration_end;
        try plan.kernels.append(allocator, kernel);
    }
    if (plan.kernels.items.len == 0) return plan;
    var transformed = std.Io.Writer.Allocating.init(allocator);
    defer transformed.deinit();
    var cursor: usize = 0;
    for (plan.kernels.items, 0..) |kernel, i| {
        try transformed.writer.writeAll(source[cursor..kernel.declaration_start]);
        try transformed.writer.print("__zlua_fallback_{d} = function", .{i});
        const after_name = kernel.name.end;
        try transformed.writer.writeAll(source[after_name..kernel.declaration_end]);
        cursor = kernel.declaration_end;
    }
    try transformed.writer.writeAll(source[cursor..]);
    plan.transformed = try transformed.toOwnedSlice();
    return plan;
}

pub fn emitExpr(plan: *const Plan, kernel: *const Kernel, index: usize, out: *std.Io.Writer) !void {
    switch (kernel.exprs.items[index]) {
        .number => |token| try out.writeAll(token.text(plan.source)),
        .parameter => |p| try out.print("p{d}", .{p}),
        .unary_minus => |operand| {
            try out.writeAll("-(");
            try emitExpr(plan, kernel, operand, out);
            try out.writeByte(')');
        },
        .binary => |b| {
            try out.writeByte('(');
            try emitExpr(plan, kernel, b.left, out);
            try out.writeAll(switch (b.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
            });
            try emitExpr(plan, kernel, b.right, out);
            try out.writeByte(')');
        },
    }
}
const Info = struct { op: Op, prec: u8 };
fn nextDirective(source: []const u8, start: usize) ?usize {
    var cursor = start;
    while (cursor < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        const line = source[cursor..end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "--@aot-number")) return cursor + @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr);
        cursor = if (end < source.len) end + 1 else source.len;
    }
    return null;
}

fn opInfo(tag: lex.Tag) ?Info {
    return switch (tag) {
        .plus => .{ .op = .add, .prec = 1 },
        .minus => .{ .op = .sub, .prec = 1 },
        .star => .{ .op = .mul, .prec = 2 },
        .slash => .{ .op = .div, .prec = 2 },
        else => null,
    };
}

test "plans annotated native function rewrite" {
    const source = "--@aot-number\nfunction square(x) return x*x end\nprint({square(3)})";
    var plan = try analyze(std.testing.allocator, source);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.kernels.items.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.transformed, "__zlua_fallback_0 = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.transformed, "function square") == null);
}
