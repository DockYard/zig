const std = @import("std");
pub fn main() !void {
    const str = getStr();
    try std.fs.File.stdout().writeAll(str);
}
inline fn getStr() []const u8 {
    return "foo\n";
}
