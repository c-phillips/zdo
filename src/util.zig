const std = @import("std");
const builtin = @import("builtin");

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

pub fn getTermSize() !std.c.winsize {
    if (builtin.os.tag == .windows) {
        // TODO: implement terminal size detection on windows
        return std.c.winsize{ .col = 80, .row = 0, .xpixel = 0, .ypixel = 0 };
    } else {
        var winsize = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
        const ret = std.c.ioctl(std.fs.File.stderr().handle, std.c.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (ret != 0) {
            return error.ErrorGetWinsize;
        }
        return winsize;
    }
}
