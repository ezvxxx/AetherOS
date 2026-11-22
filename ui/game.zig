//! Tiny keyboard-controlled dodge game used as an input/animation demo.
const s = @import("../system/state.zig");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");

var player_x: i32 = 500;
var hazard_x: i32 = 250;
var hazard_y: i32 = 0;
var score: u32 = 0;
var game_over = false;
var last_tick: u64 = 0;

pub fn reset() void {
    player_x = 500;
    hazard_x = 250;
    hazard_y = 0;
    score = 0;
    game_over = false;
    last_tick = s.uptime();
}

pub fn key(code: u8, extended: bool) void {
    if (game_over and !extended and code == 0x39) {
        reset();
        return;
    }
    if (!extended) return;
    if (code == 0x4b) player_x = @max(60, player_x - 55);
    if (code == 0x4d) player_x = @min(940, player_x + 55);
}

pub fn update() bool {
    if (s.uptime() - last_tick < 3) return false;
    last_tick = s.uptime();
    if (game_over) return false;
    hazard_y += 18;
    if (hazard_y >= 920) {
        hazard_y = 0;
        hazard_x = @intCast((score *% 173 +% 97) % 900 + 50);
        score +%= 1;
    }
    if (hazard_y > 790 and hazard_y < 940 and @abs(player_x - hazard_x) < 115) game_over = true;
    return true;
}

pub fn draw(win: s.Window) void {
    const x0 = win.x + 8;
    const y0 = win.y + 38;
    const width = win.w -| 16;
    const height = win.h -| 48;
    const bg = canvas.color(9, 15, 26);
    canvas.fillRect(x0, y0, width, height, bg);
    font.drawText(x0 + 12, y0 + 10, "Move with left/right arrows. Dodge the falling block.", 1, canvas.color(190, 205, 224));
    font.drawText(x0 + 12, y0 + 28, "Score", 1, canvas.color(103, 211, 255));
    font.drawNumber(x0 + 54, y0 + 28, score, canvas.color(255, 255, 255));
    if (height < 100 or width < 120) return;
    const field_y = y0 + 50;
    const field_h = height -| 62;
    const player_px = x0 + 12 +| (@as(u64, @intCast(player_x)) * (width -| 48)) / 1000;
    const hazard_px = x0 + 12 +| (@as(u64, @intCast(hazard_x)) * (width -| 48)) / 1000;
    const player_y = field_y + field_h -| 20;
    const hazard_py = field_y + (@as(u64, @intCast(hazard_y)) * field_h) / 1000;
    canvas.fillRect(x0 + 8, field_y, width -| 16, field_h, canvas.color(16, 25, 40));
    canvas.fillRect(player_px, player_y, 28, 12, canvas.color(103, 211, 255));
    canvas.fillRect(hazard_px, hazard_py, 30, 16, canvas.color(255, 105, 120));
    if (game_over) {
        canvas.fillRect(x0 + width / 2 -| 90, y0 + height / 2 -| 28, 180, 56, canvas.color(30, 18, 28));
        font.drawText(x0 + width / 2 -| 42, y0 + height / 2 -| 16, "Game over", 1, canvas.color(255, 140, 150));
        font.drawText(x0 + width / 2 -| 72, y0 + height / 2 + 2, "Space to play again", 1, canvas.color(232, 240, 250));
    }
}
