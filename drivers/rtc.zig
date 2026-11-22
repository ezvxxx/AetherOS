const s = @import("../system/state.zig");
const io = @import("../arch/io.zig");

pub fn cmosRead(register: u8) u8 {
    io.out8(0x70, register & 0x7f);
    return io.in8(0x71);
}

pub fn fromBcd(value: u8) u8 {
    return (value >> 4) * 10 + (value & 0x0f);
}

pub fn writeTwoDigits(buffer: []u8, index: usize, value: u8) void {
    buffer[index] = '0' + value / 10;
    buffer[index + 1] = '0' + value % 10;
}

fn unixSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) 366 else 365;
    }
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month and m <= 12) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) days += 1;
    }
    days += @as(i64, day) - 1;
    return (((days * 24 + hour) * 60 + minute) * 60) + second;
}

pub fn updateClock() bool {
    var tries: u32 = 0;
    while (tries < 1000 and (cmosRead(0x0a) & 0x80) != 0) : (tries += 1) {}
    if (tries == 1000) return false;

    const second_raw = cmosRead(0x00);
    if (s.clock_valid and second_raw == s.clock_second) return false;
    const minute_raw = cmosRead(0x02);
    const hour_raw = cmosRead(0x04);
    const day_raw = cmosRead(0x07);
    const month_raw = cmosRead(0x08);
    const year_raw = cmosRead(0x09);
    const mode = cmosRead(0x0b);
    if (cmosRead(0x00) != second_raw) return false;

    const binary = (mode & 0x04) != 0;
    const is_24_hour = (mode & 0x02) != 0;
    const is_pm = (hour_raw & 0x80) != 0;
    const minute = if (binary) minute_raw else fromBcd(minute_raw);
    var hour = if (binary) hour_raw & 0x7f else fromBcd(hour_raw & 0x7f);
    const day = if (binary) day_raw else fromBcd(day_raw);
    const month = if (binary) month_raw else fromBcd(month_raw);
    const year = if (binary) year_raw else fromBcd(year_raw);
    if (!is_24_hour) {
        if (hour == 12) hour = 0;
        if (is_pm) hour += 12;
    }

    var display_hour = hour % 12;
    if (display_hour == 0) display_hour = 12;
    if (display_hour >= 10) {
        s.clock_time[0] = '0' + display_hour / 10;
        s.clock_time[1] = '0' + display_hour % 10;
        s.clock_time[2] = ':';
        writeTwoDigits(&s.clock_time, 3, minute);
        s.clock_time[5] = ' ';
        s.clock_time[6] = if (hour >= 12) 'P' else 'A';
        s.clock_time[7] = 'M';
        s.clock_time_len = 8;
    } else {
        s.clock_time[0] = '0' + display_hour;
        s.clock_time[1] = ':';
        writeTwoDigits(&s.clock_time, 2, minute);
        s.clock_time[4] = ' ';
        s.clock_time[5] = if (hour >= 12) 'P' else 'A';
        s.clock_time[6] = 'M';
        s.clock_time_len = 7;
    }
    writeTwoDigits(&s.clock_date, 0, month);
    writeTwoDigits(&s.clock_date, 3, day);
    const full_year: u16 = 2000 + @as(u16, year);
    s.clock_date[6] = '0' + @as(u8, @intCast(full_year / 1000));
    s.clock_date[7] = '0' + @as(u8, @intCast(full_year / 100 % 10));
    s.clock_date[8] = '0' + @as(u8, @intCast(full_year / 10 % 10));
    s.clock_date[9] = '0' + @as(u8, @intCast(full_year % 10));
    s.clock_second = second_raw;
    s.clock_year = full_year;
    s.clock_month = month;
    s.clock_day = day;
    s.clock_hour = hour;
    s.clock_minute = minute;
    s.clock_unix_seconds = unixSeconds(full_year, month, day, hour, minute, if (binary) second_raw else fromBcd(second_raw));
    s.clock_valid = true;
    return true;
}

