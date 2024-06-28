const std = @import("std");

// 1971-01-01:00:00:00+0GMT relative to Unix Epoch
const baseline: u64 = 31536000;
const days_per_month = [12]u9{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

/// Sizes are meant to copy those used in the standard library
pub const DateTime = struct {
    year: u16,
    month: u4,
    day: u5,
    epoch: u64,

    /// YYYY-MM-DD formatted date string
    pub fn toStr(self: DateTime, alloc: std.mem.Allocator) std.fmt.AllocPrintError![]u8{
        return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}", .{self.year, self.month, self.day});
    }

    /// `a.deltaDays(b)` = days from a to b
    pub fn deltaDays(self: DateTime, other: DateTime) i32 {
        return @divFloor((@as(i32, @intCast(other.epoch)) - @as(i32, @intCast(self.epoch))), 86400);
    }

    pub fn today() DateTime {
        const ts: u64 = @intCast(std.time.timestamp());
        const yearday = std.time.epoch.EpochDay.calculateYearDay(std.time.epoch.EpochSeconds.getEpochDay(.{.secs = ts}));
        const monthday = yearday.calculateMonthDay();
        return DateTime{
            .year = yearday.year,
            .month = @intFromEnum(monthday.month),
            .day = monthday.day_index,
            .epoch = ts
        };
    }

    /// Parse a date string with the format YYYY-MM-DD
    pub fn fromDateString(date_string: []const u8) !DateTime {
        var part_iter = std.mem.splitScalar(u8, date_string, '-');

        const yearStr = part_iter.next() orelse unreachable;
        const monthStr = part_iter.next() orelse unreachable;
        const dayStr = part_iter.next() orelse unreachable;
        const year: std.time.epoch.Year = try std.fmt.parseInt(u16, yearStr, 10);
        const month: std.time.epoch.Month = @enumFromInt(try std.fmt.parseInt(u4, monthStr, 10));
        const day: u5 = try std.fmt.parseInt(u5, dayStr, 10);

        // I know this doesn't correctly handle the 100 and 400 year cases, but if
        // I'm still using this when I'm 105, I'll revisit and fix it...
        // the first leap year since our baseline date is 1972
        const full_years_since = year - 1971;
        var num_leap_days: u16 = switch(full_years_since) {
            0 => 0,
            1 => 0,
            2 => 1,
            3 => 1,
            else => full_years_since >> 2  // divide difference by 4
        };

        // check to see if the current year is a leap year and if the current date
        // is past February 28
        if( (0b11 & year) == 0 ){
            if( @intFromEnum(month) >= 2 and day > 28 ){
                num_leap_days += 1;
            }
        }

        var month_idx: u8 = 0;
        var days_this_year: u9 = 0;
        while( month_idx < @intFromEnum(month)-1 ): (month_idx += 1) {
            days_this_year += days_per_month[month_idx];
        }
        days_this_year += day;

        // unix time increments at exactly 86400/day, ignoring leap seconds
        const unix_seconds: u64 = (365 * full_years_since + @as(u64, days_this_year) + num_leap_days) * 86400 + baseline;

        return DateTime{
            .year = year,
            .month = @intFromEnum(month),
            .day = day,
            .epoch = unix_seconds,
        };
    }
};

