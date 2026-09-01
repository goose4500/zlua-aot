const std = @import("std");
const pipeline = @import("pipeline.zig");

pub const Error = error{InvalidArguments};

/// Owns command-line parsing and filesystem I/O around the compiler pipeline.
pub fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const input = args.next() orelse return usage();
    const output = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const source = try std.Io.Dir.cwd().readFileAlloc(io, input, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(source);

    var generated = std.Io.Writer.Allocating.init(allocator);
    defer generated.deinit();
    const selected_backend = try pipeline.compile(allocator, source, input, &generated.writer);

    std.debug.print("zlua-aot backend: {s}\n", .{selected_backend.label()});
    const c_source = try generated.toOwnedSlice();
    defer allocator.free(c_source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = c_source });
}

fn usage() Error {
    std.debug.print("usage: zlua-emit <input.lua> <output.c>\n", .{});
    return error.InvalidArguments;
}
