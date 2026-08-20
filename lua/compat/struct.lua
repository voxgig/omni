--- Drop-in replacement for the in-situ test runner in the voxgig/struct
--- repository (`lua/test/runner.lua`).
---
--- struct's own runner and omni's runner implement the same spec format;
--- this module exposes omni behind struct's exact runner API, so a struct
--- port switches over by changing one require:
---
---   -local runnerModule = require("runner")
---   +local runnerModule = require("omni")
---
--- where `omni` is a small local-checkout resolver in the port's test
--- directory. Everything else - the corpus, the SDK, the test file - is
--- unchanged. This is the Lua peer of javascript/compat/struct.js,
--- python/voxgig_omni/compat/struct.py, ruby's and php's.
---
--- On register 4.12 - the seventeen entries carrying no `in`/`args`/`ctx`.
--- struct/lua's own runner DROPPED them outright ("Lua has no undefined
--- value; skip entries where 'in' or 'out' is absent"), which is why this
--- port reported a clean suite while never running them.
---
--- Lua can express the distinction, but not for free: omni models absence as
--- an explicit `ABSENT` sentinel table, because a Lua `nil` cannot be stored
--- in a table at all. So an absent `in` reaches the subject as one ABSENT
--- argument, not as zero arguments. `wrapsubject` below trims it, and struct
--- then sees the zero-arity call that `select('#', ...)` can tell from
--- `f(nil)`. That is this port's answer to 4.12 - the peer of python's
--- `zeroargs`, ruby's `undefargs`, go's NOVAL and php's stdClass singleton.

-- Prefixed, NOT bare. omni's own harness uses bare names because it runs
-- from `lua/` with only its own `src/` on the path; a consuming port has its
-- own modules there too, and struct/lua ships a `test/runner.lua` - exactly
-- the file this shim replaces. A bare `require('runner')` picks up whichever
-- comes first on package.path, which is luck, not design.
--
-- `src/util.lua` still does a bare `require('json')` internally, so the
-- resolver keeps omni's `lua/src/` on the path for that.
local u = require('src.util')
local Runner = require('src.runner')

local M = {}

M.NULLMARK = u.NULLMARK
M.EXISTSMARK = u.EXISTSMARK
M.JSON_NULL = u.NULL

--- The two value models, and the translation between them.
---
--- omni marks a list or a map by METATABLE IDENTITY (`json.list` / `json.map`
--- set a private metatable, and `islist`/`ismap` compare it with `==`).
--- struct/lua uses dkjson's convention instead: a `__jsontype` field of
--- "array" or "object" on whatever metatable the table happens to carry, and
--- it falls back to counting numeric keys for an unmarked table.
---
--- Neither recognises the other's marking, so every composite crossing the
--- boundary has to be re-tagged. Left alone, struct returns a table omni
--- cannot see into: `deepequal` refuses it and the failure prints as
--- "table: 0x55d82140f3c0".
---
--- Nulls differ too. Under `null = false` omni leaves its own NULL sentinel
--- in place - a table - so `typify(null)` in struct/lua answered 8256, "a
--- map", where the corpus wants 4194432. struct's runner passed a plain Lua
--- `nil` there, so that is what goes across.

local ARRAYMT = { __jsontype = 'array' }
local OBJECTMT = { __jsontype = 'object' }

--- omni's model -> struct's. Returns a second value: false when the argument
--- was omni's NULL, which has to become a real `nil` and so cannot be
--- returned in-band.
--- Returns `(value, kind)` where kind is 'value', 'null' or 'absent'. Three
--- states, not two: omni's NULL and ABSENT both become a Lua `nil`, but they
--- are NOT interchangeable at the call boundary - an absent argument becomes
--- the port's no-value, a null stays nil. Collapsing them made `typify(null)`
--- answer T_noval.
local function tostruct(val, seen)
  if u.NULL == val then
    return nil, 'null'
  end
  if u.ABSENT == val then
    return nil, 'absent'
  end
  if 'table' ~= type(val) then
    return val, 'value'
  end

  seen = seen or {}
  if nil ~= seen[val] then
    return seen[val], true
  end

  local islist = u.islist(val)
  local out = setmetatable({}, islist and ARRAYMT or OBJECTMT)
  seen[val] = out

  if islist then
    for index = 1, #val do
      local entry, kind = tostruct(val[index], seen)
      -- A null INSIDE a list has to stay a slot, or the list shortens.
      if 'value' == kind then
        out[index] = entry
      else
        out[index] = u.NULL
      end
    end
  else
    for key, entry in pairs(val) do
      local converted, kind = tostruct(entry, seen)
      if 'value' == kind then
        out[key] = converted
      end
    end
  end

  return out, 'value'
end

--- struct's model -> omni's.
local function toomni(val, seen)
  if 'table' ~= type(val) then
    return val
  end
  if u.NULL == val then
    return val
  end

  seen = seen or {}
  if nil ~= seen[val] then
    return seen[val]
  end

  -- struct marks with __jsontype and otherwise leaves the table plain, so an
  -- unmarked table is classified the way struct's own `isarray` does it: a
  -- table whose keys are all numeric is a list.
  local mt = getmetatable(val)
  local jsontype = mt and mt.__jsontype
  local islist
  if 'array' == jsontype then
    islist = true
  elseif 'object' == jsontype then
    islist = false
  else
    islist = true
    for key in pairs(val) do
      if 'number' ~= type(key) then
        islist = false
        break
      end
    end
  end

  local out = islist and u.list({}) or u.map({})
  seen[val] = out

  if islist then
    for index = 1, #val do
      out[index] = toomni(val[index], seen)
    end
  else
    for key, entry in pairs(val) do
      out[key] = toomni(entry, seen)
    end
  end

  return out
end

--- A subject that speaks struct's value model on the way in and omni's on the
--- way out. Arity is preserved exactly: `select('#', ...)` is what tells an
--- entry with no `in` (zero arguments) from one with `in: null` (one), which
--- is the whole reason this port needs no `zeroargs` equivalent.
local function wrapsubject(subject, noval)
  if nil == subject then
    return subject
  end
  return function(...)
    local count = select('#', ...)
    local args = table.pack(...)
    local converted, presence = {}, {}
    for index = 1, count do
      local value, kind = tostruct(args[index])
      -- NOT `kind and value or nil`: when `value` is `false` that whole
      -- expression is `nil`, so every `in: false` entry arrived as absent.
      presence[index] = ('absent' ~= kind)
      if 'value' == kind then
        converted[index] = value
      end
    end

    -- An absent argument becomes the port's own no-value, so `typify()` can
    -- answer T_noval where `typify(nil)` answers T_null. Without a sentinel
    -- there is nothing to send, so trailing absents shorten the call instead
    -- and the port sees a zero-arity call.
    if nil ~= noval then
      for index = 1, count do
        if not presence[index] then
          converted[index] = noval
        end
      end
    else
      while 0 < count and not presence[count] do
        count = count - 1
      end
    end

    local result = subject(table.unpack(converted, 1, count))
    -- The port's no-value IS omni's absent; a plain `nil` is its null.
    if nil ~= noval and noval == result then
      return u.ABSENT
    end
    if nil == result then
      return u.NULL
    end
    return toomni(result)
  end
end

--- struct/lua's own no-value sentinel, reached off the SDK. The shim never
--- imports struct, so this is the Lua peer of how the go shim finds NOVAL by
--- reflection. A port without one gets `nil`, and the shim falls back to
--- trimming the argument instead.
local function structnoval(client)
  local ok, utility = pcall(function()
    return client:utility()
  end)
  if not ok or nil == utility then
    return nil
  end
  local structutils = utility.struct
  if nil == structutils then
    return nil
  end
  return structutils.NOVAL
end

--- Read `name` off the SDK's utility the way struct's runner does.
local function lookup(utility, name)
  if nil == utility then
    return nil
  end
  local found = utility[name]
  if nil == found and nil ~= utility.struct then
    found = utility.struct[name]
  end
  return found
end

--- Wrap a struct SDK client as an omni provider.
local function structprovider(client)
  local provider = {}

  provider.sdk = client

  local noval = structnoval(client)

  provider.subject = function(name)
    return wrapsubject(lookup(client:utility(), name), noval)
  end

  -- A DEF.client entry becomes another SDK instance. struct's Lua client
  -- spells this `tester`, not `test`.
  provider.client = function(options)
    return structprovider(client:tester(options))
  end

  -- struct's runner hands the context BOTH `client` and `utility`; omni's
  -- resolveargs installs only `client`, so the utility is added here.
  provider.contextify = function(val)
    local utility = client:utility()
    local ctx = val
    if nil ~= utility.contextify then
      ctx = utility.contextify(val)
    end
    if u.ismap(ctx) then
      rawset(ctx, 'utility', utility)
    end
    return ctx
  end

  -- Client options may reference the runner store.
  provider.inject = function(options, store)
    local utility = client:utility()
    local structutils = utility and utility.struct
    if nil == structutils or nil == structutils.inject then
      return options
    end
    structutils.inject(options, store)
    return options
  end

  return provider
end

--- struct's makeRunner(testfile, client) signature, backed by omni.
function M.makeRunner(testfile, client)
  local provider = structprovider(client)
  local runner = Runner.makeRunner(testfile, provider)

  return function(name, store)
    local runpack = runner(name, store or {})

    -- A test file may pass its own subject; it speaks struct's model too.
    local noval = structnoval(client)
    local runsetflags = function(testspec, flags, testsubject)
      return runpack.runsetflags(testspec, flags, wrapsubject(testsubject, noval))
    end

    return {
      spec = runpack.spec,
      runset = function(testspec, testsubject)
        return runsetflags(testspec, {}, testsubject)
      end,
      runsetflags = runsetflags,
      subject = runpack.subject,
      -- struct's runner returned the SDK here, and its test file calls
      -- `client:utility()` on it. omni's runpack carries the PROVIDER in that
      -- slot, which has no such method - so hand back the SDK.
      client = client,
    }
  end
end

--- Convert NULLMARK sentinels back into real nulls.
---
--- NOT a delegation to omni's `nullmodifier`, deliberately. The two have
--- different shapes because they serve different callers: omni's RETURNS the
--- replacement value, while struct/lua's `inject` passes this as its `modify`
--- hook and expects it to MUTATE `parent[key]` in place and return nothing.
--- Delegating would quietly do nothing at all. It also has to write a real
--- Lua `nil` rather than omni's NULL sentinel, because that is what struct's
--- own modifier wrote and what the corpus expects to come back out.
function M.nullModifier(val, key, parent)
  if M.NULLMARK == val then
    parent[key] = nil
  elseif u.isstr(val) then
    parent[key] = (val:gsub(M.NULLMARK, 'null'))
  end
end

return M
