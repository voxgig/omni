//! A small backtracking regex engine.
//!
//! Omni specs match error messages with `/pattern/` expectations, so every
//! port needs a regex. Zig has none in its standard library, and omni adds
//! no dependencies, so it carries this one - a direct port of the Rust
//! engine (rust/src/regex.zig's sibling, rust/src/regex.rs).
//!
//! Supported: literals, `.`, `^`, `$`, `|`, groups `(...)`, classes
//! `[a-z0-9_]` and `[^...]`, quantifiers `* + ? {m} {m,} {m,n}` (greedy,
//! and lazy with a trailing `?`), and the escapes `\d \D \w \W \s \S \n
//! \r \t` plus any escaped punctuation.

const std = @import("std");

const ItemKind = enum { char, range, digit, word, space };

const ClassItem = struct {
    kind: ItemKind,
    ch: u8 = 0,
    from: u8 = 0,
    to: u8 = 0,
    invert: bool = false,
};

const NodeKind = enum { char, any, class, start, end, seq, alt, repeat };

const Node = struct {
    kind: NodeKind,
    ch: u8 = 0,
    items: []ClassItem = &.{},
    negated: bool = false,
    kids: []*Node = &.{},
    inner: ?*Node = null,
    min: usize = 0,
    max: ?usize = null,
    greedy: bool = true,
};

const ParseError = error{ BadRegex, OutOfMemory };

const Parser = struct {
    alloc: std.mem.Allocator,
    pattern: []const u8,
    pos: usize = 0,

    fn node(self: *Parser, value: Node) ParseError!*Node {
        const out = try self.alloc.create(Node);
        out.* = value;
        return out;
    }

    fn done(self: *Parser) bool {
        return self.pos >= self.pattern.len;
    }

    fn peek(self: *Parser) u8 {
        return if (self.done()) 0 else self.pattern[self.pos];
    }

    fn parseAlt(self: *Parser) ParseError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.alloc, try self.parseSeq());

        while (!self.done() and '|' == self.peek()) {
            self.pos += 1;
            try branches.append(self.alloc, try self.parseSeq());
        }

        if (1 == branches.items.len) {
            return branches.items[0];
        }

        return self.node(.{ .kind = .alt, .kids = branches.items });
    }

    fn parseSeq(self: *Parser) ParseError!*Node {
        var nodes: std.ArrayList(*Node) = .empty;

        while (!self.done() and '|' != self.peek() and ')' != self.peek()) {
            const atom = try self.parseAtom();
            try nodes.append(self.alloc, try self.parseRepeat(atom));
        }

        return self.node(.{ .kind = .seq, .kids = nodes.items });
    }

    fn parseRepeat(self: *Parser, atom: *Node) ParseError!*Node {
        if (self.done()) {
            return atom;
        }

        var min: usize = 0;
        var max: ?usize = null;

        switch (self.peek()) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = null;
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = null;
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const bounds = self.parseCount() orelse return atom;
                min = bounds.min;
                max = bounds.max;
            },
            else => return atom,
        }

        var greedy = true;
        if (!self.done() and '?' == self.peek()) {
            greedy = false;
            self.pos += 1;
        }

        return self.node(.{ .kind = .repeat, .inner = atom, .min = min, .max = max, .greedy = greedy });
    }

    const Bounds = struct { min: usize, max: ?usize };

    fn parseCount(self: *Parser) ?Bounds {
        const start = self.pos;
        var scan = self.pos + 1;
        var min: usize = 0;
        var digits: usize = 0;

        while (scan < self.pattern.len and std.ascii.isDigit(self.pattern[scan])) {
            min = min * 10 + (self.pattern[scan] - '0');
            digits += 1;
            scan += 1;
        }

        if (0 == digits) {
            self.pos = start;
            return null;
        }

        if (scan < self.pattern.len and '}' == self.pattern[scan]) {
            self.pos = scan + 1;
            return .{ .min = min, .max = min };
        }

        if (scan >= self.pattern.len or ',' != self.pattern[scan]) {
            self.pos = start;
            return null;
        }
        scan += 1;

        var max: usize = 0;
        var maxdigits: usize = 0;
        while (scan < self.pattern.len and std.ascii.isDigit(self.pattern[scan])) {
            max = max * 10 + (self.pattern[scan] - '0');
            maxdigits += 1;
            scan += 1;
        }

        if (scan >= self.pattern.len or '}' != self.pattern[scan]) {
            self.pos = start;
            return null;
        }

        self.pos = scan + 1;
        return .{ .min = min, .max = if (0 == maxdigits) null else max };
    }

    fn escapeNode(self: *Parser, escape: u8) ParseError!*Node {
        const items = try self.alloc.alloc(ClassItem, 1);

        switch (escape) {
            'd', 'D' => items[0] = .{ .kind = .digit },
            'w', 'W' => items[0] = .{ .kind = .word },
            's', 'S' => items[0] = .{ .kind = .space },
            'n' => return self.node(.{ .kind = .char, .ch = '\n' }),
            'r' => return self.node(.{ .kind = .char, .ch = '\r' }),
            't' => return self.node(.{ .kind = .char, .ch = '\t' }),
            else => return self.node(.{ .kind = .char, .ch = escape }),
        }

        const negated = 'D' == escape or 'W' == escape or 'S' == escape;
        return self.node(.{ .kind = .class, .items = items, .negated = negated });
    }

    fn parseClass(self: *Parser) ParseError!*Node {
        self.pos += 1; // [

        var negated = false;
        if (!self.done() and '^' == self.peek()) {
            negated = true;
            self.pos += 1;
        }

        var items: std.ArrayList(ClassItem) = .empty;
        var first = true;

        while (!self.done()) {
            const ch = self.peek();

            if (']' == ch and !first) {
                self.pos += 1;
                return self.node(.{ .kind = .class, .items = items.items, .negated = negated });
            }
            first = false;

            if ('\\' == ch and self.pos + 1 < self.pattern.len) {
                const escape = self.pattern[self.pos + 1];
                self.pos += 2;
                try items.append(self.alloc, switch (escape) {
                    'd' => ClassItem{ .kind = .digit },
                    'w' => ClassItem{ .kind = .word },
                    's' => ClassItem{ .kind = .space },
                    'n' => ClassItem{ .kind = .char, .ch = '\n' },
                    'r' => ClassItem{ .kind = .char, .ch = '\r' },
                    't' => ClassItem{ .kind = .char, .ch = '\t' },
                    else => ClassItem{ .kind = .char, .ch = escape },
                });
                continue;
            }

            self.pos += 1;

            if (self.pos + 1 < self.pattern.len and '-' == self.pattern[self.pos] and
                ']' != self.pattern[self.pos + 1])
            {
                const upto = self.pattern[self.pos + 1];
                self.pos += 2;
                try items.append(self.alloc, .{ .kind = .range, .from = ch, .to = upto });
                continue;
            }

            try items.append(self.alloc, .{ .kind = .char, .ch = ch });
        }

        return ParseError.BadRegex;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const ch = self.peek();

        if ('(' == ch) {
            self.pos += 1;

            // Non-capturing group syntax is accepted and ignored.
            if (self.pos + 1 < self.pattern.len and '?' == self.pattern[self.pos] and
                ':' == self.pattern[self.pos + 1])
            {
                self.pos += 2;
            }

            const inner = try self.parseAlt();

            if (self.done() or ')' != self.peek()) {
                return ParseError.BadRegex;
            }
            self.pos += 1;

            return inner;
        }

        if ('[' == ch) {
            return self.parseClass();
        }

        if ('.' == ch) {
            self.pos += 1;
            return self.node(.{ .kind = .any });
        }

        if ('^' == ch) {
            self.pos += 1;
            return self.node(.{ .kind = .start });
        }

        if ('$' == ch) {
            self.pos += 1;
            return self.node(.{ .kind = .end });
        }

        if ('\\' == ch) {
            self.pos += 1;
            if (self.done()) {
                return ParseError.BadRegex;
            }
            const escape = self.peek();
            self.pos += 1;
            return self.escapeNode(escape);
        }

        self.pos += 1;
        return self.node(.{ .kind = .char, .ch = ch });
    }
};

// ---- matching --------------------------------------------------------

const FrameKind = enum { seq, repeat };

const Frame = struct {
    kind: FrameKind,
    nodes: []*Node = &.{},
    index: usize = 0,
    node: ?*const Node = null,
    count: usize = 0,
    prevpos: usize = 0,
    next: ?*const Frame = null,
};

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or '_' == ch;
}

fn classMatch(items: []const ClassItem, negated: bool, ch: u8) bool {
    var hit = false;

    for (items) |item| {
        const ok = switch (item.kind) {
            .char => ch == item.ch,
            .range => item.from <= ch and ch <= item.to,
            .digit => std.ascii.isDigit(ch),
            .word => isWord(ch),
            .space => std.ascii.isWhitespace(ch),
        };
        if (ok) {
            hit = true;
            break;
        }
    }

    return hit != negated;
}

fn runFrame(frame: ?*const Frame, text: []const u8, pos: usize) bool {
    const active = frame orelse return true;

    switch (active.kind) {
        .seq => {
            if (active.index >= active.nodes.len) {
                return runFrame(active.next, text, pos);
            }
            const nextframe = Frame{
                .kind = .seq,
                .nodes = active.nodes,
                .index = active.index + 1,
                .next = active.next,
            };
            return matchNode(active.nodes[active.index], text, pos, &nextframe);
        },
        .repeat => {
            const node = active.node.?;
            // A zero-width repeat would loop forever.
            if (pos == active.prevpos) {
                return active.count >= node.min and runFrame(active.next, text, pos);
            }
            return repeatStep(node, active.count, text, pos, active.next);
        },
    }
}

fn repeatStep(node: *const Node, count: usize, text: []const u8, pos: usize, next: ?*const Frame) bool {
    const canmore = if (node.max) |limit| count < limit else true;

    const frame = Frame{
        .kind = .repeat,
        .node = node,
        .count = count + 1,
        .prevpos = pos,
        .next = next,
    };

    const takemore = canmore and matchNode(node.inner.?, text, pos, &frame);
    const stopnow = count >= node.min and runFrame(next, text, pos);

    if (node.greedy) {
        return takemore or stopnow;
    }
    return stopnow or takemore;
}

fn matchNode(node: *const Node, text: []const u8, pos: usize, cont: ?*const Frame) bool {
    switch (node.kind) {
        .char => return pos < text.len and text[pos] == node.ch and runFrame(cont, text, pos + 1),
        .any => return pos < text.len and runFrame(cont, text, pos + 1),
        .class => return pos < text.len and classMatch(node.items, node.negated, text[pos]) and
            runFrame(cont, text, pos + 1),
        .start => return 0 == pos and runFrame(cont, text, pos),
        .end => return text.len == pos and runFrame(cont, text, pos),
        .seq => {
            const frame = Frame{ .kind = .seq, .nodes = node.kids, .index = 0, .next = cont };
            return runFrame(&frame, text, pos);
        },
        .alt => {
            for (node.kids) |branch| {
                if (matchNode(branch, text, pos, cont)) {
                    return true;
                }
            }
            return false;
        },
        .repeat => return repeatStep(node, 0, text, pos, cont),
    }
}

/// Is the pattern found anywhere in the text?
pub fn find(alloc: std.mem.Allocator, pattern: []const u8, text: []const u8) bool {
    var parser = Parser{ .alloc = alloc, .pattern = pattern };

    const root = parser.parseAlt() catch return false;
    if (!parser.done()) {
        return false;
    }

    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        if (matchNode(root, text, start, null)) {
            return true;
        }
    }

    return false;
}
