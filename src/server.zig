const Server = @This();

const build_options = @import("build_options");
const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const View = @import("view.zig");
const Seat = @import("Seat.zig");
const Keyboard = @import("keyboard.zig");
const Output = @import("output.zig");
const util = @import("util.zig");
const Keybinding = @import("config/keybinds.zig");
const c = @import("c.zig");

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,

output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(newOutput),

xdg_shell: *wlr.XdgShell,
new_xdg_surface: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(newXdgSurface),
views: wl.list.Head(View, .link) = undefined,

seat: *Seat,
new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(newInput),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = wl.Listener(*wlr.Seat.event.RequestSetCursor).init(requestSetCursor),
request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = wl.Listener(*wlr.Seat.event.RequestSetSelection).init(requestSetSelection),
keyboards: wl.list.Head(Keyboard, .link) = undefined,

cursor: *wlr.Cursor,
cursor_mgr: *wlr.XcursorManager,
cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = wl.Listener(*wlr.Pointer.event.Motion).init(cursorMotion),
cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(cursorMotionAbsolute),
cursor_button: wl.Listener(*wlr.Pointer.event.Button) = wl.Listener(*wlr.Pointer.event.Button).init(cursorButton),
cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(cursorAxis),
cursor_frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(cursorFrame),

cursor_mode: enum { passthrough, move, resize } = .passthrough,
grabbed_view: ?*View = null,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_box: wlr.Box = undefined,
resize_edges: wlr.Edges = .{},

pub fn init(server: *Server) !void {
    const wl_server = try wl.Server.create();
    const backend = try wlr.Backend.autocreate(wl_server, null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create();
    const scene = try wlr.Scene.create();
    server.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),
        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),
        .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
        .cursor = try wlr.Cursor.create(),
        .cursor_mgr = try wlr.XcursorManager.create(null, 24),
    };

    try server.renderer.initServer(wl_server);

    _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
    _ = try wlr.Subcompositor.create(server.wl_server);
    _ = try wlr.DataDeviceManager.create(server.wl_server);

    server.backend.events.new_output.add(&server.new_output);

    server.xdg_shell.events.new_surface.add(&server.new_xdg_surface);
    server.views.init();

    server.backend.events.new_input.add(&server.new_input);
    server.seat.wlr_seat.events.request_set_cursor.add(&server.request_set_cursor);
    server.seat.wlr_seat.events.request_set_selection.add(&server.request_set_selection);
    server.keyboards.init();

    server.cursor.attachOutputLayout(server.output_layout);
    try server.cursor_mgr.load(1);
    server.cursor.events.motion.add(&server.cursor_motion);
    server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
    server.cursor.events.button.add(&server.cursor_button);
    server.cursor.events.axis.add(&server.cursor_axis);
    server.cursor.events.frame.add(&server.cursor_frame);
}

pub fn deinit(server: *Server) void {
    server.wl_server.destroyClients();
    server.wl_server.destroy();
}

/// Create the socket, start the backend, and setup the environment
pub fn start(server: Server) !void {
    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);
    try server.backend.start();
    // TODO: don't use libc's setenv
    if (c.setenv("WAYLAND_DISPLAY", socket.ptr, 1) < 0) return error.SetenvError;
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (c.setenv("DISPLAY", xwayland.display_name, 1) < 0) return error.SetenvError;
        }
    }
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const server: *Server = @fieldParentPtr("new_output", listener);

    if (!wlr_output.initRender(server.allocator, server.renderer)) return;

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    if (wlr_output.preferredMode()) |mode| {
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) return;

    Output.create(server, wlr_output) catch {
        std.log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

fn newXdgSurface(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const server: *Server = @fieldParentPtr("new_xdg_surface", listener);

    switch (xdg_surface.role) {
        .toplevel => {
            // Don't add the view to server.views until it is mapped
            const view = util.gpa.create(View) catch {
                std.log.err("failed to allocate new view", .{});
                return;
            };

            view.* = .{
                .server = server,
                .xdg_surface = xdg_surface,
                .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
                    util.gpa.destroy(view);
                    std.log.err("failed to allocate new view", .{});
                    return;
                },
            };
            view.scene_tree.node.data = @intFromPtr(view);
            xdg_surface.data = @intFromPtr(view.scene_tree);

            xdg_surface.surface.events.map.add(&view.map);
            xdg_surface.surface.events.unmap.add(&view.unmap);
            xdg_surface.events.destroy.add(&view.destroy);
            xdg_surface.role_data.toplevel.?.events.request_move.add(&view.request_move);
            xdg_surface.role_data.toplevel.?.events.request_resize.add(&view.request_resize);
        },
        .popup => {
            // These asserts are fine since tinywl.zig doesn't support anything else that can
            // make xdg popups (e.g. layer shell).
            const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_surface.role_data.popup.?.parent.?) orelse return;
            const parent_tree = @as(?*wlr.SceneTree, @ptrFromInt(parent.data)) orelse {
                // The xdg surface user data could be left null due to allocation failure.
                return;
            };
            const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
                std.log.err("failed to allocate xdg popup node", .{});
                return;
            };
            xdg_surface.data = @intFromPtr(scene_tree);
        },
        .none => unreachable,
    }
}

const ViewAtResult = struct {
    view: *View,
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
};

fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (@as(?*View, @ptrFromInt(n.node.data))) |view| {
                return ViewAtResult{
                    .view = view,
                    .surface = scene_surface.surface,
                    .sx = sx,
                    .sy = sy,
                };
            }
        }
    }
    return null;
}

fn focusView(server: *Server, view: *View, surface: *wlr.Surface) void {
    if (server.seat.wlr_seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    view.scene_tree.node.raiseToTop();
    view.link.remove();
    server.views.prepend(view);

    _ = view.xdg_surface.role_data.toplevel.?.setActivated(true);

    const wlr_keyboard = server.seat.wlr_seat.getKeyboard() orelse return;
    server.seat.wlr_seat.keyboardNotifyEnter(
        surface,
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const server: *Server = @fieldParentPtr("new_input", listener);
    switch (device.type) {
        .keyboard => Keyboard.create(server, device) catch |err| {
            std.log.err("failed to create keyboard: {}", .{err});
            return;
        },
        .pointer => server.cursor.attachInputDevice(device),
        else => {},
    }

    server.seat.wlr_seat.setCapabilities(.{
        .pointer = true,
        .keyboard = server.keyboards.length() > 0,
    });
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const server: *Server = @fieldParentPtr("request_set_cursor", listener);
    if (event.seat_client == server.seat.wlr_seat.pointer_state.focused_client)
        server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const server: *Server = @fieldParentPtr("request_set_selection", listener);
    server.seat.wlr_seat.setSelection(event.source, event.serial);
}

fn cursorMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const server: *Server = @fieldParentPtr("cursor_motion", listener);
    server.cursor.move(event.device, event.delta_x, event.delta_y);
    server.processCursorMotion(event.time_msec);
}

fn cursorMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
    server.cursor.warpAbsolute(event.device, event.x, event.y);
    server.processCursorMotion(event.time_msec);
}

fn processCursorMotion(server: *Server, time_msec: u32) void {
    switch (server.cursor_mode) {
        .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.seat.wlr_seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            server.seat.wlr_seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
        } else {
            server.cursor.setXcursor(server.cursor_mgr, "default");
            server.seat.wlr_seat.pointerClearFocus();
        },
        .move => {
            const view = server.grabbed_view.?;
            view.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
            view.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));
            view.scene_tree.node.setPosition(view.x, view.y);
        },
        .resize => {
            const view = server.grabbed_view.?;
            const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
            const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

            var new_left = server.grab_box.x;
            var new_right = server.grab_box.x + server.grab_box.width;
            var new_top = server.grab_box.y;
            var new_bottom = server.grab_box.y + server.grab_box.height;

            if (server.resize_edges.top) {
                new_top = border_y;
                if (new_top >= new_bottom)
                    new_top = new_bottom - 1;
            } else if (server.resize_edges.bottom) {
                new_bottom = border_y;
                if (new_bottom <= new_top)
                    new_bottom = new_top + 1;
            }

            if (server.resize_edges.left) {
                new_left = border_x;
                if (new_left >= new_right)
                    new_left = new_right - 1;
            } else if (server.resize_edges.right) {
                new_right = border_x;
                if (new_right <= new_left)
                    new_right = new_left + 1;
            }

            var geo_box: wlr.Box = undefined;
            view.xdg_surface.getGeometry(&geo_box);
            view.x = new_left - geo_box.x;
            view.y = new_top - geo_box.y;
            view.scene_tree.node.setPosition(view.x, view.y);

            const new_width = new_right - new_left;
            const new_height = new_bottom - new_top;
            _ = view.xdg_surface.role_data.toplevel.?.setSize(new_width, new_height);
        },
    }
}

fn cursorButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const server: *Server = @fieldParentPtr("cursor_button", listener);
    _ = server.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    if (event.state == .released) {
        server.cursor_mode = .passthrough;
    } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
        server.focusView(res.view, res.surface);
    }
}

fn cursorAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const server: *Server = @fieldParentPtr("cursor_axis", listener);
    server.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
    );
}

fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const server: *Server = @fieldParentPtr("cursor_frame", listener);
    server.seat.wlr_seat.pointerNotifyFrame();
}

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
fn handleKeybind(server: *Server, key: xkb.Keysym) bool {
    Keybinding.handleKeybind(server, key);
}
