const std = @import("std");
const tasklib = @import("task.zig");
const Task = tasklib.Task;
const argparse = @import("argparse.zig");
const Args = argparse.Args;
const Container = @import("container.zig").Container;

pub fn tag_filter(value: []const u8, color: bool, tags: *const std.ArrayList([]const u8)) bool {
    var has = false;
    for (tags.items) |tag| {
        has = has or std.mem.eql(u8, value, tag);
    }
    return !(color != has);
}

pub fn word_filter_exact(value: []const u8, color: bool, buffer: []const u8) bool {
    var has = false;
    var words = std.mem.splitScalar(u8, buffer, ' ');
    while (words.next()) |word| {
        has = has or std.mem.eql(u8, value, word);
    }
    return !(color != has);
}

pub fn status_filter(value: []const u8, color: bool, task: *const Task) bool {
    const value_enum = std.meta.stringToEnum(tasklib.TaskStatus, value);
    if (value_enum) |v| {
        const has: bool = task.status == v;
        std.log.debug("Filtering [{s}] for status value {any}  ->  {any}", .{ task.name, value, has});
        return !(color != has);
    } else {
        std.log.err("Bad status name: {s}", .{value});
        return false;
    }
}

pub fn filterTask(task: *const Task, args: Args) !bool {
    var ok = true;
    for (args.filters.items) |item| {
        std.debug.print("Filter item {s}\n", .{item});
        if (item.len < 3) return error.FilterTooShort;
        const color_mark = item[0];
        const filter_mark = item[1];
        const filter_value = item[2..];
        const color: bool = switch (color_mark) {
            '+' => true,
            '_' => false,
            else => return error.BadFilterColor,
        };
        switch (filter_mark) {
            ':' => {
                ok = ok and tag_filter(filter_value, color, &task.tags);
            },
            '#' => {
                ok = ok and word_filter_exact(filter_value, color, task.name);
            },
            '?' => {
                if (task.note.len > 0) {
                    ok = ok and word_filter_exact(filter_value, color, task.note);
                }
            },
            '*' => {
                // everything filter
                ok = ok 
                and tag_filter(filter_value, color, &task.tags)
                and word_filter_exact(filter_value, color, task.name)
                and if(task.note.len > 0) word_filter_exact(filter_value, color, task.note) else true;
            },
            '@' => {
                ok = ok and status_filter(filter_value, color, task);
            },
            else => {
                std.log.debug("Filtering [{s}] for tag and title by default <{s}>", .{ task.name, item });
                // by default filter tags and title
                if (item.len < 2) return error.FilterTooShort;
                const value = item[1..];

                // this is a tag filter
                var has = false;
                for (task.tags.items) |tag| {
                    has = has or std.mem.eql(u8, value, tag);
                }

                var words = std.mem.splitScalar(u8, task.name, ' ');
                while (words.next()) |word| {
                    has = has or std.mem.eql(u8, value, word);
                }
                ok = ok and !(color != has);
            },
        }
    }
    return !ok;
}