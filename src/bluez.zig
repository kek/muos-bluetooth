// BlueZ domain model over D-Bus: device enumeration and operations.
const std = @import("std");
const dbus = @import("dbus.zig");
const c = dbus.c;

pub const Device = struct {
    path: [:0]u8,
    address: [:0]u8,
    alias: [:0]u8,
    icon: [:0]u8,
    paired: bool = false,
    trusted: bool = false,
    connected: bool = false,

    /// Audio devices get their sink routed automatically on connect.
    pub fn isAudio(self: Device) bool {
        return std.mem.startsWith(u8, self.icon, "audio");
    }
};

fn dupz(gpa: std.mem.Allocator, s: [*c]const u8) ![:0]u8 {
    return gpa.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(s))));
}

/// Builds a `Device` with empty string fields (besides `path`), freeing
/// whatever it already allocated if a later field fails. Once this returns
/// successfully the caller owns a fully-formed `Device` with no partial
/// state left behind to clean up.
fn makeDevice(gpa: std.mem.Allocator, path: [*c]const u8) !Device {
    const p = try dupz(gpa, path);
    errdefer gpa.free(p);
    const address = try dupz(gpa, "");
    errdefer gpa.free(address);
    const alias = try dupz(gpa, "");
    errdefer gpa.free(alias);
    const icon = try dupz(gpa, "");
    errdefer gpa.free(icon);
    return Device{ .path = p, .address = address, .alias = alias, .icon = icon };
}

fn freeDevice(gpa: std.mem.Allocator, d: Device) void {
    gpa.free(d.path);
    gpa.free(d.address);
    gpa.free(d.alias);
    gpa.free(d.icon);
}

/// Reads org.bluez's whole object tree and returns every org.bluez.Device1.
/// Reply signature is a{oa{sa{sv}}}: path -> interface -> property -> variant.
pub fn list(gpa: std.mem.Allocator, conn: dbus.Connection) ![]Device {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", &err);
    defer c.dbus_message_unref(reply);

    var out: std.ArrayList(Device) = .empty;
    errdefer {
        for (out.items) |d| freeDevice(gpa, d);
        out.deinit(gpa);
    }

    var top: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_init(reply, &top);
    var objects: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&top, &objects);

    while (c.dbus_message_iter_get_arg_type(&objects) != c.DBUS_TYPE_INVALID) {
        var obj: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&objects, &obj);
        const path = dbus.iterString(&obj);
        _ = c.dbus_message_iter_next(&obj);

        var ifaces: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&obj, &ifaces);
        while (c.dbus_message_iter_get_arg_type(&ifaces) != c.DBUS_TYPE_INVALID) {
            var ie: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&ifaces, &ie);
            const iname = dbus.iterString(&ie);
            _ = c.dbus_message_iter_next(&ie);

            if (c.strcmp(iname, "org.bluez.Device1") == 0) {
                var d = try makeDevice(gpa, path);
                errdefer freeDevice(gpa, d);
                var props: c.DBusMessageIter = undefined;
                c.dbus_message_iter_recurse(&ie, &props);
                try readProps(gpa, &props, &d);
                try out.append(gpa, d);
            }
            _ = c.dbus_message_iter_next(&ifaces);
        }
        _ = c.dbus_message_iter_next(&objects);
    }
    return out.toOwnedSlice(gpa);
}

fn readProps(gpa: std.mem.Allocator, props: *c.DBusMessageIter, d: *Device) !void {
    while (c.dbus_message_iter_get_arg_type(props) != c.DBUS_TYPE_INVALID) {
        var entry: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(props, &entry);
        const key = dbus.iterString(&entry);
        _ = c.dbus_message_iter_next(&entry);

        var variant: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&entry, &variant);
        const vtype = c.dbus_message_iter_get_arg_type(&variant);

        if (vtype == c.DBUS_TYPE_STRING) {
            const v = dbus.iterString(&variant);
            // Dupe the new value before freeing the old one: if dupz fails,
            // `d` must stay in a fully-valid, freeable state (see makeDevice).
            if (c.strcmp(key, "Address") == 0) {
                const new_v = try dupz(gpa, v);
                gpa.free(d.address);
                d.address = new_v;
            } else if (c.strcmp(key, "Alias") == 0) {
                const new_v = try dupz(gpa, v);
                gpa.free(d.alias);
                d.alias = new_v;
            } else if (c.strcmp(key, "Icon") == 0) {
                const new_v = try dupz(gpa, v);
                gpa.free(d.icon);
                d.icon = new_v;
            }
        } else if (vtype == c.DBUS_TYPE_BOOLEAN) {
            const v = dbus.iterBool(&variant);
            if (c.strcmp(key, "Paired") == 0) d.paired = v;
            if (c.strcmp(key, "Trusted") == 0) d.trusted = v;
            if (c.strcmp(key, "Connected") == 0) d.connected = v;
        }
        _ = c.dbus_message_iter_next(props);
    }
}

pub fn freeList(gpa: std.mem.Allocator, devices: []Device) void {
    for (devices) |d| freeDevice(gpa, d);
    gpa.free(devices);
}
