const std = @import("std");
const posix = std.posix;

const c = @import("../c.zig");
const util = @import("../util.zig");
const process = @import("../process.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Spawn a program.
pub fn spawn(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", args[1], null };

    const pid = posix.fork() catch {
        out.* = try std.fmt.allocPrint(util.gpa, "fork/execve failed", .{});
        return Error.Other;
    };

    if (pid == 0) {
        process.cleanupChild();

        const pid2 = posix.fork() catch c._exit(1);
        if (pid2 == 0) {
            posix.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }

        c._exit(0);
    }

    // Wait the intermediate child.
    const ret = posix.waitpid(pid, 0);
    if (!posix.W.IFEXITED(ret.status) or
        (posix.W.IFEXITED(ret.status) and posix.W.EXITSTATUS(ret.status) != 0))
    {
        out.* = try std.fmt.allocPrint(util.gpa, "fork/execve failed", .{});
        return Error.Other;
    }
}
