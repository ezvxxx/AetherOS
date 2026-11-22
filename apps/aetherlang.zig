//! AetherLang compiler, standard-library resolver and safe app bytecode runtime.
const std = @import("std");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");
const state = @import("../system/state.zig");
const fat32 = @import("../fs/storage.zig");
const pmm = @import("../memory/pmm.zig");

pub const max_artifact = 2048;
pub var artifact: [max_artifact]u8 = @splat(0);
pub var artifact_len: usize = 0;
pub var status: [96]u8 = @splat(0);
pub var status_len: usize = 0;
pub var preview_enabled = false;
var file_cache: [1024]u8 = @splat(0);
var file_cache_name: [64]u8 = @splat(0);
var file_cache_name_len: usize = 0;
var file_cache_directory: u32 = 0;
var file_cache_attempted = false;
var file_cache_found = false;
var file_cache_len: usize = 0;

const Op = enum(u8) {
    clear = 1,
    rect = 2,
    text = 3,
    line = 4,
    circle = 5,
    outline = 6,
    system_info = 7,
    network_info = 8,
    clock = 9,
    file_list = 10,
    file_text = 11,
};

const Import = struct {
    active: bool = false,
    alias: [24]u8 = @splat(0),
    alias_len: u8 = 0,
    module: [24]u8 = @splat(0),
    module_len: u8 = 0,
};
const Constant = struct {
    active: bool = false,
    namespace: [24]u8 = @splat(0),
    namespace_len: u8 = 0,
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,
    is_string: bool = false,
    number: u32 = 0,
    string: [128]u8 = @splat(0),
    string_len: u8 = 0,
};
const ResolvedCall = struct { canonical: []const u8, method: []const u8 };
const import_capacity = 12;
const constant_capacity = 96;
var imports: [import_capacity]Import = @splat(.{});
var import_count: usize = 0;
var constants: [constant_capacity]Constant = @splat(.{});
var constant_count: usize = 0;
var library_buffer: [2048]u8 = undefined;

fn setStatus(message: []const u8) void {
    status = @splat(0);
    status_len = @min(message.len, status.len);
    @memcpy(status[0..status_len], message[0..status_len]);
}

fn put16(value: u16) void {
    artifact[artifact_len] = @truncate(value);
    artifact[artifact_len + 1] = @truncate(value >> 8);
    artifact_len += 2;
}

fn put32(value: u32) void {
    for (0..4) |i| artifact[artifact_len + i] = @truncate(value >> @as(u5, @intCast(i * 8)));
    artifact_len += 4;
}

fn resetDeclarations() void {
    imports = @splat(.{});
    import_count = 0;
    constants = @splat(.{});
    constant_count = 0;
}

fn validIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 31) return false;
    for (name, 0..) |ch, index| {
        const letter = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
        if (index == 0 and !letter) return false;
        if (index != 0 and !letter and !(ch >= '0' and ch <= '9')) return false;
    }
    return true;
}

fn findImport(alias: []const u8) ?*const Import {
    for (imports[0..import_count]) |*item| {
        if (std.mem.eql(u8, item.alias[0..item.alias_len], alias)) return item;
    }
    return null;
}

fn addImport(alias: []const u8, module: []const u8) bool {
    if (alias.len > 23 or module.len > 23 or !validIdentifier(alias) or !validIdentifier(module) or import_count == imports.len or findImport(alias) != null) return false;
    imports[import_count] = .{ .active = true, .alias_len = @intCast(alias.len), .module_len = @intCast(module.len) };
    @memcpy(imports[import_count].alias[0..alias.len], alias);
    @memcpy(imports[import_count].module[0..module.len], module);
    import_count += 1;
    return true;
}

fn hasConstant(namespace: []const u8, name: []const u8) bool {
    for (constants[0..constant_count]) |*item| {
        if (item.namespace_len == namespace.len and item.name_len == name.len and
            std.mem.eql(u8, item.namespace[0..item.namespace_len], namespace) and
            std.mem.eql(u8, item.name[0..item.name_len], name)) return true;
    }
    return false;
}

fn lookupConstant(name: []const u8) ?*const Constant {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const namespace = if (dot) |index| name[0..index] else "";
    const value_name = if (dot) |index| name[index + 1 ..] else name;
    if (std.mem.indexOfScalar(u8, value_name, '.') != null) return null;
    for (constants[0..constant_count]) |*item| {
        if (item.namespace_len == namespace.len and item.name_len == value_name.len and
            std.mem.eql(u8, item.namespace[0..item.namespace_len], namespace) and
            std.mem.eql(u8, item.name[0..item.name_len], value_name)) return item;
    }
    return null;
}

fn addConstant(namespace: []const u8, name: []const u8, expression: []const u8) bool {
    if (!validIdentifier(name) or namespace.len > 23 or constant_count == constants.len or hasConstant(namespace, name)) return false;
    const value = std.mem.trim(u8, expression, " \t");
    var item = Constant{ .active = true, .namespace_len = @intCast(namespace.len), .name_len = @intCast(name.len) };
    if (namespace.len != 0) @memcpy(item.namespace[0..namespace.len], namespace);
    @memcpy(item.name[0..name.len], name);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const content = value[1 .. value.len - 1];
        if (content.len > item.string.len) return false;
        item.is_string = true;
        item.string_len = @intCast(content.len);
        @memcpy(item.string[0..content.len], content);
    } else {
        item.number = number(value, std.math.maxInt(u32)) orelse return false;
    }
    constants[constant_count] = item;
    constant_count += 1;
    return true;
}

const DeclResult = enum { not_declaration, ok, invalid };

fn collectDeclaration(raw_line: []const u8, namespace: []const u8) DeclResult {
    var line = std.mem.trim(u8, raw_line, " \t\r");
    if (std.mem.startsWith(u8, line, "pub const ")) line = line[4..];
    if (!std.mem.startsWith(u8, line, "const ")) return .not_declaration;
    line = std.mem.trim(u8, line[6..], " \t");
    if (line.len != 0 and line[line.len - 1] == ';') line = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
    const equal = std.mem.indexOfScalar(u8, line, '=') orelse return .invalid;
    const left = std.mem.trim(u8, line[0..equal], " \t");
    const expression = std.mem.trim(u8, line[equal + 1 ..], " \t");
    const colon = std.mem.indexOfScalar(u8, left, ':');
    const name = std.mem.trim(u8, if (colon) |index| left[0..index] else left, " \t");
    if (!validIdentifier(name) or expression.len == 0) return .invalid;

    if (std.mem.startsWith(u8, expression, "@import(")) {
        if (namespace.len != 0 or expression.len < 12 or expression[expression.len - 1] != ')') return .invalid;
        const argument = std.mem.trim(u8, expression[8 .. expression.len - 1], " \t");
        if (argument.len < 3 or argument[0] != '"' or argument[argument.len - 1] != '"') return .invalid;
        const module = argument[1 .. argument.len - 1];
        if (!addImport(name, module)) return .invalid;
        if (isBuiltinModule(module)) return .ok;

        var filename: [40]u8 = undefined;
        const lib_name = std.fmt.bufPrint(&filename, "{s}.alib", .{module}) catch return .invalid;
        const length = fat32.readFileAt(state.fs_current_directory, lib_name, &library_buffer) orelse return .invalid;
        var library_lines = std.mem.splitScalar(u8, library_buffer[0..length], '\n');
        while (library_lines.next()) |library_line| {
            const trimmed = std.mem.trim(u8, library_line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '/' or std.mem.startsWith(u8, trimmed, "app ") or std.mem.startsWith(u8, trimmed, "fn ")) continue;
            if (collectDeclaration(trimmed, name) != .ok) return .invalid;
        }
        return .ok;
    }
    return if (addConstant(namespace, name, expression)) .ok else .invalid;
}

fn isBuiltinModule(module: []const u8) bool {
    return std.mem.eql(u8, module, "std") or std.mem.eql(u8, module, "ui") or std.mem.eql(u8, module, "os") or std.mem.eql(u8, module, "fs") or std.mem.eql(u8, module, "graphics");
}

fn number(token: []const u8, maximum: u32) ?u32 {
    const trimmed = std.mem.trim(u8, token, " \t");
    const value = std.fmt.parseInt(u32, trimmed, 0) catch {
        const item = lookupConstant(trimmed) orelse return null;
        if (item.is_string) return null;
        return if (item.number <= maximum) item.number else null;
    };
    if (value > maximum) return null;
    return value;
}

fn stringValue(token: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, token, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return trimmed[1 .. trimmed.len - 1];
    const item = lookupConstant(trimmed) orelse return null;
    if (!item.is_string) return null;
    return item.string[0..item.string_len];
}

fn emitSystemCall(line: []const u8, name: []const u8, op: Op, output: *[5][]const u8) bool {
    const count = arguments(line, name, output) orelse return false;
    if (count != 3) return false;
    const x = number(output[0], 4096) orelse return false;
    const y = number(output[1], 4096) orelse return false;
    const color = number(output[2], 0xffffff) orelse return false;
    if (artifact_len + 9 > artifact.len) return false;
    artifact[artifact_len] = @intFromEnum(op);
    artifact_len += 1;
    put16(@intCast(x));
    put16(@intCast(y));
    put32(color);
    return true;
}

fn arguments(line: []const u8, name: []const u8, output: *[5][]const u8) ?usize {
    const start = std.mem.indexOf(u8, line, name) orelse return null;
    var i = start + name.len;
    while (i < line.len and line[i] != '(') : (i += 1) {}
    if (i == line.len) return null;
    i += 1;
    var count: usize = 0;
    var token_start = i;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' and (i == 0 or line[i - 1] != '\\')) in_string = !in_string;
        if (!in_string and (ch == ',' or ch == ')')) {
            if (count >= output.len) return null;
            output[count] = std.mem.trim(u8, line[token_start..i], " \t");
            count += 1;
            if (ch == ')') return count;
            token_start = i + 1;
        }
    }
    return null;
}

fn mapApi(module: []const u8, method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, module, "ui")) {
        if (std.mem.eql(u8, method, "panel")) return "rect";
        if (std.mem.eql(u8, method, "label")) return "text";
        if (std.mem.eql(u8, method, "border")) return "outline";
        if (std.mem.eql(u8, method, "divider")) return "line";
        if (std.mem.eql(u8, method, "circle")) return "circle";
    } else if (std.mem.eql(u8, module, "os")) {
        if (std.mem.eql(u8, method, "info") or std.mem.eql(u8, method, "systemInfo")) return "sys_info";
        if (std.mem.eql(u8, method, "network") or std.mem.eql(u8, method, "networkInfo")) return "network_info";
        if (std.mem.eql(u8, method, "clock")) return "clock";
    } else if (std.mem.eql(u8, module, "fs")) {
        if (std.mem.eql(u8, method, "list") or std.mem.eql(u8, method, "listDirectory")) return "file_list";
        if (std.mem.eql(u8, method, "readText")) return "file_text";
    } else if (std.mem.eql(u8, module, "graphics")) {
        if (std.mem.eql(u8, method, "clear")) return "clear";
        if (std.mem.eql(u8, method, "rect")) return "rect";
        if (std.mem.eql(u8, method, "outline")) return "outline";
        if (std.mem.eql(u8, method, "line")) return "line";
        if (std.mem.eql(u8, method, "circle")) return "circle";
        if (std.mem.eql(u8, method, "text")) return "text";
    } else if (std.mem.eql(u8, module, "std")) {
        if (std.mem.eql(u8, method, "info")) return "sys_info";
        if (std.mem.eql(u8, method, "network")) return "network_info";
        if (std.mem.eql(u8, method, "clock")) return "clock";
        if (std.mem.eql(u8, method, "fileList")) return "file_list";
        if (std.mem.eql(u8, method, "readText")) return "file_text";
    }
    return null;
}

fn resolveCall(line: []const u8) ?ResolvedCall {
    const paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const path = std.mem.trim(u8, line[0..paren], " \t");
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var path_parts = std.mem.splitScalar(u8, path, '.');
    while (path_parts.next()) |part| {
        if (part_count == parts.len) return null;
        parts[part_count] = part;
        part_count += 1;
    }
    if (part_count == 1) return .{ .canonical = parts[0], .method = parts[0] };
    if (part_count < 2) return null;
    const imported = findImport(parts[0]) orelse return null;
    const module = imported.module[0..imported.module_len];
    const method = parts[part_count - 1];
    if (part_count == 2) return .{ .canonical = mapApi(module, method) orelse return null, .method = method };
    if (part_count == 3 and std.mem.eql(u8, module, "std"))
        return .{ .canonical = mapApi(parts[1], method) orelse return null, .method = method };
    return null;
}

fn emitLine(raw_line: []const u8) bool {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0 or line[0] == '/' or line[0] == '}' or line[0] == '{' or std.mem.startsWith(u8, line, "app ") or std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "pub const ")) return true;
    const call = resolveCall(line) orelse return false;
    const operation = call.canonical;
    const method = call.method;
    var args: [5][]const u8 = undefined;
    if (std.mem.eql(u8, operation, "clear")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 1) return false;
        const color = number(args[0], 0xffffff) orelse return false;
        if (artifact_len + 5 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.clear);
        artifact_len += 1;
        put32(color);
        return true;
    }
    if (std.mem.eql(u8, operation, "rect")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 5) return false;
        var values: [4]u16 = undefined;
        for (0..4) |i| values[i] = @intCast(number(args[i], 4096) orelse return false);
        const color = number(args[4], 0xffffff) orelse return false;
        if (artifact_len + 13 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.rect);
        artifact_len += 1;
        for (values) |value| put16(value);
        put32(color);
        return true;
    }
    if (std.mem.eql(u8, operation, "outline")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 5) return false;
        var values: [4]u16 = undefined;
        for (0..4) |i| values[i] = @intCast(number(args[i], 4096) orelse return false);
        const color = number(args[4], 0xffffff) orelse return false;
        if (artifact_len + 13 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.outline);
        artifact_len += 1;
        for (values) |value| put16(value);
        put32(color);
        return true;
    }
    if (std.mem.eql(u8, operation, "line")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 5) return false;
        var values: [4]u16 = undefined;
        for (0..4) |i| values[i] = @intCast(number(args[i], 4096) orelse return false);
        const color = number(args[4], 0xffffff) orelse return false;
        if (artifact_len + 13 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.line);
        artifact_len += 1;
        for (values) |value| put16(value);
        put32(color);
        return true;
    }
    if (std.mem.eql(u8, operation, "circle")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 4) return false;
        const cx = number(args[0], 4096) orelse return false;
        const cy = number(args[1], 4096) orelse return false;
        const radius = number(args[2], 512) orelse return false;
        const color = number(args[3], 0xffffff) orelse return false;
        if (artifact_len + 11 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.circle);
        artifact_len += 1;
        put16(@intCast(cx));
        put16(@intCast(cy));
        put16(@intCast(radius));
        put32(color);
        return true;
    }
    if (std.mem.eql(u8, operation, "sys_info")) return emitSystemCall(line, method, .system_info, &args);
    if (std.mem.eql(u8, operation, "network_info")) return emitSystemCall(line, method, .network_info, &args);
    if (std.mem.eql(u8, operation, "clock")) return emitSystemCall(line, method, .clock, &args);
    if (std.mem.eql(u8, operation, "file_list")) return emitSystemCall(line, method, .file_list, &args);
    if (std.mem.eql(u8, operation, "file_text")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 4) return false;
        const x = number(args[0], 4096) orelse return false;
        const y = number(args[1], 4096) orelse return false;
        const color = number(args[2], 0xffffff) orelse return false;
        const name = stringValue(args[3]) orelse return false;
        if (name.len == 0 or name.len > 63 or artifact_len + name.len + 10 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.file_text);
        artifact_len += 1;
        put16(@intCast(x));
        put16(@intCast(y));
        put32(color);
        artifact[artifact_len] = @intCast(name.len);
        artifact_len += 1;
        @memcpy(artifact[artifact_len..][0..name.len], name);
        artifact_len += name.len;
        return true;
    }
    if (std.mem.eql(u8, operation, "text")) {
        const count = arguments(line, method, &args) orelse return false;
        if (count != 4) return false;
        const x = number(args[0], 4096) orelse return false;
        const y = number(args[1], 4096) orelse return false;
        const color = number(args[2], 0xffffff) orelse return false;
        const content = stringValue(args[3]) orelse return false;
        if (content.len > 120 or artifact_len + content.len + 10 > artifact.len) return false;
        artifact[artifact_len] = @intFromEnum(Op.text);
        artifact_len += 1;
        put16(@intCast(x));
        put16(@intCast(y));
        put32(color);
        artifact[artifact_len] = @intCast(content.len);
        artifact_len += 1;
        @memcpy(artifact[artifact_len..][0..content.len], content);
        artifact_len += content.len;
        return true;
    }
    return false;
}

/// Compile AetherLang source to a compact, versioned .ath bytecode app.
pub fn compile(source: []const u8) bool {
    resetFileCache();
    resetDeclarations();
    artifact = @splat(0);
    artifact_len = 5;
    artifact[0] = 'A';
    artifact[1] = 'T';
    artifact[2] = 'H';
    artifact[3] = 1;
    artifact[4] = 0; // instruction count, limited to 255

    var declarations = std.mem.splitScalar(u8, source, '\n');
    while (declarations.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (collectDeclaration(trimmed, "") == .invalid) {
            setStatus("Compile error: invalid const or import");
            artifact_len = 0;
            return false;
        }
    }

    var instructions: u16 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ")) continue;
        if (trimmed.len == 0 or trimmed[trimmed.len - 1] == '{' or trimmed[trimmed.len - 1] == ';' or trimmed[0] == '}') {
            if (trimmed.len == 0 or trimmed[0] == '}' or std.mem.startsWith(u8, trimmed, "app ") or std.mem.startsWith(u8, trimmed, "fn ")) continue;
            if (!emitLine(trimmed)) {
                setStatus("Compile error: check SDK call arguments");
                artifact_len = 0;
                return false;
            }
        } else if (!emitLine(trimmed)) {
            setStatus("Compile error: unknown AetherLang statement");
            artifact_len = 0;
            return false;
        }
        if (trimmed.len != 0 and trimmed[0] != '/' and trimmed[0] != '}' and trimmed[0] != '{' and !std.mem.startsWith(u8, trimmed, "app ") and !std.mem.startsWith(u8, trimmed, "fn ")) instructions += 1;
    }
    if (instructions == 0 or instructions > 255) {
        setStatus("Compile error: app needs 1 to 255 SDK calls");
        artifact_len = 0;
        return false;
    }
    artifact[4] = @intCast(instructions);
    preview_enabled = false;
    setStatus("Build successful: .ath app is ready");
    return true;
}

/// Activate an .ath file from storage. Runtime drawing is memory-safe and bounded.
pub fn activateArtifact(length: usize) bool {
    if (length < 5 or length > artifact.len or !std.mem.eql(u8, artifact[0..3], "ATH") or artifact[3] != 1 or artifact[4] == 0) {
        preview_enabled = false;
        setStatus("Invalid or unsupported .ath application");
        return false;
    }
    resetFileCache();
    artifact_len = length;
    preview_enabled = true;
    setStatus("");
    return true;
}

fn resetFileCache() void {
    file_cache = @splat(0);
    file_cache_name = @splat(0);
    file_cache_name_len = 0;
    file_cache_directory = 0;
    file_cache_attempted = false;
    file_cache_found = false;
    file_cache_len = 0;
}

fn get16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn get32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) | (@as(u32, data[offset + 1]) << 8) | (@as(u32, data[offset + 2]) << 16) | (@as(u32, data[offset + 3]) << 24);
}

/// Run the validated drawing bytecode into a bounded preview rectangle.
pub fn drawPreview(x: u64, y: u64, width: u64, height: u64) void {
    if (!preview_enabled or artifact_len < 5 or !std.mem.eql(u8, artifact[0..3], "ATH") or artifact[3] != 1) return;
    canvas.fillRect(x, y, width, height, canvas.color(255, 255, 255));
    var pos: usize = 5;
    var remaining: usize = artifact[4];
    while (remaining != 0 and pos < artifact_len) : (remaining -= 1) {
        const op = artifact[pos];
        pos += 1;
        switch (op) {
            @intFromEnum(Op.clear) => {
                if (pos + 4 > artifact_len) return;
                canvas.fillRect(x, y, width, height, toColor(get32(&artifact, pos)));
                pos += 4;
            },
            @intFromEnum(Op.rect) => {
                if (pos + 12 > artifact_len) return;
                const rx = get16(&artifact, pos);
                const ry = get16(&artifact, pos + 2);
                const rw = get16(&artifact, pos + 4);
                const rh = get16(&artifact, pos + 6);
                const color = toColor(get32(&artifact, pos + 8));
                if (rx < width and ry < height) canvas.fillRect(x + rx, y + ry, @min(@as(u64, rw), width - rx), @min(@as(u64, rh), height - ry), color);
                pos += 12;
            },
            @intFromEnum(Op.outline) => {
                if (pos + 12 > artifact_len) return;
                const rx = get16(&artifact, pos);
                const ry = get16(&artifact, pos + 2);
                const rw = get16(&artifact, pos + 4);
                const rh = get16(&artifact, pos + 6);
                const color = toColor(get32(&artifact, pos + 8));
                drawOutline(x, y, width, height, rx, ry, rw, rh, color);
                pos += 12;
            },
            @intFromEnum(Op.line) => {
                if (pos + 12 > artifact_len) return;
                const x0 = get16(&artifact, pos);
                const y0 = get16(&artifact, pos + 2);
                const x1 = get16(&artifact, pos + 4);
                const y1 = get16(&artifact, pos + 6);
                const color = toColor(get32(&artifact, pos + 8));
                drawLine(x, y, width, height, x0, y0, x1, y1, color);
                pos += 12;
            },
            @intFromEnum(Op.circle) => {
                if (pos + 10 > artifact_len) return;
                const cx = get16(&artifact, pos);
                const cy = get16(&artifact, pos + 2);
                const radius = get16(&artifact, pos + 4);
                const color = toColor(get32(&artifact, pos + 6));
                drawCircle(x, y, width, height, cx, cy, radius, color);
                pos += 10;
            },
            @intFromEnum(Op.system_info), @intFromEnum(Op.network_info), @intFromEnum(Op.clock), @intFromEnum(Op.file_list) => {
                if (pos + 8 > artifact_len) return;
                const tx = get16(&artifact, pos);
                const ty = get16(&artifact, pos + 2);
                const color = toColor(get32(&artifact, pos + 4));
                switch (op) {
                    @intFromEnum(Op.system_info) => drawSystemInfo(x, y, width, height, tx, ty, color),
                    @intFromEnum(Op.network_info) => drawNetworkInfo(x, y, width, height, tx, ty, color),
                    @intFromEnum(Op.clock) => drawClock(x, y, width, height, tx, ty, color),
                    @intFromEnum(Op.file_list) => drawFileList(x, y, width, height, tx, ty, color),
                    else => {},
                }
                pos += 8;
            },
            @intFromEnum(Op.file_text) => {
                if (pos + 9 > artifact_len) return;
                const tx = get16(&artifact, pos);
                const ty = get16(&artifact, pos + 2);
                const color = toColor(get32(&artifact, pos + 4));
                const name_len: usize = artifact[pos + 8];
                pos += 9;
                if (name_len == 0 or name_len > 63 or pos + name_len > artifact_len) return;
                drawFileText(x, y, width, height, tx, ty, color, artifact[pos .. pos + name_len]);
                pos += name_len;
            },
            @intFromEnum(Op.text) => {
                if (pos + 9 > artifact_len) return;
                const tx = get16(&artifact, pos);
                const ty = get16(&artifact, pos + 2);
                const color = toColor(get32(&artifact, pos + 4));
                const length: usize = artifact[pos + 8];
                pos += 9;
                if (pos + length > artifact_len) return;
                if (tx < width and ty < height) font.drawText(x + tx, y + ty, artifact[pos .. pos + length], 1, color);
                pos += length;
            },
            else => return,
        }
    }
}

fn drawOutline(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, rx: u16, ry: u16, rw: u16, rh: u16, color: u32) void {
    const left: u64 = rx;
    const top: u64 = ry;
    const width: u64 = rw;
    const height: u64 = rh;
    if (width == 0 or height == 0 or left >= clip_w or top >= clip_h) return;
    canvas.fillRect(origin_x + left, origin_y + top, @min(width, clip_w - left), 1, color);
    if (height > 1 and top + height - 1 < clip_h) canvas.fillRect(origin_x + left, origin_y + top + height - 1, @min(width, clip_w - left), 1, color);
    if (height > 2) {
        const inner_h = @min(height - 2, clip_h -| top -| 1);
        canvas.fillRect(origin_x + left, origin_y + top + 1, 1, inner_h, color);
        if (width > 1 and left + width - 1 < clip_w) canvas.fillRect(origin_x + left + width - 1, origin_y + top + 1, 1, inner_h, color);
    }
}

fn drawLine(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, start_x: u16, start_y: u16, end_x: u16, end_y: u16, color: u32) void {
    var x0: i64 = start_x;
    var y0: i64 = start_y;
    const x1: i64 = end_x;
    const y1: i64 = end_y;
    const dx = @as(i64, @intCast(@abs(x1 - x0)));
    const sx: i64 = if (x0 < x1) 1 else -1;
    const dy = -@as(i64, @intCast(@abs(y1 - y0)));
    const sy: i64 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        if (x0 >= 0 and y0 >= 0 and @as(u64, @intCast(x0)) < clip_w and @as(u64, @intCast(y0)) < clip_h)
            canvas.putPixel(origin_x + @as(u64, @intCast(x0)), origin_y + @as(u64, @intCast(y0)), color);
        if (x0 == x1 and y0 == y1) break;
        const twice = err * 2;
        if (twice >= dy) {
            err += dy;
            x0 += sx;
        }
        if (twice <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawCircle(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, center_x: u16, center_y: u16, radius: u16, color: u32) void {
    var px: i32 = radius;
    var py: i32 = 0;
    var err: i32 = 1 - px;
    const cx: i32 = center_x;
    const cy: i32 = center_y;
    while (px >= py) {
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx + px, cy + py, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx + py, cy + px, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx - py, cy + px, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx - px, cy + py, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx - px, cy - py, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx - py, cy - px, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx + py, cy - px, color);
        plotCirclePoint(origin_x, origin_y, clip_w, clip_h, cx + px, cy - py, color);
        py += 1;
        if (err < 0) {
            err += 2 * py + 1;
        } else {
            px -= 1;
            err += 2 * (py - px) + 1;
        }
    }
}

fn plotCirclePoint(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, px: i32, py: i32, color: u32) void {
    if (px < 0 or py < 0 or @as(u64, @intCast(px)) >= clip_w or @as(u64, @intCast(py)) >= clip_h) return;
    canvas.putPixel(origin_x + @as(u64, @intCast(px)), origin_y + @as(u64, @intCast(py)), color);
}

fn drawApiText(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32, content: []const u8) void {
    const x: u64 = tx;
    const y: u64 = ty;
    if (x >= clip_w or y >= clip_h) return;
    const columns: usize = @intCast((clip_w - x) / 6);
    const visible = @min(content.len, columns);
    if (visible == 0) return;
    font.drawText(origin_x + x, origin_y + y, content[0..visible], 1, color);
}

fn drawSystemInfo(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32) void {
    var line: [80]u8 = undefined;
    var row: u64 = ty;
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(@min(row, 0xffff)), color, "AetherOS x86-64");
    row += 16;
    const ram = std.fmt.bufPrint(&line, "RAM: {d} MiB total", .{pmm.totalMemoryBytes() / (1024 * 1024)}) catch return;
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(@min(row, 0xffff)), color, ram);
    row += 16;
    const display = std.fmt.bufPrint(&line, "Display: {d} x {d}", .{ state.fb.width, state.fb.height }) catch return;
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(@min(row, 0xffff)), color, display);
    row += 16;
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(@min(row, 0xffff)), color, if (state.boot_is_uefi) "Firmware: UEFI" else "Firmware: BIOS");
    row += 16;
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(@min(row, 0xffff)), color, if (state.fs_mounted) "Storage: filesystem ready" else "Storage: no disk");
}

fn drawNetworkInfo(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32) void {
    var line: [80]u8 = undefined;
    const message = if (!state.ethernet_present)
        "Ethernet: not detected"
    else if (!state.ethernet_link_up)
        "Ethernet: disconnected"
    else if (!state.network_configured)
        "Network: waiting for DHCP"
    else
        std.fmt.bufPrint(&line, "IPv4: {d}.{d}.{d}.{d}", .{ state.ipv4_address[0], state.ipv4_address[1], state.ipv4_address[2], state.ipv4_address[3] }) catch "IPv4: unavailable";
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, message);
}

fn drawClock(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32) void {
    if (!state.clock_valid) {
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, "Clock: unavailable");
        return;
    }
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, state.clock_time[0..state.clock_time_len]);
    drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty +| 14, color, &state.clock_date);
}

fn drawFileList(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32) void {
    if (!state.fs_mounted or !fat32.isMounted()) {
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, "Storage is unavailable");
        return;
    }
    var entries: [32]fat32.Entry = undefined;
    const count = fat32.listDirectory(state.fs_current_directory, &entries);
    if (count == 0) {
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, "Folder is empty");
        return;
    }
    for (entries[0..count], 0..) |entry, index| {
        const row = @as(u64, ty) + @as(u64, @intCast(index)) * 14;
        if (row >= clip_h or row > 0xffff) break;
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(row), color, entry.name[0..entry.name_len]);
        if (entry.attributes & 0x10 != 0) {
            const suffix_x: u16 = @intCast(@min(@as(u64, 0xffff), @as(u64, tx) + @as(u64, entry.name_len) * 6));
            drawApiText(origin_x, origin_y, clip_w, clip_h, suffix_x, @intCast(row), color, "/");
        }
    }
}

fn cachedFile(name: []const u8) bool {
    if (file_cache_attempted and file_cache_directory == state.fs_current_directory and file_cache_name_len == name.len and std.mem.eql(u8, file_cache_name[0..file_cache_name_len], name)) return file_cache_found;
    file_cache_attempted = true;
    file_cache_found = false;
    file_cache_len = 0;
    file_cache_directory = state.fs_current_directory;
    file_cache_name = @splat(0);
    file_cache_name_len = name.len;
    @memcpy(file_cache_name[0..name.len], name);
    if (!state.fs_mounted or !fat32.isMounted()) return false;
    if (fat32.readFileAt(state.fs_current_directory, name, &file_cache)) |length| {
        file_cache_len = length;
        file_cache_found = true;
    }
    return file_cache_found;
}

fn drawFileText(origin_x: u64, origin_y: u64, clip_w: u64, clip_h: u64, tx: u16, ty: u16, color: u32, name: []const u8) void {
    if (!cachedFile(name)) {
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, "File not found in current folder");
        return;
    }
    if (file_cache_len == 0) {
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, ty, color, "(empty file)");
        return;
    }
    var offset: usize = 0;
    var row: u64 = ty;
    while (offset < file_cache_len and row < clip_h and row <= 0xffff) {
        var end = offset;
        while (end < file_cache_len and file_cache[end] != '\n') : (end += 1) {}
        var content = file_cache[offset..end];
        if (content.len != 0 and content[content.len - 1] == '\r') content = content[0 .. content.len - 1];
        drawApiText(origin_x, origin_y, clip_w, clip_h, tx, @intCast(row), color, content);
        row += 14;
        offset = if (end < file_cache_len) end + 1 else end;
    }
}

fn toColor(value: u32) u32 {
    return canvas.color(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
}
