//! Omni: the shared multi-language test runner (Zig port).
//!
//! A test spec is plain JSON. The same spec file drives the same tests in
//! every language that ships an omni port.
//!
//! Port of the canonical TypeScript implementation
//! (typescript/src/Runner.ts). Behaviour must match, case for case.
//!
//! Zig has no exceptions, so a failing check is returned as a message:
//! `if (pack.runset(group, subject)) |failure| { ... }`. A subject reports
//! failure the same way, with `SubjectResult.err`.
//!
//! Memory: every value the runner allocates comes from the allocator given
//! to `makeRunner`. Use an arena and free it once at the end.

const std = @import("std");

pub const regex = @import("regex.zig");

/// A JSON value. `null` (the Zig optional) is the absence marker, as
/// distinct from `Json{ .null = {} }`, which is a JSON null.
pub const Json = std.json.Value;

/// Absence: no value at all.
pub const Maybe = ?Json;

pub const NULLMARK = "__NULL__"; // Value is JSON null.
pub const UNDEFMARK = "__UNDEF__"; // Value is not present.
pub const EXISTSMARK = "__EXISTS__"; // Value exists (not undefined).

// ---- value helpers ---------------------------------------------------

pub fn ismap(val: Maybe) bool {
    return if (val) |entry| .object == entry else false;
}

pub fn islist(val: Maybe) bool {
    return if (val) |entry| .array == entry else false;
}

pub fn isnode(val: Maybe) bool {
    return ismap(val) or islist(val);
}

pub fn isabsent(val: Maybe) bool {
    return null == val;
}

pub fn isnull(val: Maybe) bool {
    return if (val) |entry| .null == entry else false;
}

pub fn isnone(val: Maybe) bool {
    return isabsent(val) or isnull(val);
}

pub fn isnum(val: Maybe) bool {
    const entry = val orelse return false;
    return .integer == entry or .float == entry;
}

pub fn isstr(val: Maybe) bool {
    return if (val) |entry| .string == entry else false;
}

pub fn asnum(val: Maybe) ?f64 {
    const entry = val orelse return null;
    return switch (entry) {
        .integer => |num| @floatFromInt(num),
        .float => |num| num,
        else => null,
    };
}

pub fn asstr(val: Maybe) ?[]const u8 {
    const entry = val orelse return null;
    return switch (entry) {
        .string => |text| text,
        else => null,
    };
}

/// Read a map entry. Returns null (absent) when missing.
pub fn jget(val: Maybe, key: []const u8) Maybe {
    const entry = val orelse return null;
    return switch (entry) {
        .object => |map| map.get(key),
        else => null,
    };
}

pub fn jhas(val: Maybe, key: []const u8) bool {
    const entry = val orelse return false;
    return switch (entry) {
        .object => |map| map.contains(key),
        else => false,
    };
}

pub fn jnum(val: f64) Json {
    return .{ .float = val };
}

pub fn jstr(val: []const u8) Json {
    return .{ .string = val };
}

pub fn jbool(val: bool) Json {
    return .{ .bool = val };
}

pub fn jlist(alloc: std.mem.Allocator, entries: []const Json) !Json {
    var out = std.json.Array.init(alloc);
    for (entries) |entry| {
        try out.append(entry);
    }
    return .{ .array = out };
}

pub const Pair = struct { []const u8, Json };

pub fn jmap(alloc: std.mem.Allocator, entries: []const Pair) !Json {
    var out: std.json.ObjectMap = .{};
    for (entries) |entry| {
        try out.put(alloc, entry[0], entry[1]);
    }
    return .{ .object = out };
}

/// Set a map entry, returning the updated value (no-op for non-maps).
pub fn jset(alloc: std.mem.Allocator, val: Json, key: []const u8, entry: Json) !Json {
    switch (val) {
        .object => |map| {
            var out = map;
            try out.put(alloc, key, entry);
            return .{ .object = out };
        },
        else => return val,
    }
}

// ---- util ------------------------------------------------------------

/// Deep copy a JSON value. Containers are rebuilt in the given allocator;
/// scalars are values already.
pub fn clone(alloc: std.mem.Allocator, val: Maybe) error{OutOfMemory}!Json {
    const entry = val orelse return Json{ .null = {} };

    return switch (entry) {
        .array => |list| blk: {
            var out = std.json.Array.init(alloc);
            for (list.items) |item| {
                try out.append(try clone(alloc, item));
            }
            break :blk Json{ .array = out };
        },
        .object => |map| blk: {
            var out: std.json.ObjectMap = .{};
            var it = map.iterator();
            while (it.next()) |field| {
                try out.put(alloc, field.key_ptr.*, try clone(alloc, field.value_ptr.*));
            }
            break :blk Json{ .object = out };
        },
        else => entry,
    };
}

/// The callback of a walk.
pub const Apply = *const fn (alloc: std.mem.Allocator, val: Json, path: []const []const u8) Json;

/// Depth-first walk: children first, then the containing node.
pub fn walk(
    alloc: std.mem.Allocator,
    val: Json,
    apply: Apply,
    path: []const []const u8,
) error{OutOfMemory}!Json {
    const next = switch (val) {
        .array => |list| blk: {
            var out = std.json.Array.init(alloc);
            for (list.items, 0..) |item, index| {
                const childpath = try std.mem.concat(alloc, []const u8, &.{
                    path,
                    &.{try std.fmt.allocPrint(alloc, "{d}", .{index})},
                });
                try out.append(try walk(alloc, item, apply, childpath));
            }
            break :blk Json{ .array = out };
        },
        .object => |map| blk: {
            var out: std.json.ObjectMap = .{};
            var it = map.iterator();
            while (it.next()) |field| {
                const childpath = try std.mem.concat(alloc, []const u8, &.{
                    path,
                    &.{field.key_ptr.*},
                });
                try out.put(alloc, field.key_ptr.*, try walk(alloc, field.value_ptr.*, apply, childpath));
            }
            break :blk Json{ .object = out };
        },
        else => val,
    };

    return apply(alloc, next, path);
}

/// Read a value by path. Returns null (absent) when any step is missing.
pub fn getpath(val: Maybe, path: []const []const u8) Maybe {
    var current = val;

    for (path) |part| {
        const entry = current orelse return null;

        switch (entry) {
            .array => |list| {
                const index = std.fmt.parseInt(usize, part, 10) catch return null;
                if (index >= list.items.len) {
                    return null;
                }
                current = list.items[index];
            },
            .object => |map| {
                current = map.get(part) orelse return null;
            },
            else => return null,
        }
    }

    return current;
}

/// Deep structural equality: numbers by value, bools never numbers.
pub fn deepequal(a: Maybe, b: Maybe) bool {
    if (isabsent(a) or isabsent(b)) {
        return isabsent(a) and isabsent(b);
    }

    const x = a.?;
    const y = b.?;

    if (isnum(a) or isnum(b)) {
        if (!isnum(a) or !isnum(b)) {
            return false;
        }
        const anum = asnum(a).?;
        const bnum = asnum(b).?;

        // NaN equals NaN: deepequal is structural, not IEEE (as canonical).
        return anum == bnum or (std.math.isNan(anum) and std.math.isNan(bnum));
    }

    return switch (x) {
        .null => .null == y,
        .bool => |flag| .bool == y and flag == y.bool,
        .string => |text| .string == y and std.mem.eql(u8, text, y.string),
        .array => |list| blk: {
            if (.array != y) break :blk false;
            if (list.items.len != y.array.items.len) break :blk false;
            for (list.items, 0..) |entry, index| {
                if (!deepequal(entry, y.array.items[index])) break :blk false;
            }
            break :blk true;
        },
        .object => |map| blk: {
            if (.object != y) break :blk false;
            if (map.count() != y.object.count()) break :blk false;
            var it = map.iterator();
            while (it.next()) |field| {
                const other = y.object.get(field.key_ptr.*) orelse break :blk false;
                if (!deepequal(field.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Render a number the same way in every port: 5.0 prints as 5.
pub fn numstr(alloc: std.mem.Allocator, val: f64) ![]const u8 {
    if (std.math.isNan(val) or std.math.isInf(val)) {
        return "null";
    }
    if (val == @trunc(val) and @abs(val) < 9007199254740992.0) {
        return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(val))});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{val});
}

/// Render a string as a JSON string literal.
pub fn quote(alloc: std.mem.Allocator, val: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');

    for (val) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (0x20 > ch) {
                    const escape = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{ch});
                    try out.appendSlice(alloc, escape);
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }

    try out.append(alloc, '"');
    return out.items;
}

/// Compact JSON text with map keys sorted, identical in every port.
pub fn jsonstr(alloc: std.mem.Allocator, val: Maybe) error{OutOfMemory}![]const u8 {
    const entry = val orelse return "undefined";

    return switch (entry) {
        .null => "null",
        .bool => |flag| if (flag) "true" else "false",
        .integer, .float, .number_string => try numstr(alloc, asnum(val).?),
        .string => |text| try quote(alloc, text),
        .array => |list| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(alloc, '[');
            for (list.items, 0..) |item, index| {
                if (0 < index) try out.append(alloc, ',');
                try out.appendSlice(alloc, try jsonstr(alloc, item));
            }
            try out.append(alloc, ']');
            break :blk out.items;
        },
        .object => |map| blk: {
            var keys: std.ArrayList([]const u8) = .empty;
            var it = map.iterator();
            while (it.next()) |field| {
                try keys.append(alloc, field.key_ptr.*);
            }
            std.mem.sort([]const u8, keys.items, {}, lessThanStr);

            var out: std.ArrayList(u8) = .empty;
            try out.append(alloc, '{');
            for (keys.items, 0..) |key, index| {
                if (0 < index) try out.append(alloc, ',');
                try out.appendSlice(alloc, try quote(alloc, key));
                try out.append(alloc, ':');
                try out.appendSlice(alloc, try jsonstr(alloc, map.get(key).?));
            }
            try out.append(alloc, '}');
            break :blk out.items;
        },
    };
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return .lt == std.mem.order(u8, a, b);
}

/// Strings verbatim, everything else as compact JSON.
pub fn stringify(alloc: std.mem.Allocator, val: Maybe) ![]const u8 {
    if (asstr(val)) |text| {
        return text;
    }
    return jsonstr(alloc, val);
}

/// Render a path as a dotted string.
pub fn pathify(alloc: std.mem.Allocator, path: []const []const u8) ![]const u8 {
    return std.mem.join(alloc, ".", path);
}

// ---- runner ----------------------------------------------------------

/// What a subject returns: a value, or the message of a failure.
pub const SubjectResult = union(enum) {
    ok: Json,
    err: []const u8,
};

/// The function under test. Zig has no closures, so a subject is a
/// function pointer plus its own data.
pub const Subject = struct {
    call: *const fn (self: *const Subject, args: []const Json) SubjectResult,
    data: ?*const anyopaque = null,
};

/// What an args-subject returns: the arguments it ended up with, alongside
/// the value - or the message of a failure.
pub const SubjectArgsResult = union(enum) {
    ok: struct { args: []const Json, res: Json },
    err: []const u8,
};

/// A subject that may REPLACE its arguments, which `match.args` can then
/// assert on. `minor/setpath` is the case in point: eight of its nine entries
/// assert that the store was rewritten in place, and `merge/integrity` all
/// six.
///
/// A consumer whose value model is not `std.json.Value` has to convert, and a
/// conversion is a copy: whatever it does to its own nodes is invisible here.
/// Returning the arguments alongside the result is the only channel there is.
///
/// Separate from `Subject` rather than replacing it: a signature change would
/// break every consumer for a capability most subjects do not need. omni-rust,
/// -cpp, -ocaml, -elixir, -haskell, -clojure, -scala, -swift and -lean carry
/// the same pair, for the same reason.
pub const SubjectArgs = struct {
    call: *const fn (self: *const SubjectArgs, args: []const Json) SubjectArgsResult,
    data: ?*const anyopaque = null,
};

/// The host of the system under test. Every hook is optional.
pub const Provider = struct {
    subject: ?*const fn (self: *const Provider, name: []const u8) ?*const Subject = null,
    client: ?*const fn (self: *const Provider, options: Maybe) *const Provider = null,
    contextify: ?*const fn (self: *const Provider, val: Json) Json = null,
    /// Build the `match.err` base from the failure, REPLACING `errify`.
    ///
    /// Zig reaches this point with a message and nothing else - an error
    /// value carries no payload - so a library whose errors carry a code
    /// has no other way to put one in the base. The hook receives that
    /// message and returns the base, letting a spec assert
    /// `match: {err: {code: "x"}}` instead of pattern-matching prose.
    errify: ?*const fn (self: *const Provider, alloc: std.mem.Allocator, message: []const u8) anyerror!Json = null,
    data: ?*const anyopaque = null,
};

/// Run-time options for a set of test entries.
pub const Flags = struct {
    null_: bool = true,
    name: ?[]const u8 = null,

    pub fn nonull() Flags {
        return .{ .null_ = false };
    }
};

/// The newest spec format version this runner understands. A spec with no
/// OMNI block is version 0: the original, lenient format, frozen forever.
/// Version 1 turns on strict entry validation (see checkentry).
pub const SPECVERSION = 1;

/// Capability strings this runner supports beyond the version baseline. A
/// spec's OMNI.requires list is checked against this: an unknown
/// capability refuses the spec loudly at load time, instead of a lagging
/// port silently mis-running it. (Empty today; future format features
/// mint a string here.)
pub const CAPABILITIES: []const []const u8 = &.{};

/// The complete set of fields an entry may carry. Under version 1 anything
/// else is an error: an unrecognised key is almost always a typo'd
/// assertion, and a typo'd assertion is a test that silently stopped
/// testing.
const ENTRYFIELDS = [_][]const u8{ "in", "args", "ctx", "out", "err", "match", "client", "id", "doc" };

fn isentryfield(key: []const u8) bool {
    for (ENTRYFIELDS) |field| {
        if (std.mem.eql(u8, field, key)) return true;
    }
    return false;
}

/// Load a spec: a path to a JSON file.
pub fn loadspec(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Json {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch {
        return error.CannotReadSpec;
    };

    const parsed = try std.json.parseFromSlice(Json, alloc, text, .{});

    return parsed.value;
}

/// Find `primary.<name>`, then `<name>`, then the whole spec.
pub fn resolvespec(name: []const u8, alltests: Json) Json {
    if (0 == name.len) {
        return alltests;
    }

    if (jget(jget(alltests, "primary"), name)) |section| {
        return section;
    }

    if (jget(alltests, name)) |section| {
        return section;
    }

    return alltests;
}

/// Read the spec's format version from its optional top-level OMNI block,
/// and refuse a spec this runner cannot faithfully run: a version newer
/// than SPECVERSION, or a required capability outside CAPABILITIES. Only a
/// genuinely absent OMNI key is legacy (version 0) - a present-but-null
/// block, or a present-but-null requires list, is malformed; that
/// distinction is why this checks presence (jhas) rather than nullness.
/// This is a load-time failure, so it surfaces through makeRunner's own
/// error-union return path rather than the ?[]const u8 channel runset
/// failures use - Zig error values carry no message payload, so (unlike
/// the checkset/checkentry failures below) this one is exempt from
/// carrying byte-identical text; the distinct error name is what a caller
/// matches on instead.
fn resolveversion(alltests: Json) !i64 {
    if (!jhas(alltests, "OMNI")) {
        return 0;
    }

    const meta = jget(alltests, "OMNI");
    const version = jget(meta, "version");

    if (!ismap(meta) or !isnum(version)) {
        return error.MalformedOmniVersion;
    }

    const vnum = asnum(version).?;
    if (vnum != @trunc(vnum)) {
        return error.MalformedOmniVersion;
    }

    const maxversion: f64 = SPECVERSION;
    if (vnum < 0 or maxversion < vnum) {
        return error.UnsupportedSpecVersion;
    }

    if (jhas(meta, "requires")) {
        const requires = jget(meta, "requires").?;
        if (!islist(requires)) {
            return error.MalformedOmniRequires;
        }

        for (requires.array.items) |cap| {
            const capstr = asstr(cap) orelse return error.UnsupportedCapability;

            var known = false;
            for (CAPABILITIES) |allowed| {
                if (std.mem.eql(u8, allowed, capstr)) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                return error.UnsupportedCapability;
            }
        }
    }

    return @intFromFloat(vnum);
}

/// Nulls (and absent values) become NULLMARK. Always a fresh copy.
pub fn fixjson(alloc: std.mem.Allocator, val: Maybe, donull: bool) error{OutOfMemory}!Json {
    if (isnone(val)) {
        return if (donull) jstr(NULLMARK) else Json{ .null = {} };
    }

    const entry = val.?;

    return switch (entry) {
        .array => |list| blk: {
            var out = std.json.Array.init(alloc);
            for (list.items) |item| {
                try out.append(try fixjson(alloc, item, donull));
            }
            break :blk Json{ .array = out };
        },
        .object => |map| blk: {
            var out: std.json.ObjectMap = .{};
            var it = map.iterator();
            while (it.next()) |field| {
                try out.put(alloc, field.key_ptr.*, try fixjson(alloc, field.value_ptr.*, donull));
            }
            break :blk Json{ .object = out };
        },
        else => entry,
    };
}

/// The JSON form of an error: always at least {name,message}.
pub fn errify(alloc: std.mem.Allocator, message: []const u8) !Json {
    return jmap(alloc, &.{ .{ "name", jstr("Error") }, .{ "message", jstr(message) } });
}

/// Match one leaf: /regex/ or case-insensitive substring for strings.
pub fn matchval(alloc: std.mem.Allocator, check: Maybe, base: Maybe) !bool {
    if (deepequal(check, base)) {
        return true;
    }

    var want = check;
    if (asstr(check)) |text| {
        if (std.mem.eql(u8, UNDEFMARK, text) or std.mem.eql(u8, NULLMARK, text)) {
            want = Json{ .null = {} };
        }
    }

    if (isnone(want)) {
        if (isnone(base)) {
            return true;
        }
        if (asstr(base)) |text| {
            return std.mem.eql(u8, NULLMARK, text);
        }
        return false;
    }

    if (asstr(want)) |text| {
        // An empty want is not a wildcard: it matches only an empty string.
        if (0 == text.len) {
            return if (asstr(base)) |basetext| 0 == basetext.len else false;
        }

        const basestr = try stringify(alloc, base);

        if (2 < text.len and '/' == text[0] and '/' == text[text.len - 1]) {
            return regex.find(alloc, text[1 .. text.len - 1], basestr);
        }

        const lowbase = try std.ascii.allocLowerString(alloc, basestr);
        const lowwant = try std.ascii.allocLowerString(alloc, text);

        return null != std.mem.indexOf(u8, lowbase, lowwant);
    }

    return deepequal(want, base);
}

/// Convert NULLMARK sentinels back into real nulls.
pub fn nullmodifier(alloc: std.mem.Allocator, val: Json) !Json {
    const text = asstr(val) orelse return val;

    if (std.mem.eql(u8, NULLMARK, text)) {
        return Json{ .null = {} };
    }

    const replaced = try std.mem.replaceOwned(u8, alloc, text, NULLMARK, "null");
    return jstr(replaced);
}

/// What a runner returns for one named spec section.
pub const RunPack = struct {
    alloc: std.mem.Allocator,
    spec: Json,
    subject: ?*const Subject,
    client: *const Provider,
    name: []const u8,
    clientnames: []const []const u8,
    clients: []const *const Provider,
    specversion: i64,

    /// A named group of the resolved spec.
    pub fn set(self: *const RunPack, setname: []const u8) Maybe {
        return jget(self.spec, setname);
    }

    /// Run one set of test entries. Returns a failure message, or null.
    pub fn runset(self: *const RunPack, testspec: Maybe, subject: ?*const Subject) !?[]const u8 {
        return self.runsetflags(testspec, .{}, subject);
    }

    /// Run one set of test entries with flags.
    pub fn runsetflags(
        self: *const RunPack,
        testspec: Maybe,
        flags: Flags,
        subject: ?*const Subject,
    ) !?[]const u8 {
        return self.drive(testspec, flags, subject, null);
    }

    /// Everything `runsetflags` does, for a subject that may replace its
    /// arguments. See `SubjectArgs`.
    pub fn runsetflagsargs(
        self: *const RunPack,
        testspec: Maybe,
        flags: Flags,
        argsubject: *const SubjectArgs,
    ) !?[]const u8 {
        return self.drive(testspec, flags, null, argsubject);
    }

    fn drive(
        self: *const RunPack,
        testspec: Maybe,
        flags: Flags,
        subject: ?*const Subject,
        argsubject: ?*const SubjectArgs,
    ) !?[]const u8 {
        const alloc = self.alloc;
        const label = flags.name orelse (if (0 == self.name.len) "set" else self.name);

        const usesubject: ?*const Subject = if (null != argsubject)
            null
        else
            subject orelse self.subject orelse
                return try std.fmt.allocPrint(alloc, "omni: no test subject for: {s}", .{label});

        const testspecmap = try fixjson(alloc, testspec, flags.null_);
        const testset = jget(testspecmap, "set") orelse
            return try std.fmt.allocPrint(alloc, "omni: test spec has no set: {s}", .{label});

        if (.array != testset) {
            return try std.fmt.allocPrint(alloc, "omni: test spec has no set: {s}", .{label});
        }

        // Validate the AUTHORED group (pre-fixjson), not the normalised
        // one: null-normalisation would otherwise rewrite an authored
        // `id: null` into a sentinel string and hide it from checkentry.
        if (1 <= self.specversion) {
            if (try self.checkset(label, testspec, testset)) |failure| {
                return failure;
            }
        }

        for (testset.array.items, 0..) |rawentry, index| {
            if (.object != rawentry) {
                return try std.fmt.allocPrint(
                    alloc,
                    "omni: {s}[{d}]: entry is not a map",
                    .{ label, index },
                );
            }

            var entry = rawentry;

            // An entry with no `out` expects a null (or absent) result.
            if (flags.null_ and isnone(jget(entry, "out"))) {
                entry = try jset(alloc, entry, "out", jstr(NULLMARK));
            }

            var entrysubject: ?*const Subject = usesubject;

            if (null != entrysubject) if (asstr(jget(entry, "client"))) |clientname| {
                var found: ?*const Provider = null;
                for (self.clientnames, 0..) |candidate, at| {
                    if (std.mem.eql(u8, candidate, clientname)) {
                        found = self.clients[at];
                    }
                }

                const client = found orelse
                    return try std.fmt.allocPrint(alloc, "omni: unknown client: {s}", .{clientname});

                if (client.subject) |resolve| {
                    if (resolve(client, self.name)) |clientsubject| {
                        entrysubject = clientsubject;
                    }
                }
            };

            // Build the argument list: `ctx`, `args`, or `in`.
            var args: std.ArrayList(Json) = .empty;
            const hasctx = jhas(entry, "ctx");
            const hasargs = jhas(entry, "args");

            if (hasctx) {
                try args.append(alloc, jget(entry, "ctx").?);
            } else if (hasargs) {
                const rawargs = jget(entry, "args").?;
                if (.array == rawargs) {
                    for (rawargs.array.items) |item| {
                        try args.append(alloc, item);
                    }
                } else {
                    try args.append(alloc, rawargs);
                }
            } else {
                try args.append(alloc, try clone(alloc, jget(entry, "in")));
            }

            if ((hasctx or hasargs) and 0 < args.items.len and .object == args.items[0]) {
                var first = args.items[0];
                if (self.client.contextify) |contextify| {
                    first = contextify(self.client, first);
                }
                // Canonical attaches the resolved client onto ctx/args[0]
                // (testpack.client) so a context subject can tell it was
                // invoked through one. std.json.Value has no case for a
                // live Provider reference, and the resolved client is
                // never absent (it defaults to the root provider), so a
                // boolean marker carries the same observable meaning the
                // corpus checks for - presence, never identity.
                first = try jset(alloc, first, "client", jbool(true));
                args.items[0] = first;
                entry = try jset(alloc, entry, "ctx", first);
            }

            // An args-subject returns its arguments alongside the result, so
            // `match.args` sees what the subject actually did with them.
            const outcome: SubjectArgsResult = if (argsubject) |call|
                call.call(call, args.items)
            else if (entrysubject) |call| switch (call.call(call, args.items)) {
                .ok => |value| SubjectArgsResult{ .ok = .{ .args = args.items, .res = value } },
                .err => |message| SubjectArgsResult{ .err = message },
            } else return try std.fmt.allocPrint(
                alloc,
                "omni: no test subject for: {s}",
                .{label},
            );

            switch (outcome) {
                .err => |message| {
                    if (try self.handleerror(label, index, entry, message)) |failure| {
                        return failure;
                    }
                },
                .ok => |call| {
                    const res = try fixjson(alloc, call.res, flags.null_);
                    entry = try jset(alloc, entry, "res", res);

                    if (try self.checkresult(label, index, entry, call.args, res)) |failure| {
                        return failure;
                    }
                },
            }
        }

        return null;
    }

    // Validate a version-1 group up front, against the AUTHORED entries -
    // see the note on runsetflags's call site for why. Absorbs the
    // empty-set check too: an empty `set` is refused unless the group
    // carries `empty: true`, making the emptiness a stated fact rather
    // than an accident.
    fn checkset(self: *const RunPack, label: []const u8, testspec: Maybe, normalset: Json) !?[]const u8 {
        const origset = if (ismap(testspec) and islist(jget(testspec, "set")))
            jget(testspec, "set").?
        else
            normalset;

        var isempty = false;
        if (ismap(testspec)) {
            if (jget(testspec, "empty")) |flag| {
                isempty = .bool == flag and flag.bool;
            }
        }

        if (0 == origset.array.items.len and !isempty) {
            return try std.fmt.allocPrint(self.alloc, "omni: empty test set: {s}", .{label});
        }

        for (origset.array.items, 0..) |entry, index| {
            if (try self.checkentry(label, index, entry)) |failure| {
                return failure;
            }
        }

        return null;
    }

    // Strict entry validation, applied when the spec declares version 1
    // or later. The lenient format converts each of these mistakes into a
    // silent pass or a dead field; here they fail with the entry named.
    fn checkentry(self: *const RunPack, label: []const u8, index: usize, entry: Json) !?[]const u8 {
        if (.object != entry) {
            return try self.fail(label, index, entry, "entry is not a map", null, null);
        }

        var fields = entry.object.iterator();
        while (fields.next()) |field| {
            if (!isentryfield(field.key_ptr.*)) {
                const reason = try std.fmt.allocPrint(
                    self.alloc,
                    "unknown entry field: {s}",
                    .{field.key_ptr.*},
                );
                return try self.fail(label, index, entry, reason, null, null);
            }
        }

        var argsources: usize = 0;
        for ([_][]const u8{ "in", "args", "ctx" }) |key| {
            if (jhas(entry, key)) argsources += 1;
        }
        if (1 < argsources) {
            return try self.fail(label, index, entry, "entry has more than one of in, args, ctx", null, null);
        }

        if (!isnone(jget(entry, "err")) and jhas(entry, "out")) {
            return try self.fail(label, index, entry, "entry has both err and out", null, null);
        }

        // Presence, not nullness: an authored `id: null` must fail here,
        // before resolveentry's null-normalisation ever gets a chance to
        // turn it into the sentinel string "__NULL__".
        if (jhas(entry, "id") and null == asstr(jget(entry, "id"))) {
            return try self.fail(label, index, entry, "entry id is not a string", null, null);
        }

        return null;
    }

    fn checkresult(
        self: *const RunPack,
        label: []const u8,
        index: usize,
        entry: Json,
        args: []const Json,
        res: Json,
    ) !?[]const u8 {
        const alloc = self.alloc;
        var matched = false;

        const entryerr = jget(entry, "err");
        if (!isnone(entryerr)) {
            return try self.fail(
                label,
                index,
                entry,
                "expected error did not occur",
                try stringify(alloc, entryerr),
                try stringify(alloc, res),
            );
        }

        const check = jget(entry, "match");
        if (!isnone(check)) {
            const base = try jmap(alloc, &.{
                .{ "in", jget(entry, "in") orelse Json{ .null = {} } },
                .{ "args", try jlist(alloc, args) },
                .{ "out", jget(entry, "res") orelse Json{ .null = {} } },
                .{ "ctx", jget(entry, "ctx") orelse Json{ .null = {} } },
            });

            if (try self.matchcheck(label, index, entry, check.?, base, &.{})) |failure| {
                return failure;
            }
            matched = true;
        }

        const out = jget(entry, "out");

        if (deepequal(res, out)) {
            return null;
        }

        // NOTE: a match with no explicit out is a complete check on its own.
        if (matched) {
            if (isnone(out)) {
                return null;
            }
            if (asstr(out)) |text| {
                if (std.mem.eql(u8, NULLMARK, text)) {
                    return null;
                }
            }
        }

        return try self.fail(
            label,
            index,
            entry,
            "result mismatch",
            try stringify(alloc, out),
            try stringify(alloc, res),
        );
    }

    /// The error base a `match.err` sees: the provider's own, when it has one.
    fn errbase(self: *const RunPack, message: []const u8) !Json {
        if (self.client.errify) |hook| {
            return hook(self.client, self.alloc, message);
        }
        return errify(self.alloc, message);
    }

    fn handleerror(
        self: *const RunPack,
        label: []const u8,
        index: usize,
        entry: Json,
        message: []const u8,
    ) !?[]const u8 {
        const alloc = self.alloc;
        const entryerr = jget(entry, "err");

        if (isnone(entryerr)) {
            return try self.fail(label, index, entry, "unexpected error", null, message);
        }

        var istrue = false;
        if (.bool == entryerr.?) {
            istrue = entryerr.?.bool;
        }

        if (istrue or try matchval(alloc, entryerr, jstr(message))) {
            const check = jget(entry, "match");
            if (!isnone(check)) {
                const base = try jmap(alloc, &.{
                    .{ "in", jget(entry, "in") orelse Json{ .null = {} } },
                    .{ "out", jget(entry, "res") orelse Json{ .null = {} } },
                    .{ "ctx", jget(entry, "ctx") orelse Json{ .null = {} } },
                    .{ "err", try self.errbase(message) },
                });
                return self.matchcheck(label, index, entry, check.?, base, &.{});
            }
            return null;
        }

        return try self.fail(
            label,
            index,
            entry,
            "error mismatch",
            try stringify(alloc, entryerr),
            message,
        );
    }

    // Check that every leaf of `check` is present, and matches, in `base`.
    fn matchcheck(
        self: *const RunPack,
        label: []const u8,
        index: usize,
        entry: Json,
        check: Json,
        base: Json,
        path: []const []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        const alloc = self.alloc;

        switch (check) {
            .array => |list| {
                for (list.items, 0..) |subcheck, at| {
                    const childpath = try std.mem.concat(alloc, []const u8, &.{
                        path,
                        &.{try std.fmt.allocPrint(alloc, "{d}", .{at})},
                    });
                    if (try self.matchcheck(label, index, entry, subcheck, base, childpath)) |failure| {
                        return failure;
                    }
                }
                return null;
            },
            .object => |map| {
                var it = map.iterator();
                while (it.next()) |field| {
                    const childpath = try std.mem.concat(alloc, []const u8, &.{
                        path,
                        &.{field.key_ptr.*},
                    });
                    if (try self.matchcheck(label, index, entry, field.value_ptr.*, base, childpath)) |failure| {
                        return failure;
                    }
                }
                return null;
            },
            else => {},
        }

        const baseval = getpath(base, path);

        // The sentinels are tested BEFORE the identity check below.
        // Otherwise a subject returning the literal string "__UNDEF__"
        // satisfies an assertion that the key is absent - two mutually
        // exclusive states passing one check. A sentinel that accepts its
        // own literal is not a sentinel. (NULLMARK still accepts NULLMARK:
        // under the default null flag a real null has already been
        // normalised to it, so the two are genuinely indistinguishable
        // here - that one needs a raw-value escape, not an ordering
        // change.)
        if (asstr(check)) |text| {
            // Explicitly absent: satisfied only by a genuinely missing
            // key, never by a present null (the distinction the sentinels
            // exist to keep).
            if (std.mem.eql(u8, UNDEFMARK, text)) {
                if (isabsent(baseval)) {
                    return null;
                }
                return try self.fail(
                    label,
                    index,
                    entry,
                    try std.fmt.allocPrint(alloc, "expected absent at {s}", .{try self.matchat(path)}),
                    "absent",
                    try stringify(alloc, baseval),
                );
            }
            // Explicitly null: satisfied only by a present null.
            if (std.mem.eql(u8, NULLMARK, text)) {
                if (isnull(baseval)) {
                    return null;
                }
                if (asstr(baseval)) |basetext| {
                    if (std.mem.eql(u8, NULLMARK, basetext)) {
                        return null;
                    }
                }
                return try self.fail(
                    label,
                    index,
                    entry,
                    try std.fmt.allocPrint(alloc, "expected null at {s}", .{try self.matchat(path)}),
                    "null",
                    try stringify(alloc, baseval),
                );
            }
            // Explicitly present: any present value, including null.
            if (std.mem.eql(u8, EXISTSMARK, text)) {
                if (!isabsent(baseval)) {
                    return null;
                }
                return try self.fail(
                    label,
                    index,
                    entry,
                    try std.fmt.allocPrint(alloc, "expected present at {s}", .{try self.matchat(path)}),
                    "present",
                    "absent",
                );
            }
        }

        // Identical values match. This sits below the sentinel branches
        // on purpose - see the note above.
        if (deepequal(check, baseval)) {
            return null;
        }

        // A concrete expectation never matches a missing key - a match
        // leaf against an absent value must fail, not substring-match
        // "undefined".
        if (isabsent(baseval)) {
            return try self.fail(
                label,
                index,
                entry,
                try std.fmt.allocPrint(alloc, "match failed at {s}", .{try self.matchat(path)}),
                try stringify(alloc, check),
                "absent",
            );
        }

        if (try matchval(alloc, check, baseval)) {
            return null;
        }

        return try self.matchfail(label, index, entry, check, baseval, path);
    }

    // A "match failed" report at one path.
    fn matchfail(
        self: *const RunPack,
        label: []const u8,
        index: usize,
        entry: Json,
        check: Maybe,
        baseval: Maybe,
        path: []const []const u8,
    ) error{OutOfMemory}![]const u8 {
        const alloc = self.alloc;
        return try self.fail(
            label,
            index,
            entry,
            try std.fmt.allocPrint(alloc, "match failed at {s}", .{try self.matchat(path)}),
            try stringify(alloc, check),
            try stringify(alloc, baseval),
        );
    }

    // The location of one match leaf, for failure messages.
    fn matchat(self: *const RunPack, path: []const []const u8) error{OutOfMemory}![]const u8 {
        return if (0 == path.len) "<root>" else try pathify(self.alloc, path);
    }

    // The spec-defined part of an entry (drop runner bookkeeping).
    fn entrysummary(self: *const RunPack, entry: Json) !Json {
        if (.object != entry) {
            return entry;
        }

        var out: std.json.ObjectMap = .{};
        var it = entry.object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (!std.mem.eql(u8, "res", key) and !std.mem.eql(u8, "thrown", key) and
                !std.mem.eql(u8, "ctx", key))
            {
                try out.put(self.alloc, key, field.value_ptr.*);
            }
        }

        return .{ .object = out };
    }

    fn fail(
        self: *const RunPack,
        label: []const u8,
        index: usize,
        entry: Json,
        reason: []const u8,
        expected: ?[]const u8,
        actual: ?[]const u8,
    ) error{OutOfMemory}![]const u8 {
        const alloc = self.alloc;

        const id = jget(entry, "id");
        const idpart = if (isabsent(id))
            ""
        else
            try std.fmt.allocPrint(alloc, " ({s})", .{try stringify(alloc, id)});

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, try std.fmt.allocPrint(
            alloc,
            "omni: {s}[{d}]{s}: {s}",
            .{ label, index, idpart, reason },
        ));

        if (expected) |text| {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n  expected: {s}", .{text}));
        }
        if (actual) |text| {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n  actual:   {s}", .{text}));
        }

        try out.appendSlice(alloc, try std.fmt.allocPrint(
            alloc,
            "\n  entry:    {s}",
            .{try stringify(alloc, try self.entrysummary(entry))},
        ));

        return out.items;
    }
};

/// A loaded spec plus its provider.
pub const Runner = struct {
    alloc: std.mem.Allocator,
    alltests: Json,
    provider: *const Provider,
    specversion: i64,

    /// Resolve one named section of the spec.
    pub fn runner(self: *const Runner, name: []const u8, store: Maybe) !RunPack {
        _ = store;

        const spec = resolvespec(name, self.alltests);

        var clientnames: std.ArrayList([]const u8) = .empty;
        var clients: std.ArrayList(*const Provider) = .empty;

        // A spec may define clients that a given test run never references.
        const defclient = jget(jget(spec, "DEF"), "client");
        if (ismap(defclient)) {
            if (self.provider.client) |clientmaker| {
                var it = defclient.?.object.iterator();
                while (it.next()) |field| {
                    var copts = jget(jget(field.value_ptr.*, "test"), "options");
                    if (isabsent(copts)) {
                        copts = try jmap(self.alloc, &.{});
                    }
                    try clientnames.append(self.alloc, field.key_ptr.*);
                    try clients.append(self.alloc, clientmaker(self.provider, copts));
                }
            }
        }

        var subject: ?*const Subject = null;
        if (0 < name.len) {
            if (self.provider.subject) |resolve| {
                subject = resolve(self.provider, name);
            }
        }

        return .{
            .alloc = self.alloc,
            .spec = spec,
            .subject = subject,
            .client = self.provider,
            .name = name,
            .clientnames = clientnames.items,
            .clients = clients.items,
            .specversion = self.specversion,
        };
    }
};

/// Make a runner for a spec file path and a provider. Resolves the spec's
/// format version immediately, so an unsupported or malformed OMNI block
/// fails fast, before any group runs.
pub fn makeRunner(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    provider: *const Provider,
) !Runner {
    const alltests = try loadspec(alloc, io, path);
    return .{
        .alloc = alloc,
        .alltests = alltests,
        .provider = provider,
        .specversion = try resolveversion(alltests),
    };
}

/// Make a runner for an in-memory spec and a provider. Same fail-fast
/// version resolution as makeRunner.
pub fn makeRunnerSpec(alloc: std.mem.Allocator, spec: Json, provider: *const Provider) !Runner {
    return .{
        .alloc = alloc,
        .alltests = spec,
        .provider = provider,
        .specversion = try resolveversion(spec),
    };
}
