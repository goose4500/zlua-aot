const std = @import("std");
const lexical = @import("../frontend/lexer.zig");
const syntax = @import("../frontend/parser.zig");
const numeric = @import("../ir/numeric.zig");
const hybrid = @import("../ir/hybrid.zig");
const launcher = @import("../backend/launcher.zig");

pub const Backend = enum {
    native_numeric,
    hybrid_functions,
    luajit_fallback,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .native_numeric => "native-numeric",
            .hybrid_functions => "hybrid-functions",
            .luajit_fallback => "luajit-fallback",
        };
    }
};

/// Runs the compiler pipeline from validated Lua source to generated C.
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_name: []const u8,
    out: *std.Io.Writer,
) !Backend {
    try validateSyntax(allocator, source, source_name);

    if (try numeric.emitIfEligible(allocator, source, out)) return .native_numeric;

    var plan = hybrid.analyze(allocator, source) catch |err| {
        std.debug.print("{s}: AOT eligibility error: annotated function is outside the supported numeric subset\n", .{source_name});
        return err;
    };
    defer plan.deinit();

    if (plan.kernels.items.len != 0) {
        try launcher.emit(plan.transformed, source_name, &plan, out);
        return .hybrid_functions;
    }

    try launcher.emit(source, source_name, null, out);
    return .luajit_fallback;
}

fn validateSyntax(allocator: std.mem.Allocator, source: []const u8, source_name: []const u8) !void {
    // Lex independently so malformed initial tokens receive lexical diagnostics.
    var lexer = lexical.Lexer.init(source);
    while (true) {
        const token = lexer.next() catch |err| {
            std.debug.print("{s}:{d}:{d}: lexical error: {s}\n", .{
                source_name, lexer.failure.line, lexer.failure.column, lexer.failure.message,
            });
            return err;
        };
        if (token.tag == .eof) break;
    }

    var parser = try syntax.Parser.init(allocator, source);
    defer parser.deinit();
    parser.parse() catch |err| {
        std.debug.print("{s}:{d}:{d}: syntax error: {s}\n", .{
            source_name, parser.failure.line, parser.failure.column, parser.failure.message,
        });
        return err;
    };
}
