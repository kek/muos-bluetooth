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

/// Reads org.bluez's whole object tree and returns every org.bluez.Device1.
/// Reply signature is a{oa{sa{sv}}}: path -> interface -> property -> variant.
pub fn list(gpa: std.mem.Allocator, conn: dbus.Connection) ![]Device {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", &err);
    defer c.dbus_message_unref(reply);

    var out: std.ArrayList(Device) = .empty;
    errdefer out.deinit(gpa);

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
                var d = Device{
                    .path = try dupz(gpa, path),
                    .address = try dupz(gpa, ""),
                    .alias = try dupz(gpa, ""),
                    .icon = try dupz(gpa, ""),
                };
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
            if (c.strcmp(key, "Address") == 0) {
                gpa.free(d.address);
                d.address = try dupz(gpa, v);
            } else if (c.strcmp(key, "Alias") == 0) {
                gpa.free(d.alias);
                d.alias = try dupz(gpa, v);
            } else if (c.strcmp(key, "Icon") == 0) {
                gpa.free(d.icon);
                d.icon = try dupz(gpa, v);
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
    for (devices) |d| {
        gpa.free(d.path);
        gpa.free(d.address);
        gpa.free(d.alias);
        gpa.free(d.icon);
    }
    gpa.free(devices);
}
