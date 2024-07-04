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



pub const Container = struct {
    alloc: std.mem.Allocator,
    abspath: []const u8,
    dirname: []const u8,
    table: ?Table = null,
    tasks: std.ArrayList(Task),
    global: bool = false,
    prefix: []const u8 = "",
    parent: ?*const Container = null,
    children: ?std.ArrayList(Container) = null,
    child_prefix_map: ?std.StringHashMap(*Container) = null,
    task_map: ?std.StringHashMap(*Task) = null,
    level: u8 = 0,
    valid_child_tasks: bool = false,

    pub fn deinit(self: *Container) void {
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
        parent: ?*const Container = null,
        global: bool = false,
        prefix: ?[]const u8 = null,
        level: u8 = 0,
    }) !Container {
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

        std.log.debug("Initializing Container for {s} @ {s}", .{std.fs.path.basename(abspath), abspath});
        var self = try alloc.create(Container);
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

            var children = std.ArrayList(Container).init(alloc);
            var child_prefix_map = std.StringHashMap(*Container).init(alloc);

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
                    try Container.init(alloc, child_location, .{
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

    pub fn printTable(self: *Container, args: struct{
        long: bool = false,
        flat: bool = false,
        command_args: ?Args = null,
    }) !void {

        const stdout = std.io.getStdOut().writer();
        if(self.parent == null){
            try self.loadTasks(args.command_args.?, .{.flat = args.flat});
        }
        
        var have_tasks = false;
        for(self.tasks.items) |task| {
            have_tasks = have_tasks or !task._filtered;
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
        for(self.tasks.items) |task| {
            if(task._filtered) continue;

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

    pub fn loadTasks(self: *Container, args: Args, opts: struct{
        flat: bool = false,
    }) !void {
        if(self.tasks.items.len > 0) return; // only load once
        // load all of the tasks in our flat location into our task list
        try tasklib.loadLocationToList(&self.tasks, .{
            .abs_location = self.abspath,
            .today = datetime.DateTime.today()
        });

        std.mem.sort(Task, self.tasks.items, tasklib.SortAttribute.creation, Task.sortWithContext);
        
        var task_map = std.StringHashMap(*Task).init(self.alloc);
        for(self.tasks.items, 0..) |*task, idx| {
            task._id = try std.fmt.allocPrint(task.alloc, "{s}{d}", .{self.prefix, idx});
            task._filtered = try Container.filterTask(task, args);
            try task_map.put(task._id.?, task);
        }
        self.task_map = task_map;

        if( self.children ) |children| {
            for(children.items) |*child| {
                std.log.debug("Loading tasks for {s}", .{child.dirname});
                try child.loadTasks(args, opts);
            }
        }

        if( opts.flat ){
            if(self.children)|children|{
                for(children.items) |child| {
                    // join the child tasks and filter mask into the parent's
                    try self.tasks.appendSlice(child.tasks.items);
                }
            }
        }
        
        if(args.options.contains("sort") or (opts.flat and self.parent == null)) try self.sortBy(args);
    }

    pub fn sortBy(self: *Container, args: Args) !void {
        const user_sort = args.options.get("sort") orelse "c";
        const sort_attr: tasklib.SortAttribute = switch(user_sort[0]){
            'p'  => .priority,
            'd'  => .due,
            's'  => .start,
            else => .creation,
        };
        std.mem.sort(Task, self.tasks.items, sort_attr, Task.sortWithContext);

        // TODO: Figure out if there's a more efficient way to do this so we don't keep
        //       reiterating over the list
        if( args.flags.contains("desc") ){
            std.mem.reverse(Task, self.tasks.items);
        }
    }

    pub fn getTaskById(self: *const Container, id: []const u8) !?*Task {
        if( self.task_map ) |task_map| {
            std.log.debug("Container {s} ({s}): searching for {s}...", .{self.dirname, self.prefix, id});
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
                '@' => {
                    // this is a status filter
                    if( item.len < 3 ) return error.FilterTooShort;
                    const value_str = item[2..];
                    const value_enum = std.meta.stringToEnum(tasklib.TaskStatus, value_str);
                    if( value_enum ) |value| {
                        const has: bool = task.status == value;
                        ok = ok and !( color != has );
                        std.log.debug("Filtering [{s}] for status value {}  ->  {} => {}", .{task.name, value, has, ok});
                    } else {
                        std.log.err("Bad status name: {s}", .{value_str});
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