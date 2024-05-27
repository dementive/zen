const xkb = @import("xkbcommon");
const Server = @import("../server.zig");
const View = @import("../view.zig");

// For the full list of all key codes see xkb.Keysym
fn handleKeybind(server: *Server, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        // Exit the compositor
        xkb.Keysym.Escape => server.wl_server.terminate(),
        // Focus the next view in the stack, pushing the current top to the back
        xkb.Keysym.F1 => {
            if (server.views.length() < 2) return true;
            const view: *View = @fieldParentPtr("link", server.views.link.prev.?);
            server.focusView(view, view.xdg_surface.surface);
        },
        // Open alacritty
        xkb.Keysym.Space => {
            server.seat.runCommand([_][]const u8{ "spawn", "alacritty" });
        },
        xkb.Keysym.f => {
            server.seat.runCommand([_][]const u8{ "spawn", "alacritty" });
        },
        xkb.Keysym.D => {
            server.seat.runCommand([_][]const u8{ "spawn", "alacritty" });
        },
        else => return false,
    }
    return true;
}
