//! The system under test: a tiny Fibonacci library.
//!
//! Every omni port ships this same library, with the same behaviour and
//! the same error messages, and tests it with the same spec file
//! (spec/fib.json).

const std = @import("std");
const omni = @import("omni");

const Json = omni.Json;

/// What a fib call returns: a value, or the message of a failure. A
/// subject never reports failure the way the runner does.
pub const FibResult = union(enum) {
    ok: Json,
    err: []const u8,
};

/// Validate a Fibonacci index. The spec matches on these messages.
pub fn fibindex(alloc: std.mem.Allocator, val: omni.Maybe) !union(enum) { ok: i64, err: []const u8 } {
    const num = omni.asnum(val) orelse {
        return .{ .err = try std.fmt.allocPrint(
            alloc,
            "fib: not a number: {s}",
            .{try omni.stringify(alloc, val)},
        ) };
    };

    if (num != @trunc(num)) {
        return .{ .err = try std.fmt.allocPrint(
            alloc,
            "fib: non-integer index: {s}",
            .{try omni.stringify(alloc, val)},
        ) };
    }

    if (0 > num) {
        return .{ .err = try std.fmt.allocPrint(
            alloc,
            "fib: negative index: {s}",
            .{try omni.stringify(alloc, val)},
        ) };
    }

    return .{ .ok = @intFromFloat(num) };
}

/// The nth Fibonacci number: fib(0)=0, fib(1)=1.
pub fn fibnum(index: i64) i64 {
    if (0 == index) {
        return 0;
    }

    var prev: i64 = 0;
    var cur: i64 = 1;
    var step: i64 = 1;

    while (step < index) : (step += 1) {
        const next = prev + cur;
        prev = cur;
        cur = next;
    }

    return cur;
}

pub fn fib(alloc: std.mem.Allocator, val: omni.Maybe) !FibResult {
    switch (try fibindex(alloc, val)) {
        .err => |message| return .{ .err = message },
        .ok => |index| return .{ .ok = omni.jnum(@floatFromInt(fibnum(index))) },
    }
}

/// The first n Fibonacci numbers.
pub fn fibseq(alloc: std.mem.Allocator, val: omni.Maybe) !FibResult {
    const count = switch (try fibindex(alloc, val)) {
        .err => |message| return .{ .err = message },
        .ok => |index| index,
    };

    var out = std.json.Array.init(alloc);
    var index: i64 = 0;
    while (index < count) : (index += 1) {
        try out.append(omni.jnum(@floatFromInt(fibnum(index))));
    }

    return .{ .ok = .{ .array = out } };
}

/// The Fibonacci numbers from index start to index end, inclusive.
pub fn fibrange(alloc: std.mem.Allocator, start: omni.Maybe, stop: omni.Maybe) !FibResult {
    const from = switch (try fibindex(alloc, start)) {
        .err => |message| return .{ .err = message },
        .ok => |index| index,
    };

    const upto = switch (try fibindex(alloc, stop)) {
        .err => |message| return .{ .err = message },
        .ok => |index| index,
    };

    var out = std.json.Array.init(alloc);
    var index = from;
    while (index <= upto) : (index += 1) {
        try out.append(omni.jnum(@floatFromInt(fibnum(index))));
    }

    return .{ .ok = .{ .array = out } };
}

/// A description of the nth Fibonacci number. `prev` is null at index 0,
/// which exercises the runner's null handling.
pub fn fibinfo(alloc: std.mem.Allocator, val: omni.Maybe) !FibResult {
    const index = switch (try fibindex(alloc, val)) {
        .err => |message| return .{ .err = message },
        .ok => |found| found,
    };

    const num = fibnum(index);

    const label = try std.fmt.allocPrint(alloc, "fib({s})={s}", .{
        try omni.numstr(alloc, @floatFromInt(index)),
        try omni.numstr(alloc, @floatFromInt(num)),
    });

    const out = try omni.jmap(alloc, &.{
        .{ "n", omni.jnum(@floatFromInt(index)) },
        .{ "val", omni.jnum(@floatFromInt(num)) },
        .{ "even", omni.jbool(0 == @mod(num, 2)) },
        .{ "prev", if (0 == index) Json{ .null = {} } else omni.jnum(@floatFromInt(fibnum(index - 1))) },
        .{ "label", omni.jstr(label) },
    });

    return .{ .ok = out };
}
