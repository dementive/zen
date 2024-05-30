const Server = @This();

const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const gpa = @import("utils/allocator.zig").gpa;
const command = @import("command.zig");
const View = @import("view.zig");
const Keyboard = @import("keyboard.zig");
const Output = @import("output.zig");

wl_server: *wl.Server,
sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,

shm: *wlr.Shm,
drm: ?*wlr.Drm = null,
linux_dmabuf: ?*wlr.LinuxDmabufV1 = null,
single_pixel_buffer_manager: *wlr.SinglePixelBufferManagerV1,

viewporter: *wlr.Viewporter,
fractional_scale_manager: *wlr.FractionalScaleManagerV1,
compositor: *wlr.Compositor,
subcompositor: *wlr.Subcompositor,

backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,

output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(newOutput),

xdg_shell: *wlr.XdgShell,
//xdg_decoration_manager: *wlr.XdgDecorationManagerV1, // TODO
//layer_shell: *wlr.LayerShellV1, // TODO
xdg_activation: *wlr.XdgActivationV1,

data_device_manager: *wlr.DataDeviceManager,
primary_selection_manager: *wlr.PrimarySelectionDeviceManagerV1,
data_control_manager: *wlr.DataControlManagerV1,
export_dmabuf_manager: *wlr.ExportDmabufManagerV1,
screencopy_manager: *wlr.ScreencopyManagerV1,
foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,

views: wl.list.Head(View, .link) = undefined,
seat: *wlr.Seat,
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

new_xdg_surface: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(newXdgSurface),
// new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleNewToplevelDecoration),
// new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleNewLayerSurface),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) =
    wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(handleRequestActivate),

pub fn init(server: *Server) !void {
    const wl_server = try wl.Server.create();
    const backend = try wlr.Backend.autocreate(wl_server, null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create();
    const scene = try wlr.Scene.create();
    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);
    const loop = wl_server.getEventLoop();

    server.* = .{
        .wl_server = wl_server,
        .sigint_source = try loop.addSignal(*wl.Server, posix.SIG.INT, terminate, wl_server),
        .sigterm_source = try loop.addSignal(*wl.Server, posix.SIG.TERM, terminate, wl_server),
        .backend = backend,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),

        .shm = try wlr.Shm.createWithRenderer(wl_server, 1, renderer),
        .single_pixel_buffer_manager = try wlr.SinglePixelBufferManagerV1.create(wl_server),

        .viewporter = try wlr.Viewporter.create(wl_server),
        .fractional_scale_manager = try wlr.FractionalScaleManagerV1.create(wl_server, 1),
        .compositor = compositor,
        .subcompositor = try wlr.Subcompositor.create(wl_server),

        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),

        .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
        //.xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server),
        //.layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
        .xdg_activation = try wlr.XdgActivationV1.create(wl_server),

        .data_device_manager = try wlr.DataDeviceManager.create(wl_server),
        .primary_selection_manager = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server),
        .data_control_manager = try wlr.DataControlManagerV1.create(wl_server),
        .export_dmabuf_manager = try wlr.ExportDmabufManagerV1.create(wl_server),
        .screencopy_manager = try wlr.ScreencopyManagerV1.create(wl_server),
        .foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(wl_server),

        .seat = try wlr.Seat.create(wl_server, "default"),
        .cursor = try wlr.Cursor.create(),
        .cursor_mgr = try wlr.XcursorManager.create(null, 24),
    };

    if (renderer.getDmabufFormats() != null and renderer.getDrmFd() >= 0) {
        server.drm = try wlr.Drm.create(wl_server, renderer);
        server.linux_dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer);
    }

    // if (build_options.xwayland and runtime_xwayland) {
    //     server.xwayland = try wlr.Xwayland.create(wl_server, compositor, false);
    //     server.xwayland.?.events.new_surface.add(&server.new_xwayland_surface);
    // }

    //try server.renderer.initServer(wl_server);
    _ = try wlr.DataDeviceManager.create(server.wl_server);

    server.backend.events.new_output.add(&server.new_output);

    server.xdg_shell.events.new_surface.add(&server.new_xdg_surface);
    //server.xdg_decoration_manager.events.new_toplevel_decoration.add(&server.new_toplevel_decoration);
    //server.layer_shell.events.new_surface.add(&server.new_layer_surface);
    server.xdg_activation.events.request_activate.add(&server.request_activate);
    server.views.init();

    server.backend.events.new_input.add(&server.new_input);
    server.seat.events.request_set_cursor.add(&server.request_set_cursor);
    server.seat.events.request_set_selection.add(&server.request_set_selection);
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
    server.sigint_source.remove();
    server.sigterm_source.remove();

    server.new_xdg_surface.link.remove();
    server.wl_server.destroyClients();
    server.wl_server.destroy();
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

/// Handle SIGINT and SIGTERM by gracefully stopping the server
fn terminate(_: c_int, wl_server: *wl.Server) c_int {
    wl_server.terminate();
    return 0;
}

fn newXdgSurface(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const server: *Server = @fieldParentPtr("new_xdg_surface", listener);

    switch (xdg_surface.role) {
        .toplevel => {
            // Don't add the view to server.views until it is mapped
            const view = gpa.create(View) catch {
                std.log.err("failed to allocate new view", .{});
                return;
            };

            view.* = .{
                .server = server,
                .xdg_surface = xdg_surface,
                .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
                    gpa.destroy(view);
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

// fn handleNewToplevelDecoration(
//     _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
//     _: *wlr.XdgToplevelDecorationV1,
// ) void {
//     return;
//     // TODO
//     //XdgDecoration.init(wlr_decoration);
// }

// fn handleNewLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
//     const server: *Server = @fieldParentPtr("new_layer_surface", listener);

//     std.log.debug(
//         "new layer surface: namespace {s}, layer {s}, anchor {b:0>4}, size {},{}, margin {},{},{},{}, exclusive_zone {}",
//         .{
//             wlr_layer_surface.namespace,
//             @tagName(wlr_layer_surface.current.layer),
//             @as(u32, @bitCast(wlr_layer_surface.current.anchor)),
//             wlr_layer_surface.current.desired_width,
//             wlr_layer_surface.current.desired_height,
//             wlr_layer_surface.current.margin.top,
//             wlr_layer_surface.current.margin.right,
//             wlr_layer_surface.current.margin.bottom,
//             wlr_layer_surface.current.margin.left,
//             wlr_layer_surface.current.exclusive_zone,
//         },
//     );

//     // If the new layer surface does not have an output assigned to it, use the
//     // first output or close the surface if none are available.
//     if (wlr_layer_surface.output == null) {
//         const output = server.input_manager.defaultSeat().focused_output orelse {
//             std.log.err("no output available for layer surface '{s}'", .{wlr_layer_surface.namespace});
//             wlr_layer_surface.destroy();
//             return;
//         };

//         std.log.debug("new layer surface had null output, assigning it to output '{s}'", .{output.wlr_output.name});
//         wlr_layer_surface.output = output.wlr_output;
//     }

//     // TODO
//     // LayerSurface.create(wlr_layer_surface) catch {
//     //     wlr_layer_surface.resource.postNoMemory();
//     //     return;
//     // };
// }

fn handleRequestActivate(
    _: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    _: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    return;
    // TODO
    // const server: *Server = @fieldParentPtr("request_activate", listener);

    // const node_data = SceneNodeData.fromSurface(event.surface) orelse return;
    // switch (node_data.data) {
    //     .view => |view| if (view.pending.focus == 0) {
    //         view.pending.urgent = true;
    //         server.root.applyPending();
    //     },
    //     else => |tag| {
    //         log.info("ignoring xdg-activation-v1 activate request of {s} surface", .{@tagName(tag)});
    //     },
    // }
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

pub fn focusView(server: *Server, view: *View, surface: *wlr.Surface) void {
    if (server.seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    view.scene_tree.node.raiseToTop();
    view.link.remove();
    server.views.prepend(view);

    _ = view.xdg_surface.role_data.toplevel.?.setActivated(true);

    const wlr_keyboard = server.seat.getKeyboard() orelse return;
    server.seat.keyboardNotifyEnter(
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

    server.seat.setCapabilities(.{
        .pointer = true,
        .keyboard = server.keyboards.length() > 0,
    });
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const server: *Server = @fieldParentPtr("request_set_cursor", listener);
    if (event.seat_client == server.seat.pointer_state.focused_client)
        server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const server: *Server = @fieldParentPtr("request_set_selection", listener);
    server.seat.setSelection(event.source, event.serial);
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
            server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
        } else {
            server.cursor.setXcursor(server.cursor_mgr, "default");
            server.seat.pointerClearFocus();
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
    _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
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
    server.seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
    );
}

fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const server: *Server = @fieldParentPtr("cursor_frame", listener);
    server.seat.pointerNotifyFrame();
}

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
pub fn handleKeybind(server: *Server, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        // Exit the compositor
        xkb.Keysym.Escape => {
            std.debug.print("Goodbye World!\n", .{});
            server.wl_server.terminate();
        },
        xkb.Keysym.F5 => {
            var output: ?[]const u8 = null;
            defer if (output) |s| gpa.free(s);
            const args = [_][:0]const u8{ "spawn", "alacritty" };
            command.run(&args, &output) catch |err| {
                std.debug.print("Error: {s}", .{command.errToMsg(err)});
                return false;
                // const failure_message = switch (err) {
                //     command.Error.OutOfMemory => {
                //         //callback.getClient().postNoMemory();
                //         std.log.info("Error: {s}", .{command.errToMsg(err)});
                //     },
                //     else => std.log.info("Error: {s}", .{command.errToMsg(err)}),
                // };
                // std.log.info("Error: {s}", .{failure_message});
                //callback.sendFailure(failure_message);
                //return false;
            };
        },
        else => return false,
    }
    return true;
}
