const std = @import("std");
const posix = std.posix;
const gpa = @import("../utils/allocator.zig").gpa;
const log = std.log.scoped(.SpawnControl);
const c = @import("../utils/c.zig");

const Error = @import("../command.zig").Error;

pub fn spawnCmd(
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    log.debug("Attempting to run shell command: {s}", .{args[1]});

    const cmd = [_:null]?[*:0]const u8{ "/bin/sh", "-c", args[1], null };
    const pid = posix.fork() catch |err| {
        log.err("Fork failed: {s}", .{@errorName(err)});

        out.* = try std.fmt.allocPrint(gpa, "fork failed!", .{});
        return Error.OSError;
    };

    if (pid == 0) {
        if (c.setsid() < 0) unreachable;
        if (posix.system.sigprocmask(posix.SIG.SETMASK, &posix.empty_sigset, null) < 0) unreachable;
        const sig_dfl = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &sig_dfl, null) catch |err| {
            log.err("Sigaction failed: {s}", .{@errorName(err)});
            return Error.OSError;
        };

        const pid2 = posix.fork() catch c._exit(1);
        if (pid2 == 0) posix.execveZ("/bin/sh", &cmd, std.c.environ) catch c._exit(1);

        c._exit(0);
    }

    const exit_code = posix.waitpid(pid, 0);
    if (!posix.W.IFEXITED(exit_code.status) or
        (posix.W.IFEXITED(exit_code.status) and posix.W.EXITSTATUS(exit_code.status) != 0))
    {
        out.* = try std.fmt.allocPrint(gpa, "Fork failed", .{});
        return Error.OSError;
    }
}
