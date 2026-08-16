// SDL2 window, themed text, list rows, and gamepad/keyboard input polling.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
const theme = @import("theme.zig");

pub const screen_w: c_int = 640;
pub const screen_h: c_int = 480;

// listRow geometry (Ruling 3: specified in prose, not code, by the task-7
// brief - row height 28, list origin y=64, label at x=24, right-aligned
// status at x=616).
pub const list_origin_y: c_int = 64;
pub const row_height: c_int = 28;
pub const label_x: c_int = 24;
pub const status_right_x: c_int = 616;

pub const Ui = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    controller: ?*c.SDL_GameController,
    joystick: ?*c.SDL_Joystick,
};

pub const Button = enum { up, down, a, b, x, y, l1, r1, quit };

/// muOS ships an SDL controller mapping for muOS-Keys here (a symlink to
/// /opt/muos/share/info/gamecontrollerdb/retro.txt); muOS's own launch
/// scripts export SDL_GAMECONTROLLERCONFIG_FILE pointing at it too, but we
/// load it explicitly so btui doesn't depend on that env var being set.
const gamecontrollerdb_path = "/usr/lib/gamecontrollerdb.txt";

/// Opens index 0 as an SDL_GameController when a mapping is available
/// (muOS-Keys, via gamecontrollerdb_path), else falls back to the raw
/// SDL_Joystick API. Named button constants beat the raw indices below,
/// which the task-7 plan guessed wrong across the board - see poll()'s
/// fallback switch and task-7-report.md for the real ones.
fn openPad() struct { controller: ?*c.SDL_GameController, joystick: ?*c.SDL_Joystick } {
    _ = c.SDL_GameControllerAddMappingsFromFile(gamecontrollerdb_path);
    if (c.SDL_NumJoysticks() < 1) return .{ .controller = null, .joystick = null };
    if (c.SDL_IsGameController(0) != 0) {
        if (c.SDL_GameControllerOpen(0)) |ctl| return .{ .controller = ctl, .joystick = null };
    }
    return .{ .controller = null, .joystick = c.SDL_JoystickOpen(0) };
}

/// Step 1 gate: proves a bare window + accelerated renderer can be created
/// under the device's only video driver (`mali`) before anything else in
/// this file is built on top of it. Deliberately independent of `init` -
/// no font, no joystick - so a failure here isolates to SDL itself.
pub fn windowTest() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const win = c.SDL_CreateWindow("btui", 0, 0, screen_w, screen_h, c.SDL_WINDOW_SHOWN) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
    defer c.SDL_DestroyWindow(win);

    const ren = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRenderer;
    };
    defer c.SDL_DestroyRenderer(ren);

    _ = c.SDL_SetRenderDrawColor(ren, 0xFF, 0xC6, 0x29, 0xFF);
    _ = c.SDL_RenderClear(ren);
    c.SDL_RenderPresent(ren);
    c.SDL_Delay(2000);
}

pub fn init(font_path: [:0]const u8) !Ui {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    errdefer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.debug.print("TTF_Init failed: {s}\n", .{c.TTF_GetError()});
        return error.TtfInit;
    }
    errdefer _ = c.TTF_Quit();

    const win = c.SDL_CreateWindow("btui", 0, 0, screen_w, screen_h, c.SDL_WINDOW_SHOWN) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
    errdefer c.SDL_DestroyWindow(win);

    const ren = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRenderer;
    };
    errdefer c.SDL_DestroyRenderer(ren);

    const font = c.TTF_OpenFont(font_path.ptr, 18) orelse {
        std.debug.print("TTF_OpenFont failed: {s}\n", .{c.TTF_GetError()});
        return error.FontOpen;
    };
    errdefer c.TTF_CloseFont(font);

    // muOS-Keys is the only pad; index 0 is always it. A missing pad (e.g.
    // testing over SSH with no gamepad attached) is not fatal - poll() just
    // never sees controller/joystick events.
    const pad = openPad();

    return .{ .window = win, .renderer = ren, .font = font, .controller = pad.controller, .joystick = pad.joystick };
}

pub fn deinit(self: Ui) void {
    if (self.controller) |ctl| c.SDL_GameControllerClose(ctl);
    if (self.joystick) |j| c.SDL_JoystickClose(j);
    c.TTF_CloseFont(self.font);
    c.SDL_DestroyRenderer(self.renderer);
    c.SDL_DestroyWindow(self.window);
    _ = c.TTF_Quit();
    c.SDL_Quit();
}

fn setColor(ren: *c.SDL_Renderer, colour: u32) void {
    _ = c.SDL_SetRenderDrawColor(
        ren,
        @intCast((colour >> 16) & 0xFF),
        @intCast((colour >> 8) & 0xFF),
        @intCast(colour & 0xFF),
        0xFF,
    );
}

pub fn beginFrame(self: Ui, pal: theme.Palette) void {
    setColor(self.renderer, pal.bg);
    _ = c.SDL_RenderClear(self.renderer);
}

pub fn endFrame(self: Ui) void {
    c.SDL_RenderPresent(self.renderer);
}

const Glyphs = struct { tex: *c.SDL_Texture, w: c_int, h: c_int };

/// Renders `s` to a texture. Caller owns and must destroy the returned
/// texture; the intermediate surface is freed here regardless of outcome.
fn render(self: Ui, s: [:0]const u8, colour: u32) ?Glyphs {
    const col = c.SDL_Color{
        .r = @intCast((colour >> 16) & 0xFF),
        .g = @intCast((colour >> 8) & 0xFF),
        .b = @intCast(colour & 0xFF),
        .a = 0xFF,
    };
    const surf = c.TTF_RenderUTF8_Blended(self.font, s.ptr, col) orelse return null;
    defer c.SDL_FreeSurface(surf);
    const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse return null;
    return .{ .tex = tex, .w = surf.*.w, .h = surf.*.h };
}

pub fn text(self: Ui, x: c_int, y: c_int, s: [:0]const u8, colour: u32) void {
    const g = render(self, s, colour) orelse return;
    defer c.SDL_DestroyTexture(g.tex);
    var dst = c.SDL_Rect{ .x = x, .y = y, .w = g.w, .h = g.h };
    _ = c.SDL_RenderCopy(self.renderer, g.tex, null, &dst);
}

/// Draws `s` so its right edge lands at `right_x`.
fn textRight(self: Ui, right_x: c_int, y: c_int, s: [:0]const u8, colour: u32) void {
    const g = render(self, s, colour) orelse return;
    defer c.SDL_DestroyTexture(g.tex);
    var dst = c.SDL_Rect{ .x = right_x - g.w, .y = y, .w = g.w, .h = g.h };
    _ = c.SDL_RenderCopy(self.renderer, g.tex, null, &dst);
}

/// One row of a themed list: a full-width selection band in `pal.accent`
/// when `selected`, a left-aligned label, and a right-aligned status.
pub fn listRow(self: Ui, index: usize, selected: bool, left: [:0]const u8, right: [:0]const u8, pal: theme.Palette) void {
    const y = list_origin_y + @as(c_int, @intCast(index)) * row_height;

    if (selected) {
        setColor(self.renderer, pal.accent);
        var band = c.SDL_Rect{ .x = 0, .y = y, .w = screen_w, .h = row_height };
        _ = c.SDL_RenderFillRect(self.renderer, &band);
    }

    const label_colour = if (selected) pal.bg else pal.fg;
    const status_colour = if (selected) pal.bg else pal.dim;
    // Centre on the font's line metrics rather than each string's rendered
    // surface height, so the label and status baselines match even when one
    // string has descenders and the other doesn't.
    const text_y = y + @divTrunc(row_height - c.TTF_FontHeight(self.font), 2);

    text(self, label_x, text_y, left, label_colour);
    textRight(self, status_right_x, text_y, right, status_colour);
}

/// Returns the first recognised input event, or null once the queue is
/// drained. Call in a loop to pump every pending event in a frame.
///
/// The same physical button press generates both a `SDL_CONTROLLERBUTTONDOWN`
/// and a raw `SDL_JOYBUTTONDOWN`/`SDL_JOYHATMOTION` event when a
/// SDL_GameController is open - SDL never suppresses the joystick-level
/// events underneath a mapped controller. So the raw cases below are only
/// live when `self.controller == null` (no mapping was found), or the two
/// paths would double-fire on every press.
pub fn poll(self: Ui) ?Button {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev) != 0) {
        switch (ev.type) {
            c.SDL_QUIT => return .quit,
            c.SDL_CONTROLLERBUTTONDOWN => return switch (ev.cbutton.button) {
                c.SDL_CONTROLLER_BUTTON_A => .a,
                c.SDL_CONTROLLER_BUTTON_B => .b,
                c.SDL_CONTROLLER_BUTTON_X => .x,
                c.SDL_CONTROLLER_BUTTON_Y => .y,
                c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER => .l1,
                c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => .r1,
                c.SDL_CONTROLLER_BUTTON_DPAD_UP => .up,
                c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => .down,
                else => null,
            },
            c.SDL_JOYHATMOTION => {
                if (self.controller == null) {
                    if (ev.jhat.value == c.SDL_HAT_UP) return .up;
                    if (ev.jhat.value == c.SDL_HAT_DOWN) return .down;
                }
            },
            c.SDL_JOYBUTTONDOWN => {
                if (self.controller == null) return switch (ev.jbutton.button) {
                    // muOS-Keys raw indices, from the muOS-Keys entry in
                    // /usr/lib/gamecontrollerdb.txt: a:b3 b:b4 x:b6 y:b5
                    // leftshoulder:b7 rightshoulder:b8. Only reached as a
                    // fallback when SDL_GameControllerOpen failed to map
                    // the pad; the plan's original guess here (0-5) was
                    // wrong across the board.
                    3 => .a,
                    4 => .b,
                    6 => .x,
                    5 => .y,
                    7 => .l1,
                    8 => .r1,
                    else => null,
                };
            },
            c.SDL_KEYDOWN => return switch (ev.key.keysym.sym) {
                c.SDLK_UP => .up,
                c.SDLK_DOWN => .down,
                c.SDLK_RETURN => .a,
                c.SDLK_ESCAPE => .b,
                else => null,
            },
            else => {},
        }
    }
    return null;
}

/// Prints every controller/joystick event so the mapping in `poll` can be
/// confirmed (or corrected) against real hardware. Exits on SDL_QUIT or
/// after `timeout_ms`, whichever comes first. Kept even though the muOS-Keys
/// mapping is now known (gamecontrollerdb.txt, see poll()'s doc comment) -
/// Task 8's UI testing is expected to re-run this once with the device in
/// hand to confirm it live.
pub fn inputTest(timeout_ms: u32) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const win = c.SDL_CreateWindow("btui", 0, 0, screen_w, screen_h, c.SDL_WINDOW_SHOWN) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
    defer c.SDL_DestroyWindow(win);

    const pad = openPad();
    defer if (pad.controller) |ctl| c.SDL_GameControllerClose(ctl);
    defer if (pad.joystick) |j| c.SDL_JoystickClose(j);
    std.debug.print("controller: {s}  joystick fallback: {s}\n", .{
        if (pad.controller != null) "opened" else "none",
        if (pad.joystick != null) "opened" else "none",
    });

    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 16) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => return,
                c.SDL_CONTROLLERBUTTONDOWN => std.debug.print("controller button {d}\n", .{ev.cbutton.button}),
                c.SDL_JOYBUTTONDOWN => std.debug.print("raw joystick button {d}\n", .{ev.jbutton.button}),
                c.SDL_JOYHATMOTION => std.debug.print("raw hat {d}\n", .{ev.jhat.value}),
                else => {},
            }
        }
        c.SDL_Delay(16);
    }
}

/// Renders five dummy rows with row 2 selected, for `timeout_ms`, so the
/// list layout and theme colours can be checked on the real screen.
pub fn uiTest(font_path: [:0]const u8, timeout_ms: u32) !void {
    const ui = try init(font_path);
    defer deinit(ui);

    const pal = theme.palette();
    const labels = [_][:0]const u8{ "Row Alpha", "Row Bravo", "Row Charlie", "Row Delta", "Row Echo" };
    const statuses = [_][:0]const u8{ "-", "paired", "connected", "-", "-" };

    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 16) {
        while (poll(ui)) |btn| {
            if (btn == .quit or btn == .b) return;
        }
        beginFrame(ui, pal);
        for (labels, 0..) |label, i| {
            listRow(ui, i, i == 2, label, statuses[i], pal);
        }
        endFrame(ui);
        c.SDL_Delay(16);
    }
}
