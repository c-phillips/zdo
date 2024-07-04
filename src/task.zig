const std = @import("std");
const datetime = @import("datetime.zig");
const util = @import("util.zig");

const MAX_FILESIZE:usize = 1024;

pub const TaskStatus = enum(u3) {
    pending,
    waiting,
    hidden,
    active,
    done,
};

pub const SortAttribute = enum(u3) {
    creation,
    priority,
    due,
    start,
};

pub const Task = struct {
    name: []const u8,
    start: ?datetime.DateTime,
    due: ?datetime.DateTime,
    priority: u8,
    tags: std.ArrayList([]const u8),
    note: []const u8,
    
    status: TaskStatus = .pending,
    days_until_start: ?i32,
    days_until_due: ?i32,
    alloc: std.mem.Allocator,

    file_path: ?[]const u8 = null,
    file_hash: ?u32 = null,
    file_meta: ?std.fs.File.Metadata = null,

    /// Set by the container
    _id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, args: struct {
        name: []const u8,
        priority: u8,
        tags: std.ArrayList([]const u8),
        note: []const u8,

        status: TaskStatus = .pending,
        due:   ?datetime.DateTime = null,
        start: ?datetime.DateTime = null,
        today: ?datetime.DateTime = null,
        file_path: ?[]const u8 = null,
        file_hash: ?u32 = null,
        file_meta: ?std.fs.File.Metadata = null,
    }) Task {
        var today = args.today orelse datetime.DateTime.today();

        var status: TaskStatus = args.status;
        var days_until_due: ?i32 = null;
        var days_until_start: ?i32 = null;
        if(args.due) |due|{
            days_until_due = today.deltaDays(due)+1;
        }
        if(args.start) |start|{
            days_until_start = today.deltaDays(start);
            if( days_until_start.? > 0 ){
                status = .waiting;
            } else {
                status = .active;
            }
        }

        return Task{
            .name = args.name,
            .start = args.start,
            .due = args.due,
            .priority = args.priority,
            .tags = args.tags,
            .note = args.note,

            .status = status,
            .days_until_start = days_until_start,
            .days_until_due = days_until_due,
            .alloc = allocator,

            .file_path = args.file_path,
            .file_hash = args.file_hash,
            .file_meta = args.file_meta,
        };
    }

    pub fn deinit(self: Task) void {
        self.tags.allocator.free(self.tags);
    }

    /// WARNING: This will overwrite the frontmatter with whatever is in props!
    /// If you want to preserve the frontmatter that is already there, you need
    /// to first read the contents into your hashmap!
    /// TODO: Add proper YAML parsing to prevent overwriting other user-set data
    pub fn updateFileFrontmatter(self: *const Task, props: std.StringHashMap([]const u8), opts: struct {
        abspath: ?[]const u8 = null,
        relpath: ?[]const u8 = null,
    }) !void {
        var file: std.fs.File = undefined;
        if(opts.abspath) |abspath| {
            file = try std.fs.openFileAbsolute(abspath, .{.mode = .read_write});
        } else if(opts.relpath) |relpath| {
            file = try std.fs.cwd().openFile(relpath, .{.mode = .read_write});
        }
        defer file.close();
        try file.setEndPos(0); // clear the file
        const writer = file.writer();
        try writer.writeAll("---\n");
        var iter = props.iterator();
        while(iter.next()) |entry| {
            // TODO: Fix lists...
            if(std.mem.eql(u8, entry.key_ptr.*, "tags")){
                try writer.print("{s}: [{s}]\n", .{entry.key_ptr.*, entry.value_ptr.*});
            } else {
                try writer.print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
            }
        }
        try writer.print("---\n{s}", .{self.note});
    }

    pub fn writeTaskFile(self: *const Task, opts: struct {
        dir: ?std.fs.Dir = null,
        abspath: ?[]const u8 = null,
        relpath: ?[]const u8 = null,
    }) !void {
        // TODO: handle conflicts
        var file: std.fs.File = undefined;
        if(opts.dir) |path|{
            const file_name = try std.fmt.allocPrint(self.alloc, "{s}.md", .{ self.name[0..@min(30, self.name.len)] });
            defer self.alloc.free(file_name);
            file = try path.createFile(file_name, .{});
        } else if(opts.abspath) |abspath| {
            file = try std.fs.openFileAbsolute(abspath, .{.mode = .write_only});
        } else if(opts.relpath) |relpath| {
            file = try std.fs.cwd().openFile(relpath, .{.mode = .write_only});
        }
        defer file.close();
        const writer = file.writer();
        
        // TODO: add status initializers
        try writer.print(\\---
        \\priority: {d}
        \\status: {s}
        \\
        , .{self.priority, @tagName(self.status)});

        if(self.tags.items.len > 0){
            try writer.writeAll("tags: [");
            for(self.tags.items, 0..) |item, idx| {
                if( idx < self.tags.items.len - 1){
                    try writer.print("{s}", .{item});
                } else {
                    try writer.print("{s},", .{item});
                }
            }
            try writer.writeAll("]\n");
        }

        if( self.due ) |due_date| {
            const due_str = try due_date.toStr(self.alloc);
            defer self.alloc.free(due_str);
            try writer.print("due: {s}\n", .{due_str});
        }
        if( self.start ) |start_date| {
            const start_str = try start_date.toStr(self.alloc);
            defer self.alloc.free(start_str);
            try writer.print("start: {s}\n", .{start_str});
        }

        try writer.print("---\n# {s}\n{s}", .{self.name, self.note});
    }

    fn parseFrontmatter(alloc: std.mem.Allocator, yaml: []const u8) !std.StringHashMap([]const u8) {
        var lines = std.mem.splitSequence(u8, yaml, "\n");
        var propmap = std.StringHashMap([]const u8).init(alloc);
        while(lines.next()) |raw_line|{
            const line = util.trim(raw_line);
            // process the frontmatter entries
            // frontmatter entries are generally YAML, but I don't support all that right now
            if(line.len < 1 or line[0] == '#') continue;
            var parts = std.mem.splitScalar(u8, line, ':');
            const name = parts.next().?;
            const value = parts.next();
            if( value ) |v| {
                var val_str = util.trim(v);
                if( val_str.len == 0 ){
                    const next_line = util.trim(lines.peek().?);
                    if( std.mem.startsWith(u8, "  -", next_line) ){
                        // this is a YAML multiline list
                        // TODO: Support this
                        continue;
                    } else {
                        // There's just a property with a missing value or something...
                        continue;
                    }
                } else {
                    if( val_str[0] == '[' ) {
                        val_str = val_str[1..val_str.len-1];
                    }
                    try propmap.put(name, val_str);
                }
            } else {
                std.log.debug("ERROR ON LINE: {s}, {s}:{s}", .{line, name, value orelse "null"});
                return error.InvalidIdentifier;
            }
        }
        return propmap;
    }

    pub fn fromTaskFile(alloc: std.mem.Allocator, path: []const u8, opts: struct {today: ?datetime.DateTime = null}) !Task {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const metadata = try file.metadata();

        // TODO: switch to a streaming setup and remove the filesize restriction
        const buf = try file.readToEndAlloc(alloc, MAX_FILESIZE);

        var propmap: std.StringHashMap([]const u8) = undefined;

        if( !std.mem.startsWith(u8, buf, "---") ){
            // handle a file without frontmatter
            propmap = std.StringHashMap([]const u8).init(alloc);
            var line_iter = std.mem.splitScalar(u8, util.trim(buf), '\n');
            if(line_iter.next())|first_line|{
                if( util.trim(first_line)[0] == '#' ){
                    try propmap.put("name", util.trim(first_line[1..]));
                }
            }
            try propmap.put("description", buf);
        } else {
            var parts = std.mem.splitSequence(u8, buf, "---");
            _ = parts.next();  // first part is empty
            propmap = try Task.parseFrontmatter(alloc, util.trim(parts.next().?));

            if(propmap.get("name") == null) {
                if(parts.peek()) |description|{
                    if( description.len > 0 ){
                        var line_iter = std.mem.splitScalar(u8, util.trim(description), '\n');
                        if(line_iter.next())|first_line|{
                            if( util.trim(first_line)[0] == '#' ){
                                try propmap.put("name", util.trim(first_line[1..]));
                            }
                        }
                    }
                }
            }

            const description = parts.rest();
            try propmap.put("description", description);
        }

        // If there's no first header, the best backup option is the filename
        if( !propmap.contains("name") ) {
            try propmap.put("name", std.fs.path.stem(path));
        }

        const priority_val = try std.fmt.parseInt(u8, propmap.get("priority") orelse "0", 10);

        var due: ?datetime.DateTime = null;
        if(propmap.get("due")) |due_str| {
            due = try datetime.DateTime.fromDateString(due_str);
        }
        var start: ?datetime.DateTime = null;
        if(propmap.get("start")) |start_str| {
            start = try datetime.DateTime.fromDateString(start_str);
        }

        var tag_list = std.ArrayList([]const u8).init(alloc);
        const tag_str = propmap.get("tags") orelse "";
        if(tag_str.len > 0){
            var tag_iter = std.mem.splitScalar(u8, tag_str, ',');
            while(tag_iter.next()) |tag| {
                if(tag.len > 0) try tag_list.append(util.trim(tag));
            }
        }
        return Task.init(alloc, .{
            .today = opts.today,
            .name     = propmap.get("name") orelse std.fs.path.basename(path),
            .start  = start,
            .due      = due,
            .priority = priority_val,
            .tags     = tag_list,
            .note     = util.trim(propmap.get("description") orelse ""),
            .status = std.meta.stringToEnum(TaskStatus, propmap.get("status") orelse "pending") orelse .pending,

            .file_path = path,
            .file_hash = std.hash.CityHash32.hash(buf),
            .file_meta = metadata,
        });
    }

    pub fn makeStr(
        self: *const Task,
        alloc: std.mem.Allocator,
        opts: struct {
                short: bool = false,
                end: []const u8 = "\n",
                linewidth: u8 = 80,
            }
        ) ![]const u8 {

        const name_col_len: usize = if(opts.short) 50 else opts.linewidth-8;
        var name_col = try alloc.dupe(u8, " " ** 256);
        const name_len = if(self.name.len <= name_col_len) self.name.len else name_col_len;
        defer alloc.free(name_col);
        std.mem.copyForwards(u8, name_col, self.name[0..name_len]);
        if( self.name.len > name_col_len ){
            name_col[name_len-1] = '.';
            name_col[name_len-2] = '.';
            name_col[name_len-3] = '.';
        }
        name_col = name_col[0..name_col_len];

        var datefmt: ?[]const u8 = null;
        if( self.due ) |_| {
            if(self.days_until_due.? > 0) {
                if( self.start )|_|{
                    if(self.days_until_start.? <= 0){
                        // middle of the task timeline
                        datefmt = try std.fmt.allocPrint(alloc, "{d}d remaining", .{self.days_until_due.?});
                    } else {
                        // don't need to start yet
                        datefmt = try std.fmt.allocPrint(alloc, "Starts in {d}d", .{self.days_until_start.?});
                    }
                } else {
                    datefmt = try std.fmt.allocPrint(alloc, "Due in {d}d", .{self.days_until_due.?});
                }
            } else if (self.days_until_due.? < 0){
                datefmt = try std.fmt.allocPrint(alloc, "Due {d}d ago", .{-1*self.days_until_due.?});
            } else {
                datefmt = try std.fmt.allocPrint(alloc, "Due today!", .{});
            }
        } else if( self.start ) |_| {
            if(self.days_until_start.? > 0) {
                datefmt = try std.fmt.allocPrint(alloc, "Starts in {d}d", .{self.days_until_start.?});
            } else if (self.days_until_start.? < 0){
                datefmt = try std.fmt.allocPrint(alloc, "Started {d}d ago", .{-1*self.days_until_start.?});
            } else {
                datefmt = try std.fmt.allocPrint(alloc, "Starts today!", .{});
            }
        }
        const datestr = datefmt orelse "Anytime";
        defer {
            if(datefmt != null) alloc.free(datefmt.?);
        }


        const checkbox = switch(self.status) {
            .pending => "[ ] ",
            .waiting => "[z] ",
            .hidden  => "[_] ",
            .active  => "[-] ",
            .done    => "[x] "
        };

        var priority_symbol: u8 = '.';
        if(self.priority > 2 and self.priority <= 4) {
            priority_symbol = '-';
        } else if(self.priority > 4 and self.priority <= 6) {
            priority_symbol = '=';
        } else if(self.priority > 6 and self.priority <= 8) {
            priority_symbol = 'o';
        } else if(self.priority > 8) {
            priority_symbol = '#';
        }

        if(opts.short){
            return try std.fmt.allocPrint(
                alloc,
                "{s} {c}  {s}  {s}{s}",
                .{
                    checkbox,
                    priority_symbol,
                    name_col,
                    datestr,
                    opts.end,
                }
            );
        } else {
            const tag_str = try std.mem.join(alloc, ", ", self.tags.items);
            defer alloc.free(tag_str);

            if(self.note.len == 0){
                return try std.fmt.allocPrint(
                    alloc,
                    "{s} {c}  {s}\n    {s}\n    Tags: {{{s}}}{s}",
                    .{
                        checkbox,
                        priority_symbol,
                        name_col,
                        datestr,
                        tag_str,
                        opts.end
                    }
                );
            } else {
                var note_lines = std.ArrayList([]const u8).init(alloc);
                defer note_lines.deinit();
                var note_paragraphs = std.mem.splitSequence(u8, self.note, "\n");
                while(note_paragraphs.next()) |original_paragraph|{
                    // var paragraph = try alloc.dupe(u8, original_paragraph);
                    // paragraph = paragraph;
                    // _ = std.mem.replace(u8, original_paragraph, "\n", "\n ", paragraph);
                    const paragraph = try std.mem.replaceOwned(u8, alloc, original_paragraph, "\n", "\n    ");
                    defer alloc.free(paragraph);

                    var words = std.mem.splitScalar(u8, paragraph, ' ');

                    var paragraph_lines = std.ArrayList([]const u8).init(alloc);
                    defer paragraph_lines.deinit();

                    var current_line = std.ArrayList([]const u8).init(alloc);
                    defer current_line.deinit();

                    const line_start = "       ";
                    try current_line.append(line_start);
                    var line_length = line_start.len + 1;
                    while(words.next()) |word| {
                        const new_len = word.len + line_length - 1;
                        if( new_len >= opts.linewidth + 4 ) {
                            // create new line
                            const full_line = try std.mem.join(alloc, " ", current_line.items);
                            try paragraph_lines.append(full_line);
                            try current_line.resize(0);
                            try current_line.append(line_start);
                            line_length = line_start.len + 1;
                        }
                        try current_line.append(word);
                        line_length += word.len + 1;
                    }
                    const full_line = try std.mem.join(alloc, " ", current_line.items);
                    try paragraph_lines.append(full_line);

                    const joined_paragraphs = try std.mem.join(alloc, "\n", paragraph_lines.items);
                    try note_lines.append(joined_paragraphs);
                }
                const note = try std.mem.join(alloc, "\n", note_lines.items);
                defer alloc.free(note);

                return try std.fmt.allocPrint(
                    alloc,
                    "{s} {c}  {s}\n    {s}\n    Tags: {{{s}}}\n    Note:\n{s}{s}",
                    .{
                        checkbox,
                        priority_symbol,
                        name_col,
                        datestr,
                        tag_str,
                        note,
                        opts.end
                    }
                );
            }
        }
    }

    pub fn mark(self: *Task, status: TaskStatus) !void {
        self.status = status;
        if(self.file_path) |path| {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();

            const reader = file.reader();
            const buf = try reader.readAllAlloc(self.alloc, MAX_FILESIZE);
            var propmap: std.StringHashMap([]const u8) = undefined;

            if( !std.mem.startsWith(u8, buf, "---") ){
                // handle a file without frontmatter
                propmap = std.StringHashMap([]const u8).init(self.alloc);
            } else {
                var parts = std.mem.splitSequence(u8, buf, "---");
                _ = parts.next();  // first part is empty
                propmap = try Task.parseFrontmatter(self.alloc, util.trim(parts.next().?));
            }
            try propmap.put("status", @tagName(status));
            try self.updateFileFrontmatter(propmap, .{.abspath = path});
        }
    }

    pub fn olderThan(self: Task, other: Task) bool {
        if(self.file_meta.?.created()) |self_created|{
            if(other.file_meta.?.created()) |other_created|{
                return self_created > other_created;
            }
            return true;
        }
        return false;
    }

    pub fn moreImportantThan(self: Task, other: Task) bool {
        return self.priority > other.priority;
    }

    pub fn dueSoonerThan(self: Task, other: Task) bool {
        if(self.days_until_due) |self_days_until_due|{
            if(other.days_until_due) |other_days_until_due|{
                return self_days_until_due < other_days_until_due;
            }
            return true;
        }
        return false;
    }

    pub fn startsSoonerThan(self: Task, other: Task) bool {
        if(self.days_until_start) |self_days_until_start|{
            if(other.days_until_start) |other_days_until_start|{
                return self_days_until_start < other_days_until_start;
            }
            return true;
        }
        return false;
    }

    pub fn sortWithContext(context: SortAttribute, a: Task, b: Task) bool {
        return switch(context) {
            .priority => b.moreImportantThan(a),
            .due      => b.dueSoonerThan(a),
            .start    => b.startsSoonerThan(a),
            else      => b.olderThan(a)
        };
    }
};


/// Will use the allocator attached to the task_list
pub fn loadLocationToList(task_list: *std.ArrayList(Task), opts: struct{
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
