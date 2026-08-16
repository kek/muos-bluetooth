// Locates the active muOS theme's font and glyphs. Colours are built in: the
// 640x480 scheme files in muOS 2601.1 carry grid geometry only.
const std = @import("std");

pub const Palette = struct {
    bg: u32 = 0x1A1A1A,
    fg: u32 = 0xEBEBEB,
    accent: u32 = 0xFFC629, // MustardOS yellow
    dim: u32 = 0x7A7A7A,
    bar: u32 = 0x101010,
};

pub fn palette() Palette {
    return .{};
}

pub fn activeNameFrom(gpa: std.mem.Allocator, contents: []const u8) ![]u8 {
    return gpa.dupe(u8, std.mem.trim(u8, contents, " \t\r\n"));
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(64 * 1024));
}

pub fn activeName(gpa: std.mem.Allocator) ![]u8 {
    const raw = readFile(gpa, "/opt/muos/config/theme/active") catch
        return gpa.dupe(u8, "MustardOS");
    defer gpa.free(raw);
    return activeNameFrom(gpa, raw);
}

/// First .ttf under the active theme's font directory, else a known-present
/// system font so the UI always has something to draw with.
pub fn fontPath(gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const fallback = "/opt/muos/share/emulator/ppsspp/Inconsolata-Medium.ttf";
    const dir_path = try std.fmt.allocPrint(gpa, "/run/muos/storage/theme/{s}/font", .{name});
    defer gpa.free(dir_path);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return gpa.dupeZ(u8, fallback);
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return gpa.dupeZ(u8, fallback)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".ttf")) {
            return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir_path, entry.name }, 0);
        }
    }
    return gpa.dupeZ(u8, fallback);
}

test "activeNameFrom trims whitespace and newlines" {
    const gpa = std.testing.allocator;
    const got = try activeNameFrom(gpa, "MustardOS\n");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("MustardOS", got);
}
