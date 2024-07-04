const std = @import("std");
const Board = @import("board.zig").Board;



// Specifies how to pass an argument: short (-),  long (--), help string
pub const ArgumentFormat = struct{?[]const u8, ?[]const u8, []const u8};
pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    flags: ?[]const ArgumentFormat = null,
    options: ?[]const ArgumentFormat = null,
    action: *const fn (board: *Board, args: Args) anyerror!void,
    
    pub fn makeStr(self: *const Command, alloc: std.mem.Allocator, opts: struct{long: bool = false}) ![]u8 {
        const command_name_col_len = 10;
        const command_name = try alloc.dupe(u8, " " ** command_name_col_len);
        defer alloc.free(command_name);

        const fmt_name = try std.fmt.allocPrint(alloc, "  `{s}`", .{self.name});
        defer alloc.free(fmt_name);
        std.mem.copyForwards(u8, command_name, fmt_name[0..@min(fmt_name.len, command_name_col_len)]);
        var buf = std.ArrayList(u8).init(alloc);
        var bufwriter = buf.writer();
        try bufwriter.print(
            "{s}{s}\n",
            .{
                command_name,
                if(opts.long) self.description else std.mem.sliceTo(self.description, '\n')
            }
        );
        if(self.flags) |flags|{
            for(flags) |flag| {
                try bufwriter.print("      {s: <3}{s: <15}{s}\n", .{
                    flag[0] orelse "",
                    flag[1] orelse "",
                    if(opts.long) flag[2] else std.mem.sliceTo(flag[2], '\n'),
                });
            }
        }
        if(self.options) |options|{
            for(options) |option| {
                try bufwriter.print("      {s: <3}{s: <15}{s}\n", .{
                    option[0] orelse "",
                    option[1] orelse "",
                    if(opts.long) option[2] else std.mem.sliceTo(option[2], '\n'),
                });
            }
        }
        try bufwriter.writeAll("\n");

        return buf.items;
    }
};


pub const Args = struct {
    exe_path: []const u8,
    raw_args: [][]const u8,
    filters: std.ArrayList([]const u8),
    flags: std.StringHashMap(bool),
    options: std.StringHashMap([]const u8),
    positional: std.ArrayList([]const u8),
    command: []const u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, raw_args: [][]const u8) !Args {
        var args = Args{
            .exe_path = raw_args[0],
            .raw_args = raw_args,
            .filters = std.ArrayList([]const u8).init(alloc),
            .flags = std.StringHashMap(bool).init(alloc),
            .options = std.StringHashMap([]const u8).init(alloc),
            .positional = std.ArrayList([]const u8).init(alloc),
        };

        var command: ?[]const u8 = null;

        var i: usize = 1;  // skip the executable path argument
        while(i < raw_args.len) : (i += 1) {
            const entry = raw_args[i];
            if(entry.len < 1) continue;
            switch(entry[0]) {
                '+' => try args.filters.append(entry),
                '!' => try args.filters.append(entry),
                '-' => {
                    if(entry.len == 1) return error.InvalidArgument;
                    if(entry[1] == '-' or command != null){
                        const offset: usize = if( entry [1] == '-' ) 2 else 1;
                        
                        if( raw_args.len > i+1){
                            const next = raw_args[i+1];
                            if( next[0] == '"' ) {
                                var value = std.ArrayList([]const u8).init(alloc);
                                defer value.deinit();
                                var j = i+1;
                                while(raw_args[j][0] != '"' and raw_args[j][raw_args[j].len-1] != '"') : (j += 1) {
                                    try value.append(raw_args[j]);
                                }
                                try args.options.put(entry[offset..], try std.mem.join(alloc, " ", value.items));
                                i = j+1;
                            } else {
                                if(next[0] == '-' or next[0] == '!' or next[0] == '+') {
                                    try args.flags.put(entry[offset..], true);
                                } else {
                                    try args.options.put(entry[offset..], next);
                                    i += 1;
                                }
                            }
                        } else {
                            try args.flags.put(entry[offset..], true);
                        }
                        continue;
                    } else {
                        if(command == null) {
                            var j: usize = 1;
                            std.log.debug("{s}", .{entry});
                            try args.flags.put(entry[j..j+1], true);
                            while( j < entry.len ) : (j += 1){
                                std.log.debug("    {d} : {c}", .{j, entry[j]});
                                try args.flags.put(entry[j..j+1], true);
                            }
                        } else {
                            return error.BadOption;
                        }
                    }
                },
                else => {
                    if(command == null){
                        command = entry;
                    } else {
                        try args.positional.append(entry);
                    }
                }
            }
        }

        if(command == null) return error.InvalidCommand;
        args.command = command.?;
        return args;
    }

    pub fn deinit(self: *Args) void {
        self.filters.deinit();
        self.flags.deinit();
        self.options.deinit();
    }

    
    pub fn printAll(args: *const Args) !void {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("All args:\n", .{});
        try stderr.print("  Flags:\n", .{});
        var flag_iter = args.flags.iterator();
        while(flag_iter.next()) |entry| {
            try stderr.print("    {s} -> {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
        try stderr.print("  Options:\n", .{});
        var option_iter = args.options.iterator();
        while(option_iter.next()) |entry| {
            try stderr.print("    {s} -> {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
        try stderr.writeAll("\n");
    }
};


pub fn fillCommandArgs(command: *const Command, args: *Args) !void {
    if(command.flags) |flags|{
        for(flags) |flag| {
            if( flag[1] ) |name| {
                if( flag[0] ) |short| {
                    if( args.flags.get(short[1..]) )|value|{
                        try args.flags.put(name[2..], value);
                    }
                }
            }
        }
    }
    if(command.options) |options| {
        for(options) |option| {
            if( option[1] ) |name| {
                if( option[0] ) |short| {
                    if( args.options.get(short[1..]) ) |value| {
                        try args.options.put(name[2..], value);
                    }
                }
            }
        }
    }
}
