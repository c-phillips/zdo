const std = @import("std");
const tasklib = @import("task.zig");
const Task = tasklib.Task;
const datetime = @import("datetime.zig");
const Table = @import("table.zig").Table;
const Container = @import("container.zig").Container;

const argparse = @import("argparse.zig");
const Args = argparse.Args;
const ArgumentFormat = argparse.ArgumentFormat;
const Command = argparse.Command;

const util = @import("util.zig");
const trim = util.trim;


pub const global_flags: []const ArgumentFormat = &.{
    .{"-c", "--current", "Use current directory tasks only"},
    .{"-d", "--desc", "List in descending order"},
};
pub const global_options: []const ArgumentFormat = &.{
    .{null, "--dirs", "Comma separated list of task directories to include"},
    .{"-s", "--sort", \\Task attribute to sort (ascending by default)
    \\          `c`,`creation`  [Default] Task file creation date
    \\          `p`,`priority`  Task priortiy
    \\          `d`,`due`       Task due date
    \\          `s`,`start`     Task start date
    },
};


pub const Board = struct {
    alloc: std.mem.Allocator,
    task_locations: std.ArrayList([]const u8),
    tasks: std.ArrayList(Task),
    today: datetime.DateTime,
    current_location: []const u8,
    global_location: ?[]const u8,
    Container: Container,

    commands: std.StringHashMap(Command),
    cli_commands: []const Command = &.{
        .{
            .name = "help",
            .description = "See more info with `help [command]` or `help --long`",
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
            \\      > zdo [flags...] [filters...] list [filters...][options...]
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
            \\        (+/!) * ->  All above
            \\        (+/!) @ ->  Status
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
        
        var cwd_task_dir = std.fs.cwd().openDir(".tasks", .{}) catch |err| switch(err){
            error.FileNotFound => blk: {
                try std.fs.cwd().makeDir(".tasks");
                break :blk try std.fs.cwd().openDir(".tasks", .{});
            },
            else => return err
        };
        cwd_task_dir.close();
        const current_location = try std.fs.cwd().realpathAlloc(alloc, "./.tasks/");
        try task_locations.append(current_location);

        const root_cont = try Container.init(alloc, "./.tasks/", .{});

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
            .Container = root_cont,
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
        self.Container.deinit();
    }

    pub fn help(board: *Board, args: Args) !void {
        const alloc = board.alloc;
        const stderr = std.io.getStdErr().writer();

        // If the user provided a positional argument, lets try to print the
        // description for that command, otherwise just print all commands
        if(args.positional.items.len > 0){
            const user_command = args.positional.items[0];

            // find the actual command object
            for(board.cli_commands) |command_entry| {
                if( std.mem.eql(u8, command_entry.name, user_command) ){
                    try stderr.writeAll(try command_entry.makeStr(alloc, .{.long = true}));
                    return;
                }
            }
            try stderr.writeAll("Command not found!");
        }

        // Fallthrough condition: print all commands
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
        var command_iter = board.commands.valueIterator();
        while(command_iter.next()) |command| {
            try stderr.writeAll(try command.makeStr(alloc, .{.long = args.flags.contains("long")}));
        }
    }

    pub fn list(
        self: *Board,
        args: Args
    ) !void {
        try self.Container.printTable(.{
            .long = args.flags.contains("long"),
            .flat = args.flags.contains("flat"),
            .command_args = args,
        });
    }

    pub fn add(
        self: *Board,
        args: Args,
    ) !void {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Adding a task...\n");

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
        try self.Container.loadTasks(args, .{});
        const stderr = std.io.getStdErr().writer();
        const user_id = args.positional.items[0];
        std.log.debug("Trying to find task {s}", .{user_id});
        if( try self.Container.getTaskById(user_id) ) |task| {
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