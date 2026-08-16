// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("dbus/dbus.h");
    @cInclude("stdio.h");
});

pub const version = "0.1.0";

pub fn main() void {
    var sdl: c.SDL_version = undefined;
    c.SDL_GetVersion(&sdl);
    _ = c.printf("btui %s (SDL %d.%d.%d)\n", version.ptr, sdl.major, sdl.minor, sdl.patch);
}
