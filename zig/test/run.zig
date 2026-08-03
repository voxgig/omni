//! RUN: make test
//! RUN-SOME: ./build/omnitest basic
//!
//! The Fibonacci conformance suite: every omni port runs this same set of
//! groups, from the same spec/fib.json, against the same fib library.
//!
//! No third-party test framework: a failing omni check returns a message,
//! which this harness reports. `zig test` can do the same.

const std = @import("std");
const omni = @import("omni");
const fib = @import("fib.zig");

const Json = omni.Json;

var ALLOC: std.mem.Allocator = undefined;
var ONLY: ?[]const u8 = null;
var PASSCOUNT: usize = 0;
var FAILCOUNT: usize = 0;

// Find the shared spec directory by walking up from the working directory.
fn specfile(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var dir: []const u8 = ".";

    var step: usize = 0;
    while (step < 8) : (step += 1) {
        const cand = try std.fmt.allocPrint(alloc, "{s}/spec/{s}", .{ dir, name });
        const file = std.Io.Dir.cwd().openFile(io, cand, .{}) catch {
            dir = try std.fmt.allocPrint(alloc, "{s}/..", .{dir});
            continue;
        };
        file.close(io);
        return cand;
    }

    return error.SpecNotFound;
}

// ---- subjects --------------------------------------------------------

const ShiftData = struct { shift: f64 };

fn callFib(self: *const omni.Subject, args: []const Json) omni.SubjectResult {
    var val: omni.Maybe = if (0 < args.len) args[0] else null;

    if (self.data) |raw| {
        const data: *const ShiftData = @ptrCast(@alignCast(raw));
        if (omni.asnum(val)) |num| {
            val = omni.jnum(num + data.shift);
        }
    }

    const result = fib.fib(ALLOC, val) catch return .{ .err = "omni: out of memory" };
    return switch (result) {
        .ok => |value| .{ .ok = value },
        .err => |message| .{ .err = message },
    };
}

fn callFibSeq(_: *const omni.Subject, args: []const Json) omni.SubjectResult {
    const result = fib.fibseq(ALLOC, if (0 < args.len) args[0] else null) catch
        return .{ .err = "omni: out of memory" };
    return switch (result) {
        .ok => |value| .{ .ok = value },
        .err => |message| .{ .err = message },
    };
}

fn callFibRange(_: *const omni.Subject, args: []const Json) omni.SubjectResult {
    const result = fib.fibrange(
        ALLOC,
        if (0 < args.len) args[0] else null,
        if (1 < args.len) args[1] else null,
    ) catch return .{ .err = "omni: out of memory" };
    return switch (result) {
        .ok => |value| .{ .ok = value },
        .err => |message| .{ .err = message },
    };
}

fn callFibInfo(_: *const omni.Subject, args: []const Json) omni.SubjectResult {
    const result = fib.fibinfo(ALLOC, if (0 < args.len) args[0] else null) catch
        return .{ .err = "omni: out of memory" };
    return switch (result) {
        .ok => |value| .{ .ok = value },
        .err => |message| .{ .err = message },
    };
}

const FIB = omni.Subject{ .call = callFib };
const FIBSEQ = omni.Subject{ .call = callFibSeq };
const FIBRANGE = omni.Subject{ .call = callFibRange };
const FIBINFO = omni.Subject{ .call = callFibInfo };

// ---- provider --------------------------------------------------------

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
fn providerSubject(self: *const omni.Provider, name: []const u8) ?*const omni.Subject {
    if (std.mem.eql(u8, "fib", name)) {
        const subject = ALLOC.create(omni.Subject) catch return null;
        subject.* = .{ .call = callFib, .data = self.data };
        return subject;
    }
    if (std.mem.eql(u8, "fibseq", name)) return &FIBSEQ;
    if (std.mem.eql(u8, "fibrange", name)) return &FIBRANGE;
    if (std.mem.eql(u8, "fibinfo", name)) return &FIBINFO;
    return null;
}

fn providerClient(_: *const omni.Provider, options: omni.Maybe) *const omni.Provider {
    const shift = omni.asnum(omni.jget(options, "shift")) orelse 0;
    return fibprovider(shift);
}

fn fibprovider(shift: f64) *const omni.Provider {
    const data = ALLOC.create(ShiftData) catch unreachable;
    data.* = .{ .shift = shift };

    const provider = ALLOC.create(omni.Provider) catch unreachable;
    provider.* = .{
        .subject = providerSubject,
        .client = providerClient,
        .data = if (0 == shift) null else data,
    };

    return provider;
}

// ---- harness ---------------------------------------------------------

fn report(name: []const u8, failure: ?[]const u8) void {
    if (failure) |message| {
        FAILCOUNT += 1;
        std.debug.print("FAIL - {s}\n{s}\n", .{ name, message });
    } else {
        PASSCOUNT += 1;
        std.debug.print("ok   - {s}\n", .{name});
    }
}

fn wanted(name: []const u8) bool {
    const only = ONLY orelse return true;
    return std.mem.eql(u8, only, name);
}

fn rungroup(pack: *const omni.RunPack, name: []const u8, subject: *const omni.Subject, flags: omni.Flags) !void {
    if (!wanted(name)) {
        return;
    }
    report(name, try pack.runsetflags(pack.set(name), flags, subject));
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
fn badspec(alloc: std.mem.Allocator) !Json {
    return omni.jmap(alloc, &.{
        .{ "fib", try omni.jmap(alloc, &.{
            .{ "wrongout", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(5) },
                        .{ "out", omni.jnum(5) },
                    }),
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "out", omni.jnum(999) },
                    }),
                }) },
            }) },
            .{ "wrongerr", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(1) },
                        .{ "err", omni.jstr("never happens") },
                    }),
                }) },
            }) },
            .{ "wrongmatch", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{.{ "out", omni.jnum(999) }}) },
                    }),
                }) },
            }) },
            .{ "missing", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{
                                .{ "nope", omni.jstr("__EXISTS__") },
                            }) },
                        }) },
                    }),
                }) },
            }) },
            // A concrete match leaf against a missing key must fail, not
            // substring-match the text "undefined".
            .{ "matchabsent", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{
                                .{ "nope", omni.jstr("fine") },
                            }) },
                        }) },
                    }),
                }) },
            }) },
            // __UNDEF__ (absent) must not be satisfied by a present null.
            .{ "undefonnull", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(0) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{
                                .{ "prev", omni.jstr("__UNDEF__") },
                            }) },
                        }) },
                    }),
                }) },
            }) },
            // __NULL__ (present null) must not be satisfied by an absent key.
            .{ "nullonabsent", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{
                                .{ "nope", omni.jstr("__NULL__") },
                            }) },
                        }) },
                    }),
                }) },
            }) },
            // An empty container asserts an empty container, not "anything".
            .{ "emptymatch", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{}) },
                        }) },
                    }),
                }) },
            }) },
            // An empty-string leaf matches only an empty string, not "anything".
            .{ "emptystr", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "match", try omni.jmap(alloc, &.{
                            .{ "out", try omni.jmap(alloc, &.{
                                .{ "label", omni.jstr("") },
                            }) },
                        }) },
                    }),
                }) },
            }) },
        }) },
    });
}

fn expectfail(label: []const u8, setname: []const u8, subject: *const omni.Subject) !void {
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const runner = omni.makeRunnerSpec(ALLOC, try badspec(ALLOC), empty);
    const pack = try runner.runner("fib", null);

    const failure = try pack.runset(pack.set(setname), subject);

    report(label, if (null == failure) "omni: expected a failure, got none" else null);
}

fn checkmessage() !void {
    const label = "reports entry index and id";
    if (!wanted(label)) {
        return;
    }

    const spec = try omni.jmap(ALLOC, &.{
        .{ "fib", try omni.jmap(ALLOC, &.{
            .{ "g", try omni.jmap(ALLOC, &.{
                .{ "set", try omni.jlist(ALLOC, &.{
                    try omni.jmap(ALLOC, &.{
                        .{ "in", omni.jnum(1) },
                        .{ "out", omni.jnum(1) },
                    }),
                    try omni.jmap(ALLOC, &.{
                        .{ "id", omni.jstr("x#2") },
                        .{ "in", omni.jnum(2) },
                        .{ "out", omni.jnum(42) },
                    }),
                }) },
            }) },
        }) },
    });

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const runner = omni.makeRunnerSpec(ALLOC, spec, empty);
    const pack = try runner.runner("fib", null);

    const failure = try pack.runset(pack.set("g"), &FIB);

    const message = failure orelse {
        report(label, "omni: expected a failure, got none");
        return;
    };

    for ([_][]const u8{ "fib[1] (x#2)", "expected: 42", "actual:   1" }) |want| {
        if (null == std.mem.indexOf(u8, message, want)) {
            report(label, message);
            return;
        }
    }

    report(label, null);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    ALLOC = arena.allocator();

    var argit = std.process.Args.Iterator.init(init.minimal.args);
    _ = argit.skip();
    if (argit.next()) |first| {
        ONLY = first;
    }

    const path = try specfile(ALLOC, init.io, "fib.json");
    const runner = try omni.makeRunner(ALLOC, init.io, path, fibprovider(0));
    const pack = try runner.runner("fib", null);

    try rungroup(&pack, "basic", &FIB, .{});
    try rungroup(&pack, "seq", &FIBSEQ, .{});
    try rungroup(&pack, "range", &FIBRANGE, .{});
    try rungroup(&pack, "info", &FIBINFO, .{});
    try rungroup(&pack, "nulls", &FIBINFO, omni.Flags.nonull());
    try rungroup(&pack, "error", &FIB, .{});
    try rungroup(&pack, "match", &FIB, .{});
    try rungroup(&pack, "matchinfo", &FIBINFO, .{});
    try rungroup(&pack, "client", &FIB, .{});

    try expectfail("detects wrong result", "wrongout", &FIB);
    try expectfail("detects missing error", "wrongerr", &FIB);
    try expectfail("detects failed match", "wrongmatch", &FIB);
    try expectfail("detects absent key", "missing", &FIBINFO);
    try expectfail("a concrete match leaf does not match a missing key", "matchabsent", &FIBINFO);
    try expectfail("__UNDEF__ does not match a present null", "undefonnull", &FIBINFO);
    try expectfail("__NULL__ does not match an absent key", "nullonabsent", &FIBINFO);
    try expectfail("an empty match container is not vacuous", "emptymatch", &FIBINFO);
    try expectfail("an empty-string match leaf is not a wildcard", "emptystr", &FIBINFO);
    try checkmessage();

    std.debug.print("\n{d} passed, {d} failed\n", .{ PASSCOUNT, FAILCOUNT });

    std.process.exit(if (0 == FAILCOUNT) 0 else 1);
}
