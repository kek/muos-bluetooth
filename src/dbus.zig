// Thin wrapper over libdbus-1 - the same library bluetoothctl uses.
// This is the only file that knows about D-Bus C interop.
const std = @import("std");
pub const c = @cImport({
    @cInclude("dbus/dbus.h");
    @cInclude("string.h");
});

/// dbus.h's DBusError contains bitfields, so translate-c renders it opaque and
/// Zig cannot allocate one. Mirror the layout: two pointers, a flags word, and
/// a padding pointer = 32 bytes on 64-bit.
pub const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    bits: c_uint = 0,
    padding1: ?*anyopaque = null,

    pub fn ptr(self: *Error) *c.DBusError {
        return @ptrCast(self);
    }
    pub fn text(self: *Error) [*c]const u8 {
        return if (self.message) |m| m else "(no detail)";
    }
};

pub const DBusFailure = error{ ConnectFailed, CallFailed };

pub const Connection = struct {
    handle: ?*c.DBusConnection,

    pub fn call(
        self: Connection,
        dest: [*c]const u8,
        path: [*c]const u8,
        iface: [*c]const u8,
        method: [*c]const u8,
        err: *Error,
    ) DBusFailure!*c.DBusMessage {
        const msg = c.dbus_message_new_method_call(dest, path, iface, method);
        defer c.dbus_message_unref(msg);
        const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 5000, err.ptr());
        return reply orelse DBusFailure.CallFailed;
    }

    /// Non-blocking: process any pending incoming messages. Call once per frame.
    pub fn pump(self: Connection) void {
        _ = c.dbus_connection_read_write_dispatch(self.handle, 0);
    }
};

pub fn connectSystem(err: *Error) DBusFailure!Connection {
    c.dbus_error_init(err.ptr());
    const conn = c.dbus_bus_get(c.DBUS_BUS_SYSTEM, err.ptr());
    return .{ .handle = conn orelse return DBusFailure.ConnectFailed };
}

/// `dbus_message_iter_get_basic` does not copy string data: the returned
/// pointer aliases a buffer owned by the `DBusMessage` the iterator was
/// initialised from. It is only valid while that message is alive and
/// unreffed; callers who need the value to outlive the message must copy it.
pub fn iterString(it: *c.DBusMessageIter) [*c]const u8 {
    var s: [*c]const u8 = undefined;
    c.dbus_message_iter_get_basic(it, @ptrCast(&s));
    return s;
}

/// Same lifetime note as `iterString`: valid only while the source
/// `DBusMessage` is alive and unreffed (bools are copied by value here, but
/// the iterator itself still points into that message).
pub fn iterBool(it: *c.DBusMessageIter) bool {
    var b: c.dbus_bool_t = 0;
    c.dbus_message_iter_get_basic(it, @ptrCast(&b));
    return b != 0;
}
