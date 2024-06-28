const std = @import("std");
const tasklib = @import("task.zig");
const Task = tasklib.Task;
const datetime = @import("datetime.zig");
const Table = @import("table.zig").Table;


const argparse = @import("argparse.zig");
const Args = argparse.Args;
const ArgumentFormat = argparse.ArgumentFormat;
const Command = argparse.Command;

const util = @import("util.zig");
const trim = util.trim;


pub const global_flags: []const ArgumentFormat = &.{
    .{"-c", "--current", "Use current directory tasks only"},
};
pub const global_options: []const ArgumentFormat = &.{
    .{null, "--dirs", "Comma separated list of task directories to include"},
};


/// Will use the allocator attached to the task_list
fn loadLocationToList(task_list: *std.ArrayList(Task), opts: struct{
    rel_location: ?[]const u8 = null,
    abs_location: ?[]const u8 = null,
    today: ?datetime.DateTime = null,
}) !void {
    var d: std.fs.Dir = undefined;
    if( opts.rel_location ) |location| {
        std.log.debug("Trying to access relative path: {s}", .{location});
        d = try std.fs.cwd().openDir(location, .{.iterate = true});
    } else if( opts.abs_location ) |location| {
        std.log.debug("Trying to access absolute path: {s}", .{location});
        d = try std.fs.openDirAbsolute(location, .{.iterate=true});
    } else {
        return error.NoPathSpecified;
    }

    var iter = d.iterate();
    while( try iter.next() ) |entry| {
        if(entry.kind == .file){
            std.log.debug("\t\tFound \"{s}\"", .{entry.name});
            if( std.mem.endsWith(u8, entry.name, ".md") ){
                try task_list.append(
                    try Task.fromTaskFile(
                        task_list.allocator,
                        try d.realpathAlloc(task_list.allocator, entry.name),
                        .{.today = opts.today}
                    )
                );
            }
        }
    }
}


const Registry = struct {
    alloc: std.mem.Allocator,
    abspath: []const u8,
    dirname: []const u8,
    table: ?Table = null,
    tasks: std.ArrayList(Task),
    global: bool = false,
    prefix: []const u8 = "",
    parent: ?*const Registry = null,
    children: ?std.ArrayList(Registry) = null,
    child_prefix_map: ?std.StringHashMap(*Registry) = null,
    task_map: ?std.StringHashMap(*Task) = null,
    level: u8 = 0,
    task_filter_mask: ?[]const bool = null,
    valid_child_tasks: bool = false,

    pub fn deinit(self: *Registry) void {
        if(self.table) |table| {
            table.deinit();
        }
        if(self.children) |children|{
            var it = children.valueIterator();
            while(it.next()) |child|{
                child.deinit();
            }
            children.deinit();
        }
        // this is created with a realpathAlloc during init
        self.alloc.free(self.abspath);
    }

    pub fn init(alloc: std.mem.Allocator, path: []const u8, opts: struct{
        parent: ?*const Registry = null,
        global: bool = false,
        prefix: ?[]const u8 = null,
        level: u8 = 0,
    }) !Registry {
        // resolve the absolute path in case we got something relative
        const abspath = try std.fs.realpathAlloc(alloc, path);

        // check for other subdirectories to load as children
        // TODO: wrap this into the task loading function to prevent iterating through the filesystem twice
        const dir = try std.fs.openDirAbsolute(abspath, .{.iterate = true});
        // defer dir.close();
        var children_locations = std.ArrayList([]const u8).init(alloc);
        defer children_locations.deinit();
        var iter = dir.iterate();
        while(try iter.next()) |entry| {
            if(entry.kind == .directory) {
                try children_locations.append( try dir.realpathAlloc(alloc, entry.name) );
            }
        }

        std.log.debug("Initializing registry for {s} @ {s}", .{std.fs.path.basename(abspath), abspath});
        var self = try alloc.create(Registry);
        self.* = .{
            .alloc = alloc,
            .abspath = abspath,
            .dirname = std.fs.path.basename(abspath),
            .parent = opts.parent,
            .global = opts.global,
            .prefix = opts.prefix orelse if(opts.global) "_" else "",
            .tasks = std.ArrayList(Task).init(alloc),
            .level = opts.level,
        };

        if(children_locations.items.len > 0) {
            // TODO: support unicode lexical sort the child_locations
            // For now, we will just do a byte order sort
            std.mem.sort([]const u8, children_locations.items, {}, util.stringCmp);
            const conflict_pref = "jklmfdsauiortpewyqnhgvcxzb";

            var children = std.ArrayList(Registry).init(alloc);
            var child_prefix_map = std.StringHashMap(*Registry).init(alloc);

            for(children_locations.items) |child_location|{
                const child_dirname = std.fs.path.basename(child_location);
                var child_prefix = std.ArrayList(u8).init(alloc);
                try child_prefix.append(child_dirname[0]);
                if( child_prefix_map.contains(child_prefix.items) ){
                    std.log.debug("\t!!-> Prefix map already contains: {s}", .{child_prefix.items});
                    // the proposed child_prefix already exists
                    if(child_dirname.len > 1){
                        try child_prefix.append(child_dirname[1]);
                    }
                    var conflict_idx: usize = 0;
                    while(child_prefix_map.contains(child_prefix.items)) : (conflict_idx += 1) {
                        if(conflict_idx >= conflict_pref.len) return error.CouldNotResolveChildNameConflict;
                        child_prefix.items[child_prefix.items.len-1] = conflict_pref[conflict_idx];
                    }
                }
                // try child_prefix_map.put(child_prefix.items, true);
                std.log.debug("\tPrefix for {s}: {s}", .{child_dirname, child_prefix.items});
                try children.append(
                    try Registry.init(alloc, child_location, .{
                        .parent = self,
                        .global = false,
                        .prefix = try std.mem.join(alloc, "", &.{self.prefix, child_prefix.items}),
                        .level = opts.level + 1,
                    })
                );
                try child_prefix_map.put(child_prefix.items, &children.items[children.items.len-1]);
            }
            self.children = children;
            self.child_prefix_map = child_prefix_map;
        }

        return self.*;
    }

    pub fn printTable(self: *Registry, args: struct{
        long: bool = false,
        flat: bool = false,
        command_args: ?Args = null,
    }) !void {

        const stdout = std.io.getStdOut().writer();
        if(self.parent == null){
            try self.loadTasks(args.command_args.?, .{.flat = args.flat});
        }
        
        var have_tasks = false;
        for(self.task_filter_mask.?) |unfiltered| {
            have_tasks = have_tasks or !unfiltered;
            if( have_tasks ) break;
        }
        // std.log.debug("{s} has unfiltered tasks? {}, or maybe child tasks? {}", .{self.dirname, have_tasks, self.valid_child_tasks});

        // write the table header
        if(self.level == 0 and !self.global){
            try stdout.writeAll("#     ?   !  Task\n" ++ ("_" ** 80) ++ "\n\n");
        } else {
            if(self.global){
                try stdout.print("{s:-^80}", .{" GLOBAL "});
            } else {
                if(have_tasks or self.valid_child_tasks){
                    if(self.level == 1) {
                        const tab = try std.fmt.allocPrint(self.alloc, "( {s} )", .{self.dirname});
                        var baseline = try self.alloc.dupe(u8, "." ++ "- "**19 ++ "  " ++ " -"**19 ++ ".\n");
                        std.mem.copyForwards(u8, baseline[40-(tab.len/2)..], tab);
                        try stdout.writeAll(baseline);
                    } else {
                        if( self.parent ) |parent| {
                            const tabname = if( self.level == 2 ) 
                                try std.fmt.allocPrint( self.alloc, "{{ {s} > {s} }}", .{parent.dirname, self.dirname})
                            else
                                try std.fmt.allocPrint( self.alloc, "{{ .. > {s} > {s} }}", .{parent.dirname, self.dirname})
                            ;
                            try stdout.print("{s: ^80}\n", .{tabname});
                        } else {
                            std.log.debug("{s} is orphaned", .{self.dirname});
                            return error.OrphanedChild;
                        }
                    }
                }
            }
        }

        // write the tasks
        for(self.tasks.items, 0..) |task, idx| {
            if(self.task_filter_mask.?[idx]) continue;

            const str = try task.makeStr(self.alloc, .{.short = !args.long, .linewidth=76});
            // defer self.alloc.free(str);

            const output = try std.fmt.allocPrint(self.alloc, "{s: <5}{s}", .{task._id.?, str});
            // defer self.alloc.free(output);

            try stdout.writeAll(output);
            if( args.long ){
                try stdout.writeAll("\n");  // add some separation in long mode
            }
        }
        if( self.level == 0 ) try stdout.writeAll("\n");

        if( !args.flat ){
            // write the child tables
            if(self.children) |children| {
                for(children.items) |*child| {
                    try child.printTable(args);
                }
            }
        }
        if( self.level == 1 and (have_tasks or self.valid_child_tasks) ) try stdout.writeAll("\n");
        
    }

    pub fn loadTasks(self: *Registry, args: Args, opts: struct{
        flat: bool = false,
    }) !void {
        if(self.tasks.items.len > 0) return; // only load once
        // load all of the tasks in our flat location into our task list
        try loadLocationToList(&self.tasks, .{
            .abs_location = self.abspath,
            .today = datetime.DateTime.today()
        });

        var task_map = std.StringHashMap(*Task).init(self.alloc);
        var filter_mask = try self.alloc.alloc(bool, self.tasks.items.len);
        for(self.tasks.items, 0..) |*task, idx| {
            task._id = try std.fmt.allocPrint(task.alloc, "{s}{d}", .{self.prefix, idx});
            filter_mask[idx] = try Registry.filterTask(task, args);
            try task_map.put(task._id.?, task);
        }
        self.task_filter_mask = filter_mask;
        self.task_map = task_map;

        if( self.children ) |children| {
            for(children.items) |*child| {
                std.log.debug("Loading tasks for {s}", .{child.dirname});
                try child.loadTasks(args, opts);
                self.valid_child_tasks = self.valid_child_tasks or std.mem.allEqual(bool, child.task_filter_mask.?, false);
            }
        }

        if( opts.flat ){
            if(self.children)|children|{
                for(children.items) |child| {
                    // join the child tasks and filter mask into the parent's
                    try self.tasks.appendSlice(child.tasks.items);
                    self.task_filter_mask = try std.mem.concat(self.alloc, bool, &.{child.task_filter_mask.?, self.task_filter_mask.?});
                }
            }
        }
        std.mem.sort(Task, self.tasks.items, {}, Task.lessThanWithCtx);
    }

    pub fn getTaskById(self: *const Registry, id: []const u8) !?*Task {
        if( self.task_map ) |task_map| {
            std.log.debug("Registry {s} ({s}): searching for {s}...", .{self.dirname, self.prefix, id});
            for(self.tasks.items) |task| {
                std.log.debug("    -> {s}: {s} ;   {}", .{task._id.?, task.name, std.mem.eql(u8, id, task._id.?)});
            }
            if( task_map.get(id) ) |v| return v;
            if( self.children )|children|{
                for(children.items) |child|{
                    if( child.task_map ) |child_map| {
                        if( child_map.get(id) ) |v| return v;
                    }
                }
                for(children.items) |child| {
                    const task = try child.getTaskById(id);
                    if( task ) |v| return v;
                }
            }
            return null;
        }
        return error.NoTasksLoaded;
    }

    pub fn filterTask(task: *const Task, args: Args) !bool {
        var ok = true;
        for(args.filters.items) |item| {
            const color: bool = switch(item[0]){
                '+'  => true,
                '!'  => false,
                else => return error.BadFilterColor
            };
            switch(item[1]){
                ':' => {
                    // this is a tag filter
                    if( item.len < 3 ) return error.FilterTooShort;
                    const value = item[2..];
                    var has = false;
                    for( task.tags.items ) |tag| {
                        has = has or std.mem.eql(u8, value, tag);
                    }
                    ok = ok and !( color != has );
                },
                '#' => {
                    // this is a title filter
                    if( item.len < 3 ) return error.FilterTooShort;
                    const value = item[2..];
                    var has = false;
                    var words = std.mem.splitScalar(u8, task.name, ' ');
                    while( words.next() ) |word| {
                        has = has or std.mem.eql(u8, value, word);
                    }
                    ok = ok and !( color != has );
                },
                '?' => {
                    // this is a note filter
                    if( item.len < 3 ) return error.FilterTooShort;
                    if( task.note.len > 0 ) {
                        const value = item[2..];
                        var has = false;
                        var words = std.mem.splitScalar(u8, task.note, ' ');
                        while( words.next() ) |word| {
                            has = has or std.mem.eql(u8, value, word);
                        }
                        ok = ok and !( color != has );
                    }
                },
                '*' => {
                    // everything filter
                    if( item.len < 3 ) return error.FilterTooShort;
                    const value = item[2..];

                    // this is a tag filter
                    var has = false;
                    for( task.tags.items ) |tag| {
                        has = has or std.mem.eql(u8, value, tag);
                    }
                    ok = ok and !( color != has );

                    // this is a title filter
                    var words = std.mem.splitScalar(u8, task.name, ' ');
                    while( words.next() ) |word| {
                        has = has or std.mem.eql(u8, value, word);
                    }
                    ok = ok and !( color != has );

                    // this is a note filter
                    if( task.note.len > 0 ) {
                        words = std.mem.splitScalar(u8, task.note, ' ');
                        while( words.next() ) |word| {
                            has = has or std.mem.eql(u8, value, word);
                        }
                        ok = ok and !( color != has );
                    }
                },
                else => {
                    std.log.debug("Filtering [{s}] for tag and title by default <{s}>", .{task.name, item});
                    // by default filter tags and title
                    if( item.len < 2 ) return error.FilterTooShort;
                    const value = item[1..];

                    // this is a tag filter
                    var has = false;
                    for( task.tags.items ) |tag| {
                        has = has or std.mem.eql(u8, value, tag);
                    }

                    var words = std.mem.splitScalar(u8, task.name, ' ');
                    while( words.next() ) |word| {
                        has = has or std.mem.eql(u8, value, word);
                    }
                    ok = ok and !( color != has );
                }
            }
        }
        return !ok;
    }
};


pub const Board = struct {
    alloc: std.mem.Allocator,
    task_locations: std.ArrayList([]const u8),
    tasks: std.ArrayList(Task),
    today: datetime.DateTime,
    current_location: []const u8,
    global_location: ?[]const u8,
    registry: Registry,

    commands: std.StringHashMap(Command),
    cli_commands: []const Command = &.{
        .{
            .name = "help",
            .description = "Print commands, flags, and options",
            .flags = &.{
                .{"-l", "--long",     "Print long descriptions"},
            },
            .action = @This().help
        },
        .{
            .name = "add",
            .description = \\Create a new task
            \\      > zdo [flags...] add [tags...] description [options...]
            \\
            \\      Example:
            \\      > zdo -g add +home Buy milk and eggs -d 2024-06-20 --priority 3
            \\      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\        |
            \\        +-> CREATE a new GLOBAL task called `Buy milk and eggs`
            \\            TAG with `home`
            \\            SET DUE as June 20, 2024
            \\            SET PRIORITY as 3/10
            \\
            ,
            .flags = &.{
                .{"-g", "--global",   "Make the new task global"},
                .{"-i", null,         "Interactively add an additional description"},
            },
            .options = &.{
                .{"-d", "--due",      "Due date in YYYY-MM-DD format"},
                .{"-s", "--start",    "Start date in YYYY-MM-DD format"},
                .{"-p", "--priority", "Priority value from 0 to 10"},
                .{"-x", "--extra",    "Add an additional description"},
            },
            .action = @This().add
        },
        .{
            .name = "list",
            .description = \\List all found tasks
            \\      > zdo [flags...] [filters...] list [filters...]
            \\
            \\      Example:
            \\      > zdo -l list +home
            \\
            \\      Filters:
            \\            +   ->  Keep Only
            \\            !   ->  Keep All Except
            \\        (+/!)   ->  Default Title & Tags
            \\        (+/!) : ->  Tags
            \\        (+/!) # ->  Title
            \\        (+/!) ? ->  Note
            \\        (+/!) * ->  All
            \\
            \\      Example:
            \\      > zdo !:personal +#issue list
            \\      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\        |
            \\        +-> list all tasks that are NOT tagged `personal`
            \\            AND which INCLUDE `issue` in the title
            \\
            ,
            .flags = &.{
                .{"-l", "--long", "Print long-form tasks"},
                .{"-f", "--flat", "Use a flat structure when displaying and sorting"}
            },
            .action = @This().list
        },
        .{
            .name = "view",
            .description = \\Update a task's status
            \\      > zdo [flags...] view id
            \\  
            \\      Example:
            \\      > zdo view i3
            \\      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\        |
            \\        +-> prints the long-form task with id "i3"
            \\
            ,
            .action = @This().view
        },
        .{
            .name = "mark",
            .description = \\Update a task's status
            \\      This will mark `done` if no status is given.
            \\
            \\      > zdo [flags...] mark [status...] id [status...]
            \\
            \\      Example:
            \\      > zdo mark 4 -a
            \\      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\        |
            \\        +-> mark the status for task with id "4" as `active`
            \\
            ,
            .flags = &.{
                .{"-d", "--done",     "Mark task as complete"},
                .{"-p", "--pending",  "Mark task as pending"},
                .{"-h", "--hidden",   "Mark task as hidden"},
                .{"-w", "--waiting",  "Mark task as waiting"},
                .{"-a", "--active",   "Mark task as complete"},
            },
            .action = @This().mark
        }
    },

    pub fn init(alloc: std.mem.Allocator, args: Args) !Board {
        var task_locations = std.ArrayList([]const u8).init(alloc);
        
        const current_location = try std.fs.cwd().realpathAlloc(alloc, "./.tasks/");
        try task_locations.append(current_location);
        const root_reg = try Registry.init(alloc, "./.tasks/", .{});

        if(args.options.get("dirs")) |path_override|{
            std.log.debug("Overriding default task directory", .{});
            var path_iter = std.mem.splitScalar(u8, path_override, ',');
            while(path_iter.next()) |path| {
                const abspath = if(std.fs.path.isAbsolute(path))
                    path
                else 
                    std.fs.cwd().realpathAlloc(alloc, path) catch |err| switch(err){
                        error.FileNotFound => {
                            std.log.err("Could not find directory: {s}", .{path});
                            return err;
                        },
                        else => return err
                    };
                std.log.debug("    Appending paths: {s}", .{abspath});
                try task_locations.append(abspath);
            }
        }

        var global_location: ?[]const u8 = null;
        if(!args.flags.contains("current")) {
            const appdata_path = try std.fs.getAppDataDir(alloc, "zdo");
            const global_tasks_path = try std.fs.path.join(alloc, &.{appdata_path, "global_tasks"});
            var appdata_dir = std.fs.openDirAbsolute(global_tasks_path, .{}) catch |err| switch(err){
                error.FileNotFound => blk: {
                    try std.fs.makeDirAbsolute(global_tasks_path);
                    break :blk try std.fs.openDirAbsolute(global_tasks_path, .{});
                },
                else => return err
            };
            appdata_dir.close();

            std.log.debug("Adding global tasks: {s}", .{global_tasks_path});
            try task_locations.append(global_tasks_path);
            global_location = global_tasks_path;
        }

        var board = Board{
            .alloc = alloc,
            .task_locations = task_locations,
            .current_location = current_location,
            .global_location = global_location,
            .tasks = std.ArrayList(Task).init(alloc),
            .today = datetime.DateTime.today(),
            .commands = std.StringHashMap(Command).init(alloc),
            .registry = root_reg,
        };
        for(board.cli_commands) |cmd| {
            try board.commands.put(cmd.name, cmd);
        }
        return board;
    }

    pub fn deinit(self: *Board) void {
        for(self.tasks) |task| {
            task.deinit();
        }
        self.tasks.deinit();
        self.task_locations.deinit();
        self.registry.deinit();
    }

    pub fn help(board: *Board, args: Args) !void {
        // _ = args;
        const alloc = board.alloc;
        const stderr = std.io.getStdErr().writer();
        try args.printAll();
        try stderr.writeAll("Global Options:\n");
        for(global_flags) |flag| {
            try stderr.print("    {s: <3}{s: <15}{s}\n", .{
                flag[0] orelse "",
                flag[1] orelse "",
                flag[2],
            });
        }

        for(global_options) |option| {
            try stderr.print("    {s: <3}{s: <15}{s}\n", .{
                option[0] orelse "",
                option[1] orelse "",
                option[2],
            });
        }
        try stderr.writeAll("\n");
        try stderr.writeAll("\n");

        try stderr.writeAll("Board Commands:\n");
        const command_name_col_len = 10;
        var command_iter = board.commands.valueIterator();
        while(command_iter.next()) |command| {
            const command_name = try alloc.dupe(u8, " " ** command_name_col_len);
            defer alloc.free(command_name);

            const fmt_name = try std.fmt.allocPrint(alloc, "  `{s}`", .{command.name});
            defer alloc.free(fmt_name);
            std.mem.copyForwards(u8, command_name, fmt_name[0..@min(fmt_name.len, command_name_col_len)]);

            try stderr.print(
                "{s}{s}\n",
                .{
                    command_name,
                    if(args.flags.contains("long")) command.description else std.mem.sliceTo(command.description, '\n')
                }
            );
            if(command.flags) |flags|{
                for(flags) |flag| {
                    try stderr.print("      {s: <3}{s: <15}{s}\n", .{
                        flag[0] orelse "",
                        flag[1] orelse "",
                        if(args.flags.contains("long")) flag[2] else std.mem.sliceTo(flag[2], '\n'),
                    });
                }
            }
            if(command.options) |options|{
                for(options) |option| {
                    try stderr.print("      {s: <3}{s: <15}{s}\n", .{
                        option[0] orelse "",
                        option[1] orelse "",
                        if(args.flags.contains("long")) option[2] else std.mem.sliceTo(option[2], '\n'),
                    });
                }
            }
            try stderr.writeAll("\n");
        }
    }

    // pub fn loadTasks(self: *Board, args: Args) !void {
    //     try self.registry.loadTasks(args);
    // }

    pub fn list(
        self: *Board,
        args: Args
    ) !void {
        try self.registry.printTable(.{
            .long = args.flags.contains("long"),
            .flat = args.flags.contains("flat"),
            .command_args = args,
        });
    }

    pub fn add(
        self: *Board,
        args: Args,
    ) !void {
        // _ = self;
        // _ = args;
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Adding a task...\n");
        try args.printAll();

        var tags = std.ArrayList([]const u8).init(self.alloc);
        defer tags.deinit();
        if(args.filters.items.len > 0) {
            try stderr.print("Tags set:\n", .{});
            for(args.filters.items) |tag| {
                try stderr.print("    {s}\n", .{tag});
                try tags.append(tag[1..]);
            }
        }

        var due: ?datetime.DateTime = null;
        if(args.options.get("due")) |due_str| {
            due = try datetime.DateTime.fromDateString(due_str);
            const printstr = try due.?.toStr(self.alloc);
            defer self.alloc.free(printstr);
            try stderr.print("Has due date: {s}\n", .{printstr});
        }

        var start: ?datetime.DateTime = null;
        if(args.options.get("start")) |start_str| {
            start = try datetime.DateTime.fromDateString(start_str);
            const printstr = try start.?.toStr(self.alloc);
            defer self.alloc.free(printstr);
            try stderr.print("Has start date: {s}\n", .{printstr});
        }

        var priority: u4 = 0;
        if(args.options.get("priority")) |priority_str| {
            priority = try std.fmt.parseInt(u4, priority_str, 10);
            try stderr.print("Has priority: {d}\n", .{priority});
        }

        const description = try std.mem.join(self.alloc, " ", args.positional.items);
        try stderr.print("Description:\n{s}\n", .{description});

        // Capturing additional information
        var note: ?[]const u8 = null;
        if( args.flags.contains("x") ){
            try stderr.writeAll("> ");
            const stdin = std.io.getStdIn().reader();
            const value = try stdin.readUntilDelimiterAlloc(self.alloc, '\n', 1024);
            note = value;
        } else if (args.options.get("extra")) |extra_content|{
            note = extra_content;
        }

        // Create the file in either the global or current locations
        var location: std.fs.Dir = undefined;
        if(args.flags.get("global")) |global| {
            try stderr.print("Flag set for global: {}\n", .{global});
            if(self.global_location) |path| {
                location = try std.fs.openDirAbsolute(path, .{});
            } else {
                return error.NoGlobalPath;
            }
        } else {
            location = try std.fs.openDirAbsolute(self.current_location, .{});
        }

        // Create a new task and then have it write a file
        const task = Task.init(
            self.alloc,
            .{
                .name = description,
                .start = start,
                .due = due,
                .priority = priority,
                .tags = tags,
                .note = note orelse "",
                .today = self.today,
            }
        );
        try task.writeTaskFile(.{.dir = location});
    }

    fn getTaskFromArgs(self: *Board, args: Args) !*Task {
        try self.registry.loadTasks(args, .{});
        const stderr = std.io.getStdErr().writer();
        const user_id = args.positional.items[0];
        std.log.debug("Trying to find task {s}", .{user_id});
        if( try self.registry.getTaskById(user_id) ) |task| {
            return task;
        }
        try stderr.print("Couldn't find task with id: {s}", .{user_id});
        return error.TaskNotFound;
    }

    pub fn view(self: *Board, args: Args) !void {
        const task = try self.getTaskFromArgs(args);
        const stderr = std.io.getStdErr().writer();
        try stderr.print("{s}", .{try task.makeStr(self.alloc, .{})});
    }

    pub fn mark(self: *Board, args: Args) !void {
        const task = try self.getTaskFromArgs(args);
        // const stderr = std.io.getStdErr().writer();
        var status: tasklib.TaskStatus = .done;
        if(args.flags.get("hidden"))|_|{       status = .hidden;  }
        else if(args.flags.get("active"))|_|{  status = .active;  }
        else if(args.flags.get("waiting"))|_|{ status = .waiting; }
        else if(args.flags.get("pending"))|_|{ status = .pending; }

        try task.mark(status);
        // try stderr.writeAll("\n~*.'[ Done! ]'.*~\n\n");
        try self.list(args);
    }
};