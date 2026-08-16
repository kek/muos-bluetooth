// PipeWire audio routing. State is read as JSON from pw-dump; changes go
// through wpctl and pw-metadata. Zig 0.16 has no process spawning API yet, so
// subprocesses use libc popen - we link libc regardless.
const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

pub const Sink = struct {
    id: u32,
    name: []const u8,
    description: []const u8,
    is_bluetooth: bool,
    is_default: bool,
};

/// muOS exports these from script/var/func.sh. Without them the PipeWire tools
/// report an empty graph instead of failing, which looks exactly like "no
/// sinks exist" and is extremely misleading.
const env_prefix = "XDG_RUNTIME_DIR=/run PIPEWIRE_RUNTIME_DIR=/run ";

// Fix round 2, finding M5: `std.json.Value`'s `.object`/`.array`/`.string`/
// `.integer` fields are a tagged union - reading the wrong one is illegal
// behaviour (a Debug-only safety panic, undefined in the ReleaseSmall build
// this ships as), not a catchable error. `pw-dump`'s JSON is less guaranteed
// input than BlueZ's own D-Bus messages, which are already strongly typed by
// the wire protocol itself - a real reply with `"info": null` (or any field
// present but the wrong JSON type) would previously have been UB rather than
// just an unmatched sink. Each helper checks the tag before returning the
// payload, so every access below can stay an ordinary `orelse continue`.
fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}
fn asArray(v: std.json.Value) ?std.json.Array {
    return if (v == .array) v.array else null;
}
fn asString(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}
fn asInteger(v: std.json.Value) ?i64 {
    return if (v == .integer) v.integer else null;
}

pub fn parseSinks(gpa: std.mem.Allocator, json_text: []const u8) ![]Sink {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();

    const top = asArray(parsed.value) orelse return &.{};

    var default_name: []const u8 = "";
    for (top.items) |obj| {
        const obj_map = asObject(obj) orelse continue;
        const md = asArray(obj_map.get("metadata") orelse continue) orelse continue;
        for (md.items) |e| {
            const e_map = asObject(e) orelse continue;
            const key = asString(e_map.get("key") orelse continue) orelse continue;
            if (!std.mem.eql(u8, key, "default.audio.sink")) continue;
            const val = asObject(e_map.get("value") orelse continue) orelse continue;
            if (val.get("name")) |n| default_name = asString(n) orelse continue;
        }
    }

    var out: std.ArrayList(Sink) = .empty;
    errdefer {
        for (out.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        out.deinit(gpa);
    }

    for (top.items) |obj| {
        const obj_map = asObject(obj) orelse continue;
        const info = asObject(obj_map.get("info") orelse continue) orelse continue;
        const props = asObject(info.get("props") orelse continue) orelse continue;
        const class = asString(props.get("media.class") orelse continue) orelse continue;
        if (!std.mem.eql(u8, class, "Audio/Sink")) continue;

        // Resolve every `orelse continue` before allocating anything below:
        // `continue` isn't an error unwind, so an errdefer registered before
        // it would never run and any prior dupe would leak silently.
        const id = asInteger(obj_map.get("id") orelse continue) orelse continue;
        const name = asString(props.get("node.name") orelse continue) orelse continue;
        const desc = if (props.get("node.description")) |d| (asString(d) orelse name) else name;

        // Each dupe gets its own errdefer so a failure on the second one
        // can't leak the first: both must be freed exactly once, whether
        // this sink makes it into `out` or not.
        const name_dup = try gpa.dupe(u8, name);
        errdefer gpa.free(name_dup);
        const desc_dup = try gpa.dupe(u8, desc);
        errdefer gpa.free(desc_dup);

        try out.append(gpa, .{
            .id = @intCast(id),
            .name = name_dup,
            .description = desc_dup,
            .is_bluetooth = std.mem.startsWith(u8, name, "bluez_output"),
            .is_default = std.mem.eql(u8, name, default_name),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeSinks(gpa: std.mem.Allocator, list: []Sink) void {
    for (list) |s| {
        gpa.free(s.name);
        gpa.free(s.description);
    }
    gpa.free(list);
}

fn runCapture(gpa: std.mem.Allocator, cmd: [*c]const u8) ![]u8 {
    const f = c.popen(cmd, "r") orelse return error.PopenFailed;
    defer _ = c.pclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (c.fgets(&buf, buf.len, f) != null) {
        try out.appendSlice(gpa, std.mem.span(@as([*:0]const u8, @ptrCast(&buf))));
    }
    return out.toOwnedSlice(gpa);
}

pub fn sinks(gpa: std.mem.Allocator) ![]Sink {
    const text = try runCapture(gpa, env_prefix ++ "pw-dump");
    defer gpa.free(text);
    return parseSinks(gpa, text);
}

fn runQuiet(cmd: [*c]const u8) void {
    _ = c.system(cmd);
}

pub fn setDefault(sink: Sink) void {
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, env_prefix ++ "wpctl set-default {d} >/dev/null 2>&1", .{sink.id}) catch return;
    runQuiet(cmd.ptr);
    // Matches bin/bt-audio.sh: a 2048 quantum makes the A2DP transport miss
    // radio windows shared with WiFi, which breaks audio up during play.
    forceQuantum(if (sink.is_bluetooth) 512 else 0);
}

pub fn forceQuantum(frames: u32) void {
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, env_prefix ++ "pw-metadata -n settings 0 clock.force-quantum {d} >/dev/null 2>&1", .{frames}) catch return;
    runQuiet(cmd.ptr);
}

test "parseSinks finds sinks and marks the default" {
    const gpa = std.testing.allocator;
    const json_text =
        \\[
        \\ {"id":33,"type":"PipeWire:Interface:Node",
        \\  "info":{"props":{"media.class":"Audio/Sink","node.name":"alsa_output.internal","node.description":"Built-in Audio"}}},
        \\ {"id":49,"type":"PipeWire:Interface:Node",
        \\  "info":{"props":{"media.class":"Audio/Sink","node.name":"bluez_output.4C_87_5D_FD_3E_42.1","node.description":"Constantin"}}},
        \\ {"id":21,"type":"PipeWire:Interface:Metadata",
        \\  "metadata":[{"key":"default.audio.sink","value":{"name":"bluez_output.4C_87_5D_FD_3E_42.1"}}]}
        \\]
    ;
    const list = try parseSinks(gpa, json_text);
    defer freeSinks(gpa, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(!list[0].is_bluetooth);
    try std.testing.expect(list[1].is_bluetooth);
    try std.testing.expect(list[1].is_default);
    try std.testing.expectEqualStrings("Constantin", list[1].description);
}
