const std = @import("std");
const Board = @import("board.zig").Board;

const argparse = @import("argparse.zig");
const Args = argparse.Args;


pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const raw_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, raw_args);

    var args = try Args.init(alloc, raw_args);
    var board = try Board.init(alloc, args);

    const command = board.commands.get(args.command);
    if(command) |cmd| {
        try argparse.fillCommandArgs(&cmd, &args);
        try cmd.action(&board, args);
    } else {
        return error.InvalidCommand;
    }
}