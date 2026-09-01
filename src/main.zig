const std = @import("std");
const cli = @import("driver/cli.zig");

pub fn main(init: std.process.Init) !void {
    try cli.run(init);
}
