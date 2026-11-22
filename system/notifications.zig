//! Small desktop toast queue. Notifications expire after six seconds.
const s = @import("state.zig");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");

var text: [96]u8 = @splat(0);
var text_len: usize = 0;
var expires_at: u64 = 0;

pub fn show(message: []const u8) void {
    text_len = @min(message.len, text.len);
    @memset(&text, 0);
    @memcpy(text[0..text_len], message[0..text_len]);
    expires_at = s.uptime() + 600;
}

pub fn update() bool {
    if (text_len == 0 or s.uptime() < expires_at) return false;
    text_len = 0;
    return true;
}

pub fn draw() void {
    if (text_len == 0 or s.uptime() >= expires_at) return;
    const w: u64 = @min(380, s.fb.width -| 24);
    const x = s.fb.width -| w -| 12;
    const y: u64 = 14;
    const panel = if (s.dark_theme) canvas.color(34, 34, 36) else canvas.color(250, 250, 250);
    const ink = if (s.dark_theme) canvas.color(238, 238, 238) else canvas.color(32, 32, 32);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
    canvas.fillRect(x, y, w, 46, panel);
    canvas.fillRect(x, y, 3, 46, accent);
    font.drawText(x + 14, y + 10, "Notification", 1, accent);
    font.drawText(x + 14, y + 27, text[0..text_len], 1, ink);
}
