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

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec
// can pin both with an ordinary `out` comparison.
fn callFibCtx(_: *const omni.Subject, args: []const Json) omni.SubjectResult {
    const ctx: omni.Maybe = if (0 < args.len) args[0] else null;
    const n = omni.jget(ctx, "n");

    const result = fib.fib(ALLOC, n) catch return .{ .err = "omni: out of memory" };
    const val = switch (result) {
        .ok => |value| value,
        .err => |message| return .{ .err = message },
    };

    const out = omni.jmap(ALLOC, &.{
        .{ "n", n orelse Json{ .null = {} } },
        .{ "val", val },
        .{ "mark", omni.jget(ctx, "mark") orelse Json{ .null = {} } },
        .{ "hasclient", omni.jbool(!omni.isnone(omni.jget(ctx, "client"))) },
    }) catch return .{ .err = "omni: out of memory" };

    return .{ .ok = out };
}

const FIBCTX = omni.Subject{ .call = callFibCtx };

// Returns the UNDEFMARK string as ordinary data. The __UNDEF__ sentinel
// asserts a key is absent, so it must reject this - otherwise two mutually
// exclusive states (absent, and present-with-that-text) pass one check.
fn callFibUndefLit(_: *const omni.Subject, _: []const Json) omni.SubjectResult {
    const out = omni.jmap(ALLOC, &.{
        .{ "a", omni.jstr(omni.UNDEFMARK) },
    }) catch return .{ .err = "omni: out of memory" };

    return .{ .ok = out };
}

const FIBUNDEFLIT = omni.Subject{ .call = callFibUndefLit };

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

// Marks the ctx map, so the context group can prove this hook ran.
fn providerContextify(_: *const omni.Provider, val: Json) Json {
    if (.object != val) return val;

    var out: std.json.ObjectMap = .{};
    var it = val.object.iterator();
    while (it.next()) |field| {
        out.put(ALLOC, field.key_ptr.*, field.value_ptr.*) catch unreachable;
    }
    out.put(ALLOC, "mark", omni.jstr("CTX")) catch unreachable;

    return .{ .object = out };
}

fn fibprovider(shift: f64) *const omni.Provider {
    const data = ALLOC.create(ShiftData) catch unreachable;
    data.* = .{ .shift = shift };

    const provider = ALLOC.create(omni.Provider) catch unreachable;
    provider.* = .{
        .subject = providerSubject,
        .client = providerClient,
        .contextify = providerContextify,
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

// An args-subject: it hands back the arguments it was given, so a consumer
// that converts into its own value model can show the runner what it did with
// them. This one rewrites the argument to prove the runner reads the RETURNED
// list rather than the one it passed in - `match.args` is the assertion that
// depends on it.
const ARGSMARK = "argsmark";

fn fibargs(_: *const omni.SubjectArgs, args: []const omni.Json) omni.SubjectArgsResult {
    const value = switch (FIB.call(&FIB, args)) {
        .ok => |found| found,
        .err => |message| return .{ .err = message },
    };

    const back = ALLOC.alloc(omni.Json, args.len) catch return .{ .err = "out of memory" };
    for (args, 0..) |_, at| {
        back[at] = omni.jstr(ARGSMARK);
    }

    return .{ .ok = .{ .args = back, .res = value } };
}

const FIBARGS = omni.SubjectArgs{ .call = fibargs };

// `runsetflagsargs` runs the same entries the plain subject does, and the
// arguments the subject hands back are the ones `match.args` sees.
fn checkargssubject() !void {
    const label = "an args-subject replaces what match.args sees";
    if (!wanted(label)) {
        return;
    }

    const spec = try omni.jmap(ALLOC, &.{
        .{ "fib", try omni.jmap(ALLOC, &.{
            .{ "g", try omni.jmap(ALLOC, &.{
                .{ "set", try omni.jlist(ALLOC, &.{
                    try omni.jmap(ALLOC, &.{
                        .{ "in", omni.jnum(6) },
                        .{ "out", omni.jnum(8) },
                        .{ "match", try omni.jmap(ALLOC, &.{
                            .{ "args", try omni.jlist(ALLOC, &.{omni.jstr(ARGSMARK)}) },
                        }) },
                    }),
                }) },
            }) },
        }) },
    });

    const runner = try omni.makeRunnerSpec(ALLOC, spec, &omni.Provider{});
    const pack = try runner.runner("fib", null);
    report(label, try pack.runsetflagsargs(pack.set("g"), .{}, &FIBARGS));
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
fn badspec(alloc: std.mem.Allocator) !Json {
    return omni.jmap(alloc, &.{
        .{
            "fib",
            try omni.jmap(alloc, &.{
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
                // __UNDEF__ (absent) must not be satisfied by a subject that
                // returns the literal string "__UNDEF__" as ordinary data.
                .{ "wrongundef", try omni.jmap(alloc, &.{
                    .{ "set", try omni.jlist(alloc, &.{
                        try omni.jmap(alloc, &.{
                            .{ "in", omni.jnum(1) },
                            .{ "match", try omni.jmap(alloc, &.{
                                .{ "out", try omni.jmap(alloc, &.{
                                    .{ "a", omni.jstr("__UNDEF__") },
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
            }),
        },
    });
}

fn expectfail(label: []const u8, setname: []const u8, subject: *const omni.Subject) !void {
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const runner = try omni.makeRunnerSpec(ALLOC, try badspec(ALLOC), empty);
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

    const runner = try omni.makeRunnerSpec(ALLOC, spec, empty);
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

// ---- version-1 negative tests -----------------------------------------

// A spec whose OMNI block this runner must refuse at load time: expects
// makeRunnerSpec to fail with exactly `wanterr`, never a Runner.
fn expectloadfail(
    label: []const u8,
    build: *const fn (std.mem.Allocator) anyerror!Json,
    wanterr: anyerror,
) !void {
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const spec = try build(ALLOC);

    if (omni.makeRunnerSpec(ALLOC, spec, empty)) |_| {
        report(label, "omni: expected a load failure, got none");
    } else |err| {
        report(label, if (err == wanterr)
            null
        else
            try std.fmt.allocPrint(ALLOC, "omni: expected {s}, got {s}", .{ @errorName(wanterr), @errorName(err) }));
    }
}

// A group that must load, then fail at runset time with `want` in the
// message - the strict entry/empty-set checks, which (unlike load-time
// version refusal) carry byte-identical text.
fn expectsetfail(
    label: []const u8,
    build: *const fn (std.mem.Allocator) anyerror!Json,
    groupname: []const u8,
    subject: *const omni.Subject,
    want: []const u8,
) !void {
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const runner = try omni.makeRunnerSpec(ALLOC, try build(ALLOC), empty);
    const pack = try runner.runner("fib", null);

    const failure = try pack.runset(pack.set(groupname), subject);

    const message = failure orelse {
        report(label, "omni: expected a failure, got none");
        return;
    };

    report(label, if (null != std.mem.indexOf(u8, message, want)) null else message);
}

// A group that must load and pass outright.
fn expectsetpass(
    label: []const u8,
    build: *const fn (std.mem.Allocator) anyerror!Json,
    groupname: []const u8,
    subject: *const omni.Subject,
) !void {
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const runner = try omni.makeRunnerSpec(ALLOC, try build(ALLOC), empty);
    const pack = try runner.runner("fib", null);

    report(label, try pack.runset(pack.set(groupname), subject));
}

fn specversion99(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(99) }}) },
        .{ "fib", try omni.jmap(alloc, &.{
            .{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{}) }}) },
        }) },
    });
}

fn specrequiresunknown(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{
            .{ "version", omni.jnum(1) },
            .{ "requires", try omni.jlist(alloc, &.{omni.jstr("nosuchfeature")}) },
        }) },
        .{ "fib", try omni.jmap(alloc, &.{
            .{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{}) }}) },
        }) },
    });
}

fn specversionmalformed(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jstr("one") }}) },
        .{ "fib", try omni.jmap(alloc, &.{
            .{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{}) }}) },
        }) },
    });
}

// Both halves of the presence-not-nullness rule for the OMNI block
// itself: a present-but-null block (or requires list) is malformed, but a
// genuinely absent OMNI key stays legacy.
fn checknullomni() !void {
    const label = "rejects a null OMNI block, but accepts an absent one";
    if (!wanted(label)) {
        return;
    }

    const empty = try ALLOC.create(omni.Provider);
    empty.* = .{};

    const nullblock = try omni.jmap(ALLOC, &.{
        .{ "OMNI", Json{ .null = {} } },
        .{ "fib", try omni.jmap(ALLOC, &.{
            .{ "g", try omni.jmap(ALLOC, &.{.{ "set", try omni.jlist(ALLOC, &.{
                try omni.jmap(ALLOC, &.{ .{ "in", omni.jnum(1) }, .{ "out", omni.jnum(1) } }),
            }) }}) },
        }) },
    });

    if (omni.makeRunnerSpec(ALLOC, nullblock, empty)) |_| {
        report(label, "omni: expected OMNI: null to be refused");
        return;
    } else |err| {
        if (err != error.MalformedOmniVersion) {
            report(label, try std.fmt.allocPrint(
                ALLOC,
                "omni: expected MalformedOmniVersion for OMNI: null, got {s}",
                .{@errorName(err)},
            ));
            return;
        }
    }

    const nullrequires = try omni.jmap(ALLOC, &.{
        .{ "OMNI", try omni.jmap(ALLOC, &.{
            .{ "version", omni.jnum(1) },
            .{ "requires", Json{ .null = {} } },
        }) },
        .{ "fib", try omni.jmap(ALLOC, &.{
            .{ "g", try omni.jmap(ALLOC, &.{.{ "set", try omni.jlist(ALLOC, &.{
                try omni.jmap(ALLOC, &.{ .{ "in", omni.jnum(1) }, .{ "out", omni.jnum(1) } }),
            }) }}) },
        }) },
    });

    if (omni.makeRunnerSpec(ALLOC, nullrequires, empty)) |_| {
        report(label, "omni: expected requires: null to be refused");
        return;
    } else |err| {
        if (err != error.MalformedOmniRequires) {
            report(label, try std.fmt.allocPrint(
                ALLOC,
                "omni: expected MalformedOmniRequires for requires: null, got {s}",
                .{@errorName(err)},
            ));
            return;
        }
    }

    const absent = try omni.jmap(ALLOC, &.{
        .{ "fib", try omni.jmap(ALLOC, &.{
            .{ "g", try omni.jmap(ALLOC, &.{.{ "set", try omni.jlist(ALLOC, &.{
                try omni.jmap(ALLOC, &.{ .{ "in", omni.jnum(1) }, .{ "out", omni.jnum(1) } }),
            }) }}) },
        }) },
    });

    if (omni.makeRunnerSpec(ALLOC, absent, empty)) |_| {
        report(label, null);
    } else |err| {
        report(label, try std.fmt.allocPrint(
            ALLOC,
            "omni: expected an absent OMNI block to load, got {s}",
            .{@errorName(err)},
        ));
    }
}

fn specunknownfield(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(1) }}) },
        .{ "fib", try omni.jmap(alloc, &.{.{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", omni.jnum(6) },
                .{ "matches", try omni.jmap(alloc, &.{.{ "out", omni.jnum(999) }}) },
            }),
        }) }}) }}) },
    });
}

fn specmultiargsources(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(1) }}) },
        .{ "fib", try omni.jmap(alloc, &.{.{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", omni.jnum(5) },
                .{ "args", try omni.jlist(alloc, &.{omni.jnum(5)}) },
                .{ "out", omni.jnum(5) },
            }),
        }) }}) }}) },
    });
}

fn specerrandout(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(1) }}) },
        .{ "fib", try omni.jmap(alloc, &.{.{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", omni.jnum(-1) },
                .{ "err", omni.jbool(true) },
                .{ "out", omni.jnum(5) },
            }),
        }) }}) }}) },
    });
}

fn specnullid(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(1) }}) },
        .{ "fib", try omni.jmap(alloc, &.{.{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", omni.jnum(1) },
                .{ "out", omni.jnum(1) },
                .{ "id", Json{ .null = {} } },
            }),
        }) }}) }}) },
    });
}

fn specemptysets(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "OMNI", try omni.jmap(alloc, &.{.{ "version", omni.jnum(1) }}) },
        .{ "fib", try omni.jmap(alloc, &.{
            .{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{}) }}) },
            .{ "h", try omni.jmap(alloc, &.{
                .{ "set", try omni.jlist(alloc, &.{}) },
                .{ "empty", omni.jbool(true) },
            }) },
        }) },
    });
}

fn speclegacyunknownfield(alloc: std.mem.Allocator) anyerror!Json {
    return omni.jmap(alloc, &.{
        .{ "fib", try omni.jmap(alloc, &.{.{ "g", try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", omni.jnum(6) },
                .{ "matches", try omni.jmap(alloc, &.{.{ "out", omni.jnum(999) }}) },
                .{ "out", omni.jnum(8) },
            }),
        }) }}) }}) },
    });
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
    try rungroup(&pack, "context", &FIBCTX, .{});
    try checkargssubject();

    try expectfail("detects wrong result", "wrongout", &FIB);
    try expectfail("detects missing error", "wrongerr", &FIB);
    try expectfail("detects failed match", "wrongmatch", &FIB);
    try expectfail("detects absent key", "missing", &FIBINFO);
    try expectfail("a concrete match leaf does not match a missing key", "matchabsent", &FIBINFO);
    try expectfail("__UNDEF__ does not match a present null", "undefonnull", &FIBINFO);
    try expectfail("__UNDEF__ does not match its own literal", "wrongundef", &FIBUNDEFLIT);
    try expectfail("__NULL__ does not match an absent key", "nullonabsent", &FIBINFO);
    try expectfail("an empty-string match leaf is not a wildcard", "emptystr", &FIBINFO);

    try expectloadfail("rejects an unsupported spec version", specversion99, error.UnsupportedSpecVersion);
    try expectloadfail("rejects an unknown required capability", specrequiresunknown, error.UnsupportedCapability);
    try expectloadfail("rejects a malformed version block", specversionmalformed, error.MalformedOmniVersion);
    try checknullomni();

    try expectsetfail(
        "strict: an unknown entry field fails instead of passing vacuously",
        specunknownfield,
        "g",
        &FIBINFO,
        "unknown entry field: matches",
    );
    try expectsetfail(
        "strict: more than one of in, args, ctx fails",
        specmultiargsources,
        "g",
        &FIB,
        "more than one of in, args, ctx",
    );
    try expectsetfail("strict: err together with out fails", specerrandout, "g", &FIB, "both err and out");
    try expectsetfail(
        "strict: a null id fails even under null-normalisation",
        specnullid,
        "g",
        &FIB,
        "entry id is not a string",
    );
    try expectsetfail("strict: an empty set fails unless marked empty", specemptysets, "g", &FIB, "empty test set");
    try expectsetpass("strict: an empty set marked empty: true passes", specemptysets, "h", &FIB);
    try expectsetpass("a legacy spec (no OMNI block) stays lenient", speclegacyunknownfield, "g", &FIB);

    try checkmessage();

    std.debug.print("\n{d} passed, {d} failed\n", .{ PASSCOUNT, FAILCOUNT });

    std.process.exit(if (0 == FAILCOUNT) 0 else 1);
}
