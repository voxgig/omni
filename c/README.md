# omni - C

C99 port of the canonical TypeScript implementation.

```sh
make test
```

Builds with `-Wall -Wextra -Werror`.

## Use

```c
omni_pool *pool = omni_pool_new();
char *err = NULL;

omni_runner *runner = omni_make_runner(pool, "spec/fib.json", NULL, provider, &err);
omni_runpack *pack = omni_runner_run(runner, "fib", NULL, &err);

if (0 != omni_runset(pack, omni_set(pack, "basic"), subject, &err)) {
  printf("%s\n", err);
}

omni_pool_free(pool);
```

C has no exceptions: `omni_runset` returns non-zero and sets `*errout` to
the failure message. A subject returns `omni_result { val, err }` - a
non-NULL `err` is the message an `err` expectation matches.

## Memory

Every value comes from an `omni_pool` and is freed by one
`omni_pool_free`. Nothing else needs freeing, and nothing is freed twice.
A test runner is exactly the workload an arena suits: allocate freely,
release once at the end.

## Layout

| File | Contents |
|---|---|
| `src/omni.h` | the public API |
| `src/runner.c` | the runner |
| `src/util.c` | clone, deep equality, path lookup, walk, regex bridge |
| `src/json.c` | the pool allocator, JSON value model, parser and printer |
| `test/fib.c` | the system under test |
| `test/run.c` | the shared conformance suite |

## Notes

- C99 plus POSIX `<regex.h>`. No third-party libraries.
- Patterns are POSIX ERE. `\d`, `\w`, `\s` and their negations are
  translated to POSIX classes first; lookaround and lazy quantifiers are
  not available.
- There is no `OmniError` type - failures are messages. This is the one
  documented parity exemption (see `tools/check_parity.py`).
- `OMNI_ABSENT` is a value type, so "absent" and "null" are distinct.
