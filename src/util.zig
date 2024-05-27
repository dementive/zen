const std = @import("std");

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;
