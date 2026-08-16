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

    /// Frees the name/message strings libdbus heap-allocates when a call
    /// fills this Error. Safe to call on an Error that was never set, and
    /// safe to call twice - `dbus_error_free` no-ops when `name` is already
    /// null. Callers that own an `Error` across a call (to read `.text()` on
    /// failure) must `defer err.deinit()` or leak those strings.
    pub fn deinit(self: *Error) void {
        c.dbus_error_free(self.ptr());
    }
};

pub const DBusFailure = error{ ConnectFailed, CallFailed };

/// A method-call argument. Variants (e.g. the boolean in a property `Set`)
/// aren't representable here - see `Connection.setBoolProperty`.
pub const Arg = union(enum) {
    str: [*c]const u8,
    obj: [*c]const u8,
    boolean: bool,
};

/// A `Connect`/`Pair` call handed off to be polled from the frame loop
/// instead of blocking on it. See `Connection.callAsync`.
pub const Pending = struct {
    call: ?*c.DBusPendingCall,

    /// True once a reply has arrived, and also once `take()` or `deinit()`
    /// has already consumed this `Pending` - a caller that polls `done()`
    /// after taking the reply must not see it flip back to "not done".
    pub fn done(self: Pending) bool {
        return self.call == null or c.dbus_pending_call_get_completed(self.call) != 0;
    }

    /// Consumes the pending call, exactly once: `self.call` is nulled before
    /// the reply is stolen, so a second `take()` (or a `done()` after this)
    /// sees an already-empty `Pending` instead of touching a freed
    /// `DBusPendingCall`. Returns the reply, which may itself be an error
    /// message - check with `errorName`. Returns null if already consumed.
    pub fn take(self: *Pending) ?*c.DBusMessage {
        const call = self.call orelse return null;
        self.call = null;
        const reply = c.dbus_pending_call_steal_reply(call);
        c.dbus_pending_call_unref(call);
        return reply;
    }

    /// Releases the pending call without caring about its reply: cancels it
    /// (so a notify callback, if one were ever registered, would not fire),
    /// steals and discards whatever reply is sitting there so it isn't
    /// leaked, then unrefs. Idempotent - safe after `take()` or a previous
    /// `deinit()`. For the frame loop's cancel path (e.g. the user backs out
    /// of a connect/pair modal before it completes).
    pub fn deinit(self: *Pending) void {
        const call = self.call orelse return;
        self.call = null;
        if (c.dbus_pending_call_get_completed(call) == 0) c.dbus_pending_call_cancel(call);
        if (c.dbus_pending_call_steal_reply(call)) |reply| c.dbus_message_unref(reply);
        c.dbus_pending_call_unref(call);
    }
};

/// Null unless the reply is a D-Bus error, e.g. "org.bluez.Error.AuthenticationFailed".
pub fn errorName(reply: *c.DBusMessage) ?[*c]const u8 {
    if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_ERROR) return null;
    return c.dbus_message_get_error_name(reply);
}

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

    /// Like `call`, but appends `args` to the outgoing message. Needed for
    /// calls that take parameters: `RemoveDevice`, agent registration, etc.
    pub fn callArgs(
        self: Connection,
        dest: [*c]const u8,
        path: [*c]const u8,
        iface: [*c]const u8,
        method: [*c]const u8,
        args: []const Arg,
        err: *Error,
    ) DBusFailure!*c.DBusMessage {
        const msg = c.dbus_message_new_method_call(dest, path, iface, method);
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        for (args) |a| switch (a) {
            .str => |s| _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&s)),
            .obj => |s| _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&s)),
            .boolean => |b| {
                var v: c.dbus_bool_t = if (b) 1 else 0;
                _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_BOOLEAN, @ptrCast(&v));
            },
        };
        const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 30000, err.ptr());
        return reply orelse DBusFailure.CallFailed;
    }

    /// Sets a boolean D-Bus property via org.freedesktop.DBus.Properties.Set.
    /// The value must go inside a variant container, which `Arg`/`callArgs`
    /// cannot express, so this builds the message by hand.
    pub fn setBoolProperty(
        self: Connection,
        path: [*c]const u8,
        iface: [*c]const u8,
        name: [*c]const u8,
        value: bool,
        err: *Error,
    ) DBusFailure!void {
        const msg = c.dbus_message_new_method_call("org.bluez", path, "org.freedesktop.DBus.Properties", "Set");
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&iface));
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&name));
        var variant: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_VARIANT, "b", &variant);
        var v: c.dbus_bool_t = if (value) 1 else 0;
        _ = c.dbus_message_iter_append_basic(&variant, c.DBUS_TYPE_BOOLEAN, @ptrCast(&v));
        _ = c.dbus_message_iter_close_container(&it, &variant);
        const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 5000, err.ptr());
        if (reply) |r| c.dbus_message_unref(r) else return DBusFailure.CallFailed;
    }

    /// Non-blocking variant of `call`: sends the message and returns a
    /// `Pending` immediately instead of blocking for the reply. Used for
    /// `Connect`/`Pair`, which can take many seconds - blocking on them would
    /// freeze the frame loop.
    pub fn callAsync(
        self: Connection,
        dest: [*c]const u8,
        path: [*c]const u8,
        iface: [*c]const u8,
        method: [*c]const u8,
    ) DBusFailure!Pending {
        const msg = c.dbus_message_new_method_call(dest, path, iface, method);
        defer c.dbus_message_unref(msg);
        var pending: ?*c.DBusPendingCall = null;
        if (c.dbus_connection_send_with_reply(self.handle, msg, &pending, 60000) == 0)
            return DBusFailure.CallFailed;
        return .{ .call = pending orelse return DBusFailure.CallFailed };
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
