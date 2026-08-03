# omni - Lua

Lua 5.4 port of the canonical TypeScript implementation.

```sh
lua5.4 test/run.lua
```

## Use

```lua
local runner = require('runner')

local provider = { subject = function(name) return subjects[name] end }

local R = runner.makeRunner(specpath, provider)('fib')

R.runset(R.set('basic'), FIB)
R.runsetflags(R.set('nulls'), { null = false }, FIBINFO)
```

A failing check raises an OmniError table, which busted or luaunit reports
as a failure. Use `runner.isomnierror(err)` to tell a test failure from a
subject error.

## Layout

| File | Contents |
|---|---|
| `src/runner.lua` | the runner |
| `src/util.lua` | clone, deep equality, path lookup, walk, stringify |
| `src/json.lua` | the JSON value model and parser |
| `src/regex.lua` | a small backtracking regex engine |
| `test/fib.lua` | the system under test |
| `test/run.lua` | the shared conformance suite |

## Notes

- **No dependencies at all.** Lua has neither JSON nor regular expressions
  (its patterns have no alternation or grouping), so the port carries both.
- Lua tables cannot hold `nil`, and cannot tell an empty list from an empty
  map. The value model is therefore explicit: `u.NULL` and `u.ABSENT` are
  sentinel values, and every container is tagged by `u.map{}` / `u.list{}`.
  A subject that returns a map or list must build it with those.
