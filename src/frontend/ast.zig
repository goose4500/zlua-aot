const std = @import("std");

pub const NodeKind = enum {
    chunk,
    block,
    assignment,
    call,
    local,
    function,
    if_statement,
    while_loop,
    repeat_loop,
    for_loop,
    return_statement,
    break_statement,
    expression,
    table,
};

pub const Node = struct {
    kind: NodeKind,
    start: usize,
    end: usize,
};

pub const SymbolKind = enum { local, parameter };

pub const Symbol = struct {
    name_start: usize,
    name_end: usize,
    kind: SymbolKind,
    function_depth: usize,
    captured: bool = false,
};

pub const Resolution = enum { local, upvalue, global };

pub const Reference = struct {
    name_start: usize,
    name_end: usize,
    resolution: Resolution,
    symbol: ?usize,
};

/// Syntax and name-resolution data produced by the frontend.
pub const Ast = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    symbols: std.ArrayList(Symbol),
    references: std.ArrayList(Reference),

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.references.deinit(self.allocator);
    }
};
