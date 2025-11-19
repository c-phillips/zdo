const std = @import("std");
const Board = @import("board.zig").Board;
const global_flags = @import("board.zig").global_flags;
const global_options = @import("board.zig").global_options;

const argparse = @import("argparse.zig");
const Args = argparse.Args;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const raw_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, raw_args);

    var args: Args = Args.init(alloc, raw_args) catch |err| {
        switch (err) {
            error.NoCommand => std.log.err("No command! Rerun with help for a list of commands", .{}),
            error.InvalidArgument => std.log.err("Invalid argument!", .{}),
            error.BadOption => std.log.err("Invalid option!", .{}),
            error.OutOfMemory => std.log.err("Out of Memory!", .{}),
        }
        return err;
    };
    defer args.deinit(alloc);

    var board = try Board.init(alloc, args);

    const command = board.commands.get(args.command);
    if (command) |cmd| {
        try argparse.fillCommandArgs(&cmd, &args, .{ .other_flags = global_flags, .other_options = global_options });
        try args.printAllDebug();
        try cmd.action(&board, args);
    } else {
        std.log.err("Invalid Command! Rerun with help for a list of commands", .{});
    }
}
