const std = @import("std");
const assert = std.debug.assert;

const Seat = @import("Seat.zig");

pub const Direction = enum {
    next,
    previous,
};

pub const PhysicalDirection = enum {
    up,
    down,
    left,
    right,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

// zig fmt: off
const command_impls = std.ComptimeStringMap(
    *const fn (*Seat, []const [:0]const u8, *?[]const u8) Error!void,
    .{
        .{ "spawn",                     @import("commands/spawn.zig").spawn },
    },
);
// zig fmt: on

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    OutOfBounds,
    Overflow,
    InvalidButton,
    InvalidCharacter,
    InvalidDirection,
    InvalidGlob,
    InvalidPhysicalDirection,
    InvalidOutputIndicator,
    InvalidOrientation,
    InvalidRgba,
    InvalidValue,
    CannotReadFile,
    CannotParseFile,
    UnknownOption,
    ConflictingOptions,
    OutOfMemory,
    Other,
};

/// Run a command for the given Seat. The `args` parameter is similar to the
/// classic argv in that the command to be run is passed as the first argument.
/// The optional slice passed as the out parameter must initially be set to
/// null. If the command produces output or Error.Other is returned, the slice
/// will be set to the output of the command or a failure message, respectively.
/// The caller is then responsible for freeing that slice, which will be
/// allocated using the provided allocator.
pub fn run(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    assert(out.* == null);
    if (args.len == 0) return Error.NoCommand;
    const impl_fn = command_impls.get(args[0]) orelse return Error.UnknownCommand;
    try impl_fn(seat, args, out);
}

/// Return a short error message for the given error. Passing Error.Other is invalid.
pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "no command given",
        Error.UnknownCommand => "unknown command",
        Error.UnknownOption => "unknown option",
        Error.ConflictingOptions => "options conflict",
        Error.NotEnoughArguments => "not enough arguments",
        Error.TooManyArguments => "too many arguments",
        Error.OutOfBounds, Error.Overflow => "value out of bounds",
        Error.InvalidButton => "invalid button",
        Error.InvalidCharacter => "invalid character in argument",
        Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
        Error.InvalidGlob => "invalid glob. '*' is only allowed as the first and/or last character",
        Error.InvalidPhysicalDirection => "invalid direction. Must be 'up', 'down', 'left' or 'right'",
        Error.InvalidOutputIndicator => "invalid indicator for an output. Must be 'next', 'previous', 'up', 'down', 'left', 'right' or a valid output name",
        Error.InvalidOrientation => "invalid orientation. Must be 'horizontal', or 'vertical'",
        Error.InvalidRgba => "invalid color format, must be hexadecimal 0xRRGGBB or 0xRRGGBBAA",
        Error.InvalidValue => "invalid value",
        Error.CannotReadFile => "cannot read file",
        Error.CannotParseFile => "cannot parse file",
        Error.OutOfMemory => "out of memory",
        Error.Other => unreachable,
    };
}
