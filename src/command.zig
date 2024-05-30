const std = @import("std");
const assert = std.debug.assert;

const spawn = @import("commands/spawn.zig");

pub const Error = error{
    NoCommand,
    NotEnoughArguments,
    OutOfMemory,
    TooManyArguments,
    UnknownCommand,
    UnknownOption,
    OSError,
};

const commands = std.ComptimeStringMap(
    *const fn ([]const [:0]const u8, *?[]const u8) Error!void,
    .{
        .{ "spawn", spawn.spawnCmd },
    },
);

pub fn run(
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    assert(out.* == null);
    if (args.len == 0) return Error.NoCommand;
    const func = commands.get(args[0]) orelse return Error.UnknownCommand;
    try func(args, out);
}

pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "No command provided\n",
        Error.NotEnoughArguments => "Not enough arguments provided\n",
        Error.OutOfMemory => "Out of memory\n",
        Error.TooManyArguments => "Too many arguments\n",
        Error.UnknownOption => "Unknown option\n",
        Error.UnknownCommand => "Unknown command\n",
        Error.OSError => "OS error\n",
    };
}
