const View = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("server.zig");
const gpa = @import("utils/allocator.zig").gpa;

server: *Server,
link: wl.list.Link = undefined,
xdg_surface: *wlr.XdgSurface,
scene_tree: *wlr.SceneTree,

x: i32 = 0,
y: i32 = 0,

map: wl.Listener(void) = wl.Listener(void).init(map),
unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = wl.Listener(*wlr.XdgToplevel.event.Move).init(requestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = wl.Listener(*wlr.XdgToplevel.event.Resize).init(requestResize),

fn map(listener: *wl.Listener(void)) void {
    const view: *View = @fieldParentPtr("map", listener);
    view.server.views.prepend(view);
    view.server.focusView(view, view.xdg_surface.surface);
}

fn unmap(listener: *wl.Listener(void)) void {
    const view: *View = @fieldParentPtr("unmap", listener);
    view.link.remove();
}

fn destroy(listener: *wl.Listener(void)) void {
    const view: *View = @fieldParentPtr("destroy", listener);

    view.map.link.remove();
    view.unmap.link.remove();
    view.destroy.link.remove();
    view.request_move.link.remove();
    view.request_resize.link.remove();

    gpa.destroy(view);
}

fn requestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    _: *wlr.XdgToplevel.event.Move,
) void {
    const view: *View = @fieldParentPtr("request_move", listener);
    const server = view.server;
    server.grabbed_view = view;
    server.cursor_mode = .move;
    server.grab_x = server.cursor.x - @as(f64, @floatFromInt(view.x));
    server.grab_y = server.cursor.y - @as(f64, @floatFromInt(view.y));
}

fn requestResize(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
    event: *wlr.XdgToplevel.event.Resize,
) void {
    const view: *View = @fieldParentPtr("request_resize", listener);
    const server = view.server;

    server.grabbed_view = view;
    server.cursor_mode = .resize;
    server.resize_edges = event.edges;

    var box: wlr.Box = undefined;
    view.xdg_surface.getGeometry(&box);

    const border_x = view.x + box.x + if (event.edges.right) box.width else 0;
    const border_y = view.y + box.y + if (event.edges.bottom) box.height else 0;
    server.grab_x = server.cursor.x - @as(f64, @floatFromInt(border_x));
    server.grab_y = server.cursor.y - @as(f64, @floatFromInt(border_y));

    server.grab_box = box;
    server.grab_box.x += view.x;
    server.grab_box.y += view.y;
}
