// BlueZ domain model over D-Bus: device enumeration and operations.
const std = @import("std");
const dbus = @import("dbus.zig");
const c = dbus.c;

// Only for the agent-callback logging below - kept separate from `c`
// (`dbus.c`) so the D-Bus wrapper itself stays about D-Bus, not stdio.
const libc = @cImport({
    @cInclude("stdio.h");
});

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
///
/// Fix round 2, finding I1: takes `err` from the caller instead of
/// allocating and discarding its own, matching every blocking verb below
/// (see the comment above `deviceCall`) - this is the one call site the
/// project's own "caller owns `err`" convention never reached. Without it,
/// a failure here (the hottest allocation path in the program - it runs
/// every ~500ms during a scan) leaked libdbus's `name`/`message` strings on
/// every occurrence and surfaced only the bare `CallFailed`, never BlueZ's
/// actual reason (e.g. "`bluetoothd` not on the bus").
pub fn list(gpa: std.mem.Allocator, conn: dbus.Connection, err: *dbus.Error) ![]Device {
    const reply = try conn.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", err);
    defer c.dbus_message_unref(reply);

    var out: std.ArrayList(Device) = .empty;
    errdefer {
        for (out.items) |d| freeDevice(gpa, d);
        out.deinit(gpa);
    }

    var top: c.DBusMessageIter = undefined;
    // Fix round 2, finding M3: `dbus_message_iter_init`'s return and the
    // top-level argument's type were never checked before recursing into
    // it - a reply with no body, or whose first argument isn't the array
    // `GetManagedObjects` always returns, would hand `dbus_message_iter_
    // recurse` a container type it isn't. BlueZ is trusted to reply
    // correctly in practice, but this is the one genuinely reachable arm of
    // that concern, so it's worth closing structurally: degrade to an empty
    // list rather than operate on an iterator that was never actually
    // initialised as an array.
    if (c.dbus_message_iter_init(reply, &top) == 0 or c.dbus_message_iter_get_arg_type(&top) != c.DBUS_TYPE_ARRAY) {
        return out.toOwnedSlice(gpa);
    }
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

pub const adapter_path = "/org/bluez/hci0";

// Every blocking verb below takes `err` from the caller rather than
// allocating its own and discarding it: a discarded `Error` means the
// operator only ever sees the bare Zig error (`CallFailed`), never the
// actual D-Bus reason (e.g. `org.bluez.Error.DoesNotExist`). The caller owns
// `err` and must `defer err.deinit()` to free the strings libdbus
// heap-allocates into it.

fn deviceCall(conn: dbus.Connection, dev: Device, method: [*c]const u8, err: *dbus.Error) !void {
    const reply = try conn.call("org.bluez", dev.path.ptr, "org.bluez.Device1", method, err);
    c.dbus_message_unref(reply);
}

/// Blocking: `Disconnect` returns promptly, unlike `Connect`/`Pair` (see
/// `connectAsync`/`pairAsync`).
pub fn disconnect(conn: dbus.Connection, dev: Device, err: *dbus.Error) !void {
    return deviceCall(conn, dev, "Disconnect", err);
}

/// Blocking, prompt-returning - same class as `disconnect`. Tells
/// `bluetoothd` to actually stop an in-flight `Pair`, unlike dropping our
/// own `dbus.Pending` (`Pending.deinit` only releases *our* D-Bus call and
/// tells BlueZ nothing): without this, a user who backs out of pairing
/// would still end up with a device BlueZ finishes pairing anyway, since
/// our own agent stays registered and auto-accepts whatever `bluetoothd`
/// asks while it completes in the background.
pub fn cancelPairing(conn: dbus.Connection, dev: Device, err: *dbus.Error) !void {
    return deviceCall(conn, dev, "CancelPairing", err);
}

pub fn startScan(conn: dbus.Connection, err: *dbus.Error) !void {
    const reply = try conn.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StartDiscovery", err);
    c.dbus_message_unref(reply);
}

pub fn stopScan(conn: dbus.Connection, err: *dbus.Error) !void {
    const reply = try conn.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StopDiscovery", err);
    c.dbus_message_unref(reply);
}

pub fn forget(conn: dbus.Connection, dev: Device, err: *dbus.Error) !void {
    const reply = try conn.callArgs("org.bluez", adapter_path, "org.bluez.Adapter1", "RemoveDevice", &.{.{ .obj = dev.path.ptr }}, err);
    c.dbus_message_unref(reply);
}

pub fn setTrusted(conn: dbus.Connection, dev: Device, on: bool, err: *dbus.Error) !void {
    try conn.setBoolProperty(dev.path.ptr, "org.bluez.Device1", "Trusted", on, err);
}

pub fn powerOn(conn: dbus.Connection, err: *dbus.Error) !void {
    try conn.setBoolProperty(adapter_path, "org.bluez.Adapter1", "Powered", true, err);
}

/// Non-blocking: `Connect` can take many seconds. The caller polls the
/// returned `dbus.Pending` from the frame loop instead of blocking on it.
pub fn connectAsync(conn: dbus.Connection, dev: Device) !dbus.Pending {
    return conn.callAsync("org.bluez", dev.path.ptr, "org.bluez.Device1", "Connect");
}

/// Non-blocking: `Pair` can take many seconds, and needs an agent registered
/// (see `registerAgent`) or it fails with org.bluez.Error.AuthenticationFailed.
pub fn pairAsync(conn: dbus.Connection, dev: Device) !dbus.Pending {
    return conn.callAsync("org.bluez", dev.path.ptr, "org.bluez.Device1", "Pair");
}

pub const agent_path = "/muos/btui/agent";

/// Set by `registerAgent`. `dbus_message_get_connection` does not exist in
/// libdbus, so the connection the agent replies on has to be captured here
/// instead of recovered from the incoming message.
var agent_conn: ?*c.DBusConnection = null;

/// First object-path (or string) argument of the incoming call, if any -
/// the device the request concerns for RequestConfirmation/
/// RequestAuthorization/AuthorizeService. Release/Cancel take no arguments,
/// so "(none)" there is expected, not a parsing failure.
fn firstPathArg(msg: ?*c.DBusMessage) [*c]const u8 {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return "(none)";
    const t = c.dbus_message_iter_get_arg_type(&it);
    if (t != c.DBUS_TYPE_OBJECT_PATH and t != c.DBUS_TYPE_STRING) return "(none)";
    return dbus.iterString(&it);
}

/// Logs every callback (method name + the device it concerns) and the reply
/// send - this agent is the single largest untested surface in the project
/// (see task-8-report.md), so a real pairing session needs evidence in the
/// transcript that these fired at all, not just silent auto-accept.
///
/// Flushed explicitly after every line: under muOS the packaged app's
/// stdout is redirected to a file and therefore fully buffered rather than
/// line-buffered, so on an abort (see the live `Pending.deinit` crash this
/// project already hit once) unflushed diagnostic lines are exactly the
/// ones lost - the hardware session that first proved this logging worked
/// only saw it because it happened to run on a tty.
fn agentMessage(_: ?*c.DBusConnection, msg: ?*c.DBusMessage, _: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const member = c.dbus_message_get_member(msg);
    _ = libc.printf("agent: %s %s\n", member, firstPathArg(msg));
    _ = libc.fflush(null);

    // Every method we accept returns an empty reply; rejecting is never needed
    // for NoInputNoOutput pairing.
    if (c.strcmp(member, "RequestConfirmation") == 0 or
        c.strcmp(member, "RequestAuthorization") == 0 or
        c.strcmp(member, "AuthorizeService") == 0 or
        c.strcmp(member, "Release") == 0 or
        c.strcmp(member, "Cancel") == 0)
    {
        const reply = c.dbus_message_new_method_return(msg);
        _ = c.dbus_connection_send(agent_conn, reply, null);
        c.dbus_message_unref(reply);
        _ = libc.printf("agent: %s reply sent\n", member);
        _ = libc.fflush(null);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

var agent_vtable = c.DBusObjectPathVTable{
    .unregister_function = null,
    .message_function = agentMessage,
};

/// Registers a NoInputNoOutput agent and, best-effort, asks to be the
/// default. BlueZ never asks this agent for a PIN or confirmation - it
/// auto-accepts just-works pairing, which is what every gamepad and headset
/// uses. Without an agent registered at all, `Device1.Pair` fails outright.
pub fn registerAgent(conn: dbus.Connection) !void {
    agent_conn = conn.handle;
    // Fix round 2, finding M4: this return value was previously discarded.
    // A failure here means `agentMessage` never gets called at all - BlueZ's
    // `RequestConfirmation`/`RequestAuthorization`/etc. callbacks below have
    // nowhere to land - so `Pair` from the UI would just hang with no
    // visible reason, on the single largest untested surface in the project
    // (see task-8-report.md).
    if (c.dbus_connection_register_object_path(conn.handle, agent_path, &agent_vtable, null) == 0) {
        _ = libc.printf("agent: dbus_connection_register_object_path failed\n");
        _ = libc.fflush(null);
        return error.RegisterObjectPathFailed;
    }

    var err = dbus.Error{};
    defer err.deinit();
    const r1 = conn.callArgs("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", &.{ .{ .obj = agent_path }, .{ .str = "NoInputNoOutput" } }, &err) catch |e| {
        _ = libc.printf("agent: RegisterAgent failed: %s (%s)\n", @errorName(e).ptr, err.text());
        _ = libc.fflush(null);
        return e;
    };
    c.dbus_message_unref(r1);
    _ = libc.printf("agent: RegisterAgent succeeded\n");
    _ = libc.fflush(null);

    // Best-effort: BlueZ routes a client's own Pair() calls to whichever
    // agent that same connection registered, so being *default* is not
    // required for our own pairing to work. Something else on the box
    // (bluetoothctl, another agent) may already hold the default slot -
    // if RequestDefaultAgent fails, don't undo the successful RegisterAgent
    // above, or every retry would hit org.bluez.Error.AlreadyExists for the
    // rest of the process's life.
    var err2 = dbus.Error{};
    defer err2.deinit();
    if (conn.callArgs("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent", &.{.{ .obj = agent_path }}, &err2)) |r2| {
        c.dbus_message_unref(r2);
        _ = libc.printf("agent: RequestDefaultAgent succeeded\n");
    } else |e| {
        _ = libc.printf("agent: RequestDefaultAgent failed (best-effort, ignored): %s (%s)\n", @errorName(e).ptr, err2.text());
    }
    _ = libc.fflush(null);
}
