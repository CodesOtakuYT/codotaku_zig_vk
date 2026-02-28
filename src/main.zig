const std = @import("std");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_allocator.deinit() == .ok);

    const gpa = gpa_allocator.allocator();

    var app = try App.init(gpa);
    defer app.deinit();
    try app.run();
}
