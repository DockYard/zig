const std = @import("std");
pub fn main() !void {
    try std.fs.File.stdout().writeAll(a);
}
const a = "Hello, World!\n";
