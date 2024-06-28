const std = @import("std");
const trim = @import("util.zig").trim;

const RowIterator = struct {
    alloc: std.mem.Allocator,
    rows: *std.ArrayList(std.ArrayList([]const u8)),
    index: usize = 0,
    col_names: ?std.ArrayList([]const u8) = null,

    pub fn next(self: *RowIterator) ?std.ArrayList([]const u8) {
        if( self.index >= self.rows.items[0].len ) return null;
        self.index += 1;
        return &self.rows.items[self.index];
    }
};


pub const Table = struct{
    alloc: std.mem.Allocator,
    row_values: std.ArrayList(std.ArrayList([]const u8)) = undefined,
    col_names: ?std.ArrayList([]const u8),
    path: ?[]const u8 = null,

    pub fn deinit(self: *Table) void {
        self.row_values.deinit();
        if( self.col_names ) |col_names| {
            col_names.deinit();
        }
    }

    pub fn getRow(self: *const Table, index: usize) !*const std.ArrayList([]const u8) {
        if( index >= self.row_values.items.len ) {
            return error.OutOfBounds;
        }
        return &self.row_values.items[index];
    }

    pub fn getColIdx(self: *const Table, idx: usize) ![]*[]const u8 {
        var column = try self.alloc.alloc(*[]const u8, self.row_values.items.len);
        for( self.row_values.items, 0..) |row, row_idx|{
            if( row.items.len <= idx ) return error.ColumnIndexOutOfBounds;
            column[row_idx] = &row.items[idx];
        }
        return column;
    }

    pub fn getCol(self: *const Table, name: []const u8) ![]*[]const u8 {
        if( self.col_names ) |columns| {
            var col_idx: usize = 0;
            for( columns.items, 0.. ) |column_name, idx| {
                if( std.mem.eql(u8, column_name, name) ) {
                    col_idx = idx;
                    break;
                }
            }
            return try self.getColIdx(col_idx);
        }
        return error.NoColumnNames;
    }

    pub fn getRowMap(self: *const Table, index: usize) !*const std.StringHashMap([]const u8) {
        const row = try self.getRow(index);
        var map = try std.StringHashMap([]const u8).init(self.alloc);
        for(row.items, 0..) |entry, idx| {
            map.put(self.col_names[idx], entry);
        }
        return &map;
    }

    pub fn iterrows(self: *const Table) !RowIterator {
        return .{
            .alloc = self.alloc,
            .rows = &self.row_values,
            .col_names = &self.col_names,
        };
    }
    
    /// Will prefer the abspath if provided
    pub fn fromCSV(alloc: std.mem.Allocator, opts: struct {
        relpath: ?[]const u8 = null,
        abspath: ?[]const u8 = null,
        header: bool = false,
    }) !Table{
        var file: std.fs.File = undefined;
        if( opts.abspath ) |abspath| {
            file = try std.fs.openFileAbsolute(abspath, .{});
        } else if( opts.relpath ) |relpath| {
            file = try std.fs.cwd().openFile(relpath, .{});
        } else {
            return error.NoPathSpecified;
        }
        defer file.close();

        const reader = file.reader();
        var line = try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 512);
        if( line == null ) return error.NoRowsFound;

        var header: ?std.ArrayList([]const u8) = null;
        if(opts.header) {
            header = std.ArrayList([]const u8).init(alloc);
            var column_names = std.mem.splitScalar(u8, trim(line.?), ',');
            while(column_names.next()) |column_name| {
                try header.?.append(trim(column_name));
            }
            line = try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 512);
        }
        var rows = std.ArrayList(std.ArrayList([]const u8)).init(alloc);
        while(line) |buf| : (line = try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 512)) {
            var values = std.mem.splitScalar(u8, trim(buf), ',');
            var row = std.ArrayList([]const u8).init(alloc);
            var index: usize = 0;
            while(values.next()) |value| : (index += 1) {
                try row.append(trim(value));
            }
            if( opts.header and index != header.?.items.len ) return error.WrongNumberOfEntries;
            if( rows.items.len > 0 ){
                if( rows.items[0].items.len != row.items.len ) return error.WrongNumberOfEntries;
            }
            try rows.append(row);
        }

        return .{
            .alloc = alloc,
            .path = opts.relpath orelse opts.abspath,
            .row_values = rows,
            .col_names = header,
        };
    }
};

