//! Filesystem selector. ext2 is preferred, with native FAT32 retained for
//! existing IDE images and FAT32 USB media.
const fat32 = @import("fat32.zig");
const ext2 = @import("ext2.zig");
const apfs = @import("apfs.zig");
pub const Entry = fat32.Entry;
pub const Kind = enum { none, apfs, ext2, fat32 };
var active: Kind = .none;
pub fn mountedKind() Kind { return active; }
pub fn isMounted() bool { return active != .none; }
pub fn mount() bool {
    active = .none;
    for (0..3) |device| if (apfs.mountDevice(@intCast(device))) { active = .apfs; return true; };
    if (ext2.mount()) { active = .ext2; return true; }
    if (fat32.mount()) { active = .fat32; return true; }
    return false;
}
pub fn mountDevice(device: u8) bool {
    active = .none;
    if (apfs.mountDevice(device)) { active = .apfs; return true; }
    if (ext2.mountDevice(device)) { active = .ext2; return true; }
    if (fat32.mountDevice(device)) { active = .fat32; return true; }
    return false;
}
pub fn rootCluster() u32 { return if (active == .apfs) apfs.rootCluster() else if (active == .ext2) ext2.rootCluster() else fat32.rootCluster(); }
pub fn listRoot(out: []Entry) usize { return listDirectory(rootCluster(), out); }
pub fn listDirectory(dir: u32, out: []Entry) usize { return if (active == .apfs) apfs.listDirectory(dir, out) else if (active == .ext2) ext2.listDirectory(dir, out) else if (active == .fat32) fat32.listDirectory(dir, out) else 0; }
pub fn readFile(name: []const u8, out: []u8) ?usize { return readFileAt(rootCluster(), name, out); }
pub fn readFileAt(dir: u32, name: []const u8, out: []u8) ?usize { return if (active == .apfs) apfs.readFileAt(dir, name, out) else if (active == .ext2) ext2.readFileAt(dir, name, out) else if (active == .fat32) fat32.readFileAt(dir, name, out) else null; }
pub fn writeFile(name: []const u8, data: []const u8) bool { return writeFileAt(rootCluster(), name, data); }
pub fn writeFileAt(dir: u32, name: []const u8, data: []const u8) bool { return if (active == .apfs) apfs.writeFileAt(dir, name, data) else if (active == .ext2) ext2.writeFileAt(dir, name, data) else if (active == .fat32) fat32.writeFileAt(dir, name, data) else false; }
pub fn deleteFile(name: []const u8) bool { return deleteFileAt(rootCluster(), name); }
pub fn deleteFileAt(dir: u32, name: []const u8) bool { return if (active == .apfs) apfs.deleteFileAt(dir, name) else if (active == .ext2) ext2.deleteFileAt(dir, name) else if (active == .fat32) fat32.deleteFileAt(dir, name) else false; }
pub fn deleteEntryAt(dir: u32, name: []const u8) bool { return if (active == .apfs) apfs.deleteEntryAt(dir, name) else if (active == .ext2) ext2.deleteEntryAt(dir, name) else if (active == .fat32) fat32.deleteEntryAt(dir, name) else false; }
pub fn renameAt(dir: u32, old: []const u8, new: []const u8) bool { return if (active == .apfs) apfs.renameAt(dir, old, new) else if (active == .ext2) ext2.renameAt(dir, old, new) else if (active == .fat32) fat32.renameAt(dir, old, new) else false; }
pub fn changeDirectory(dir: u32, name: []const u8) ?u32 { return if (active == .apfs) apfs.changeDirectory(dir, name) else if (active == .ext2) ext2.changeDirectory(dir, name) else if (active == .fat32) fat32.changeDirectory(dir, name) else null; }
pub fn makeDirectory(dir: u32, name: []const u8) bool { return if (active == .apfs) apfs.makeDirectory(dir, name) else if (active == .ext2) ext2.makeDirectory(dir, name) else if (active == .fat32) fat32.makeDirectory(dir, name) else false; }
