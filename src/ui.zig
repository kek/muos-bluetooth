// SDL2 window, themed text, list rows, and gamepad/keyboard input polling.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("stdio.h");
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
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK | c.SDL_INIT_GAMECONTROLLER) != 0) {
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
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK | c.SDL_INIT_GAMECONTROLLER) != 0) {
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

/// Fills a rectangle in `colour` - used for e.g. an error modal's backdrop,
/// so its text doesn't composite directly over whatever else is already
/// drawn (a selected list row's accent band included).
pub fn fillRect(self: Ui, x: c_int, y: c_int, w: c_int, h: c_int, colour: u32) void {
    setColor(self.renderer, colour);
    var r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
    _ = c.SDL_RenderFillRect(self.renderer, &r);
}

const Glyphs = struct { tex: *c.SDL_Texture, w: c_int, h: c_int };

/// Renders `s` to a texture. Caller owns and must destroy the returned
/// texture; the intermediate surface is freed here regardless of outcome.
/// Both failure paths print the SDL/TTF error text rather than failing
/// silently - a frame where every glyph fails to draw must not look like a
/// perfect frame in the console output (see task-7-report.md's fix-round-1
/// notes: silence here previously made "no error output" worthless as
/// evidence that text was actually rendered).
///
/// Fix round 1 (task-8-review.md finding I2): an empty string is a normal,
/// expected input here (e.g. a device that's neither connected nor paired
/// renders a blank right-hand status), not a failure - so it returns early
/// rather than handing SDL_ttf a zero-width string, which fails with "Text
/// has zero width" and would otherwise hit the diagnostic above once per
/// blank row per frame.
fn render(self: Ui, s: [:0]const u8, colour: u32) ?Glyphs {
    if (s.len == 0) return null;
    const col = c.SDL_Color{
        .r = @intCast((colour >> 16) & 0xFF),
        .g = @intCast((colour >> 8) & 0xFF),
        .b = @intCast(colour & 0xFF),
        .a = 0xFF,
    };
    const surf = c.TTF_RenderUTF8_Blended(self.font, s.ptr, col) orelse {
        std.debug.print("TTF_RenderUTF8_Blended failed: {s}\n", .{c.TTF_GetError()});
        return null;
    };
    defer c.SDL_FreeSurface(surf);
    const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse {
        std.debug.print("SDL_CreateTextureFromSurface failed: {s}\n", .{c.SDL_GetError()});
        return null;
    };
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
///
/// Deliberately NOT falling back to the raw path when a controller is open
/// but has never produced an event (fix-round-1 considered this after the
/// missing SDL_INIT_GAMECONTROLLER defect - see task-7-report.md). The
/// defect's actual root cause was the subsystem never being initialised, a
/// one-line fix with no ambiguity; a "no event yet, so fall back" heuristic
/// would instead need to guess a wait threshold, and picking one wrong
/// either delays real input on a slow first frame or masks a genuine future
/// regression in the controller path by quietly limping along on the raw
/// one - a worse failure mode than the current loud "nothing happens at
/// all" for a class of bug that init() already fully closes.
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

/// Name shown on screen and matched against `poll`'s own mapping - kept in
/// sync by hand since `poll` returns a `Button`, not the raw SDL constant.
fn controllerButtonName(button: u8) []const u8 {
    return switch (button) {
        c.SDL_CONTROLLER_BUTTON_A => "A",
        c.SDL_CONTROLLER_BUTTON_B => "B",
        c.SDL_CONTROLLER_BUTTON_X => "X",
        c.SDL_CONTROLLER_BUTTON_Y => "Y",
        c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER => "L1",
        c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => "R1",
        c.SDL_CONTROLLER_BUTTON_DPAD_UP => "UP",
        c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => "DOWN",
        c.SDL_CONTROLLER_BUTTON_DPAD_LEFT => "LEFT",
        c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => "RIGHT",
        else => "(unmapped)",
    };
}

/// Renders `s` centred horizontally at `y` in `font` - used for the one big
/// "last event" line, which needs a font size `Ui.font` (18pt, sized for
/// list rows) is too small for. Not part of `render()`/`text()` because it
/// takes an explicit font rather than `self.font`.
fn drawCentered(ren: *c.SDL_Renderer, font: *c.TTF_Font, y: c_int, s: [:0]const u8, colour: u32) void {
    const col = c.SDL_Color{
        .r = @intCast((colour >> 16) & 0xFF),
        .g = @intCast((colour >> 8) & 0xFF),
        .b = @intCast(colour & 0xFF),
        .a = 0xFF,
    };
    const surf = c.TTF_RenderUTF8_Blended(font, s.ptr, col) orelse {
        std.debug.print("TTF_RenderUTF8_Blended failed: {s}\n", .{c.TTF_GetError()});
        return;
    };
    defer c.SDL_FreeSurface(surf);
    const tex = c.SDL_CreateTextureFromSurface(ren, surf) orelse {
        std.debug.print("SDL_CreateTextureFromSurface failed: {s}\n", .{c.SDL_GetError()});
        return;
    };
    defer c.SDL_DestroyTexture(tex);
    var dst = c.SDL_Rect{ .x = @divTrunc(screen_w - surf.*.w, 2), .y = y, .w = surf.*.w, .h = surf.*.h };
    _ = c.SDL_RenderCopy(ren, tex, null, &dst);
}

/// Renders every frame so a human pressing buttons gets immediate on-screen
/// feedback: title, the last event (large, roughly centred), a running
/// event count, and seconds remaining. Exits on SDL_QUIT, `.b`, or after
/// `timeout_ms`, whichever comes first. Every event is still printed to
/// stdout exactly as before, for the log a reviewer reads afterwards.
///
/// Fix-round-1 addendum: the first version of this test created a window
/// but never drew a single frame, so the screen kept showing whatever was
/// already on it - a device owner asked to press buttons had no way to tell
/// the test was even running, and pressed nothing. On-screen feedback is
/// what makes a live pass actually testable.
pub fn inputTest(font_path: [:0]const u8, timeout_ms: u32) !void {
    const ui = try init(font_path);
    defer deinit(ui);

    // A second, larger font just for the "last event" line - the 18pt list
    // font is legible at a glance but not the "unmistakable from across the
    // room" size this test wants. Falls back to the list font if a bigger
    // size can't be opened, rather than failing the whole test over it.
    const big_font = c.TTF_OpenFont(font_path.ptr, 40);
    defer if (big_font) |f| c.TTF_CloseFont(f);

    std.debug.print("controller: {s}  joystick fallback: {s}\n", .{
        if (ui.controller != null) "opened" else "none",
        if (ui.joystick != null) "opened" else "none",
    });

    const pal = theme.palette();
    var event_count: u32 = 0;
    var last_buf: [64:0]u8 = undefined;
    var last_event: [:0]const u8 = std.fmt.bufPrintZ(&last_buf, "(no events yet)", .{}) catch "?";

    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 16) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => return,
                c.SDL_CONTROLLERBUTTONDOWN => {
                    event_count += 1;
                    const name = controllerButtonName(ev.cbutton.button);
                    std.debug.print("controller button {d} ({s})\n", .{ ev.cbutton.button, name });
                    last_event = std.fmt.bufPrintZ(&last_buf, "{s}", .{name}) catch last_event;
                },
                c.SDL_JOYBUTTONDOWN => {
                    event_count += 1;
                    std.debug.print("raw joystick button {d}\n", .{ev.jbutton.button});
                    last_event = std.fmt.bufPrintZ(&last_buf, "raw joystick button {d}", .{ev.jbutton.button}) catch last_event;
                },
                c.SDL_JOYHATMOTION => {
                    event_count += 1;
                    std.debug.print("raw hat {d}\n", .{ev.jhat.value});
                    last_event = std.fmt.bufPrintZ(&last_buf, "raw hat {d}", .{ev.jhat.value}) catch last_event;
                },
                else => {},
            }
        }

        beginFrame(ui, pal);
        text(ui, 24, 24, "INPUT TEST - press A B X Y L1 R1 UP DOWN", pal.fg);
        drawCentered(ui.renderer, big_font orelse ui.font, 180, last_event, pal.accent);

        var count_buf: [32:0]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(&count_buf, "events seen: {d}", .{event_count}) catch "events seen: ?";
        text(ui, 24, 280, count_str, pal.fg);

        var secs_buf: [32:0]u8 = undefined;
        const secs_left = (timeout_ms - elapsed) / 1000;
        const secs_str = std.fmt.bufPrintZ(&secs_buf, "{d}s remaining", .{secs_left}) catch "?s remaining";
        text(ui, 24, 320, secs_str, pal.dim);
        endFrame(ui);

        c.SDL_Delay(16);
    }
}

/// Path `--ui-test` dumps its one screenshot to. Raw RGBA8888, no header,
/// screen_w * screen_h * 4 bytes - convert with e.g.
/// `convert -size 640x480 -depth 8 rgba:btui_ui_test.rgba out.png`.
pub const screenshot_path = "/tmp/btui_ui_test.rgba";

/// Reads the renderer's current backbuffer via SDL_RenderReadPixels and
/// writes it as raw RGBA8888 to `path`. This bypasses /dev/fb0 entirely -
/// fbgrab reads a buffer this device's mali driver never writes to (see
/// task-7-report.md), but SDL_RenderReadPixels reads the renderer's own
/// backing store directly, so it works regardless of what fbgrab sees.
///
/// Must be called after drawing the frame's contents but BEFORE endFrame's
/// SDL_RenderPresent: some accelerated backends use swap semantics on
/// present (the "back" buffer just drawn becomes the new "front" buffer, or
/// is invalidated outright) rather than a copy, so reading after the flip
/// can return stale or undefined content on some drivers. Reading before
/// the flip is the documented-safe point on every backend.
pub fn screenshot(self: Ui, gpa: std.mem.Allocator, path: [:0]const u8) !void {
    const pitch: usize = @intCast(screen_w * 4);
    const buf = try gpa.alloc(u8, pitch * @as(usize, @intCast(screen_h)));
    defer gpa.free(buf);

    var rect = c.SDL_Rect{ .x = 0, .y = 0, .w = screen_w, .h = screen_h };
    // ABGR8888 is SDL's name for the format whose in-memory byte order on a
    // little-endian machine (this device's aarch64) is R,G,B,A - i.e. what
    // ImageMagick's `rgba:` raw importer and every other "RGBA bytes" reader
    // expects.
    if (c.SDL_RenderReadPixels(self.renderer, &rect, c.SDL_PIXELFORMAT_ABGR8888, buf.ptr, @intCast(pitch)) != 0) {
        std.debug.print("SDL_RenderReadPixels failed: {s}\n", .{c.SDL_GetError()});
        return error.ReadPixels;
    }

    const f = c.fopen(path.ptr, "wb") orelse return error.FileOpen;
    defer _ = c.fclose(f);
    if (c.fwrite(buf.ptr, 1, buf.len, f) != buf.len) return error.ShortWrite;
}

/// Renders five dummy rows with row 2 selected, for `timeout_ms`, so the
/// list layout and theme colours can be checked on the real screen. Dumps
/// one screenshot (see `screenshot_path`) after the first frame is drawn,
/// so the layout can be checked in software instead of needing eyes on the
/// device (see task-7-report.md's fix-round-1 notes on fbgrab being blind
/// to this driver's output).
pub fn uiTest(font_path: [:0]const u8, gpa: std.mem.Allocator, timeout_ms: u32) !void {
    const ui = try init(font_path);
    defer deinit(ui);

    const pal = theme.palette();
    const labels = [_][:0]const u8{ "Row Alpha", "Row Bravo", "Row Charlie", "Row Delta", "Row Echo" };
    const statuses = [_][:0]const u8{ "-", "paired", "connected", "-", "-" };

    var shot_taken = false;
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 16) {
        while (poll(ui)) |btn| {
            if (btn == .quit or btn == .b) return;
        }
        beginFrame(ui, pal);
        for (labels, 0..) |label, i| {
            listRow(ui, i, i == 2, label, statuses[i], pal);
        }
        if (!shot_taken) {
            screenshot(ui, gpa, screenshot_path) catch |e| {
                std.debug.print("screenshot failed: {s}\n", .{@errorName(e)});
            };
            shot_taken = true;
        }
        endFrame(ui);
        c.SDL_Delay(16);
    }
}
