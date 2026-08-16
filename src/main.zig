// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("dbus/dbus.h");
    @cInclude("stdio.h");
});
const dbus = @import("dbus.zig");

pub const version = "0.1.0";

pub fn main() void {
    var err = dbus.Error{};
    const conn = dbus.connectSystem(&err) catch {
        _ = c.printf("bus connect failed: %s\n", err.text());
        return;
    };
    _ = conn;
    _ = c.printf("connected to system bus\n");
}
