const std = @import("std");


pub fn trim(str: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = str.len;

    // Trim leading whitespace
    while (start < end and std.ascii.isWhitespace(str[start])) {
        start += 1;
    }

    // Trim trailing whitespace
    while (end > start and std.ascii.isWhitespace(str[end - 1])) {
        end -= 1;
    }

    return str[start..end];
}


pub fn stringCmp(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(.lt);
}