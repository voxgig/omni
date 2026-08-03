# omni - Zig

Zig 0.16 port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```zig
const runner = try omni.makeRunner(alloc, io, path, provider);
const pack = try runner.runner("fib", null);

if (try pack.runset(pack.set("basic"), &FIB)) |failure| {
    std.debug.print("{s}\n", .{failure});
}
```

Zig has no exceptions, and its error values carry no payload, so a failing
check is **returned** as a message (`?[]const u8`, null when the set
passes). A subject reports failure the same way, with
`SubjectResult{ .err = message }`.

Zig has no closures either, so a `Subject` is a function pointer plus its
own `data` pointer - the same shape as the C port.

## Memory

Everything the runner allocates comes from the allocator passed to
`makeRunner`. Use an arena and free it once at the end; that is exactly the
shape of a test run.

## Layout

| File | Contents |
|---|---|
| `src/omni.zig` | the runner, plus clone/deep equality/path lookup/walk/stringify |
| `src/regex.zig` | a small backtracking regex engine |
| `test/fib.zig` | the system under test |
| `test/run.zig` | the shared conformance suite |

## Notes

- `std.json` provides parsing and the value model; the regex engine is
  in-tree, because Zig's standard library has none.
- Absence is the Zig optional: `?Json` with `null` meaning absent, as
  distinct from `Json{ .null = {} }`, a JSON null.
- Zig 0.16 needs cross-directory imports declared as named modules, so the
  Makefile builds with `--dep omni -Mroot=... -Momni=...`.
