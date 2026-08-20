-- RUN: lua5.4 test/run.lua
-- RUN-SOME: lua5.4 test/run.lua basic
--
-- The Fibonacci conformance suite: every omni port runs this same set of
-- groups, from the same spec/fib.json, against the same fib library.
--
-- No third-party test framework: a failing omni check raises an OmniError
-- table, which busted or luaunit reports as a failure. This harness keeps
-- `make test` dependency-free.

package.path = 'src/?.lua;test/?.lua;' .. package.path

local runner = require('runner')
local u = require('util')
local fib = require('fib')

local ONLY = arg[1]
local PASSCOUNT = 0
local FAILCOUNT = 0

-- Find the shared spec directory by walking up from the working directory.
local function specfile(name)
  local dir = '.'

  for _ = 1, 8 do
    local cand = dir .. '/spec/' .. name
    local handle = io.open(cand, 'r')
    if nil ~= handle then
      handle:close()
      return cand
    end
    dir = dir .. '/..'
  end

  error('omni: spec not found: ' .. name, 0)
end

local function FIB(n) return fib.fib(n) end
local function FIBSEQ(n) return fib.fibseq(n) end
local function FIBRANGE(a, b) return fib.fibrange(a, b) end
local function FIBINFO(n) return fib.fibinfo(n) end

-- The provider hosts the system under test. `shift` offsets the Fibonacci
-- index, so that a client-specific subject is observably different.
-- `contextify` marks the map, so the context group can prove the hook ran.
local function fibprovider(shift)
  local subjects = {
    fib = function(n)
      if u.isnum(n) then
        return fib.fib(n + shift)
      end
      return fib.fib(n)
    end,
    fibseq = FIBSEQ,
    fibrange = FIBRANGE,
    fibinfo = FIBINFO,
  }

  return {
    subject = function(name) return subjects[name] end,
    client = function(options)
      local shiftval = u.get(options, 'shift')
      return fibprovider(u.isnum(shiftval) and shiftval or 0)
    end,
    contextify = function(val)
      rawset(val, 'mark', 'CTX')
      return val
    end,
  }
end

-- The context-group subject: reports what the runner delivered - the
-- contextify mark and the attached client - as plain data, so the spec can
-- pin both with an ordinary `out` comparison in every port.
-- A subject that returns the literal string "__UNDEF__" as ordinary data,
-- to prove the absent sentinel no longer accepts its own literal.
local function FIBUNDEF(_n)
  return u.map({ a = '__UNDEF__' })
end

local function FIBCTX(ctx)
  return u.map({
    n = u.get(ctx, 'n'),
    val = fib.fib(u.get(ctx, 'n')),
    mark = u.get(ctx, 'mark'),
    hasclient = not u.isabsent(u.get(ctx, 'client')),
  })
end

local function testcase(name, body)
  if nil ~= ONLY and name ~= ONLY then
    return
  end

  local ok, err = pcall(body)

  if ok then
    PASSCOUNT = PASSCOUNT + 1
    print('ok   - ' .. name)
  else
    FAILCOUNT = FAILCOUNT + 1
    print('FAIL - ' .. name)
    print(runner.errmessage(err))
  end
end

-- The runner must fail when the subject is wrong - otherwise a green suite
-- means nothing.
local function badspec()
  return u.map({
    fib = u.map({
      wrongout = u.map({ set = u.list({
        u.map({ ['in'] = 5, out = 5 }),
        u.map({ ['in'] = 6, out = 999 }),
      }) }),
      wrongerr = u.map({ set = u.list({
        u.map({ ['in'] = 1, err = 'never happens' }),
      }) }),
      wrongmatch = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = 999 }) }),
      }) }),
      missing = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = u.map({ nope = '__EXISTS__' }) }) }),
      }) }),
      -- A concrete match leaf against a missing key must fail, not
      -- substring-match the text "undefined".
      matchabsent = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = u.map({ nope = 'fine' }) }) }),
      }) }),
      -- __UNDEF__ (absent) must not be satisfied by a present null.
      undefonnull = u.map({ set = u.list({
        u.map({ ['in'] = 0, match = u.map({ out = u.map({ prev = '__UNDEF__' }) }) }),
      }) }),
      -- __NULL__ (present null) must not be satisfied by an absent key.
      nullonabsent = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = u.map({ nope = '__NULL__' }) }) }),
      }) }),
      -- A literal "__UNDEF__" in the data must not satisfy the absent
      -- sentinel: the sentinel is tested before the identity check.
      wrongundef = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = u.map({ a = '__UNDEF__' }) }) }),
      }) }),
      -- An empty-string want is not a wildcard substring match.
      emptystr = u.map({ set = u.list({
        u.map({ ['in'] = 6, match = u.map({ out = u.map({ label = '' }) }) }),
      }) }),
    }),
  })
end

local function expectfail(setname, subject)
  local bad = runner.makeRunner(badspec())('fib')
  local ok, err = pcall(function() bad.runset(bad.set(setname), subject) end)

  if ok then
    error('omni: expected a failure for set: ' .. setname, 0)
  end

  if not runner.isomnierror(err) then
    error(err, 0)
  end
end

-- Run `fn` and assert it raises an OmniError whose message contains
-- `wantsubstr` - used by the version/strict-validation negative tests,
-- which (unlike `expectfail`) pin the failure reason, not just the fact of
-- failure.
local function expectmsg(fn, wantsubstr)
  local ok, err = pcall(fn)

  if ok then
    error('omni: expected a failure', 0)
  end

  if not runner.isomnierror(err) then
    error(err, 0)
  end

  local msg = runner.errmessage(err)
  if nil == msg:find(wantsubstr, 1, true) then
    error('omni: message missing [' .. wantsubstr .. ']: ' .. msg, 0)
  end
end

local function checkmessage()
  local spec = u.map({
    fib = u.map({
      g = u.map({ set = u.list({
        u.map({ ['in'] = 1, out = 1 }),
        u.map({ id = 'x#2', ['in'] = 2, out = 42 }),
      }) }),
    }),
  })

  local bad = runner.makeRunner(spec)('fib')
  local ok, err = pcall(function() bad.runset(bad.set('g'), FIB) end)

  if ok then
    error('omni: expected a failure', 0)
  end

  local msg = runner.errmessage(err)
  for _, want in ipairs({ 'fib[1] (x#2)', 'expected: 42', 'actual:   1' }) do
    if nil == msg:find(want, 1, true) then
      error('omni: message missing [' .. want .. ']: ' .. msg, 0)
    end
  end
end

local R = runner.makeRunner(specfile('fib.json'), fibprovider(0))('fib')

testcase('basic', function() R.runset(R.set('basic'), FIB) end)
testcase('seq', function() R.runset(R.set('seq'), FIBSEQ) end)
testcase('range', function() R.runset(R.set('range'), FIBRANGE) end)
testcase('info', function() R.runset(R.set('info'), FIBINFO) end)
testcase('nulls', function() R.runsetflags(R.set('nulls'), { null = false }, FIBINFO) end)
testcase('error', function() R.runset(R.set('error'), FIB) end)
testcase('match', function() R.runset(R.set('match'), FIB) end)
testcase('matchinfo', function() R.runset(R.set('matchinfo'), FIBINFO) end)
testcase('client', function() R.runset(R.set('client'), FIB) end)
testcase('context', function() R.runset(R.set('context'), FIBCTX) end)

testcase('detects wrong result', function() expectfail('wrongout', FIB) end)
testcase('detects missing error', function() expectfail('wrongerr', FIB) end)
testcase('detects failed match', function() expectfail('wrongmatch', FIB) end)
testcase('detects absent key', function() expectfail('missing', FIBINFO) end)
testcase('a concrete match leaf does not match a missing key',
  function() expectfail('matchabsent', FIBINFO) end)
testcase('__UNDEF__ does not match a present null',
  function() expectfail('undefonnull', FIBINFO) end)
testcase('__NULL__ does not match an absent key',
  function() expectfail('nullonabsent', FIBINFO) end)
testcase('an empty-string match leaf is not a wildcard',
  function() expectfail('emptystr', FIBINFO) end)
testcase('__UNDEF__ does not match a literal "__UNDEF__" in the data',
  function() expectfail('wrongundef', FIBUNDEF) end)

testcase('rejects an unsupported spec version', function()
  expectmsg(function()
    runner.makeRunner(u.map({
      OMNI = u.map({ version = 99 }),
      fib = u.map({ g = u.map({ set = u.list({}) }) }),
    }))
  end, 'unsupported spec version')
end)

testcase('rejects an unknown required capability', function()
  expectmsg(function()
    runner.makeRunner(u.map({
      OMNI = u.map({ version = 1, requires = u.list({ 'nosuchfeature' }) }),
      fib = u.map({ g = u.map({ set = u.list({}) }) }),
    }))
  end, 'unsupported capability')
end)

testcase('rejects a malformed version block', function()
  expectmsg(function()
    runner.makeRunner(u.map({
      OMNI = u.map({ version = 'one' }),
      fib = u.map({ g = u.map({ set = u.list({}) }) }),
    }))
  end, 'malformed OMNI')
end)

testcase('strict: an unknown entry field fails instead of passing vacuously', function()
  local bad = runner.makeRunner(u.map({
    OMNI = u.map({ version = 1 }),
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = 6, matches = u.map({ out = 999 }) }),
    }) }) }),
  }))('fib')
  expectmsg(function() bad.runset(bad.set('g'), FIBINFO) end, 'unknown entry field: matches')
end)

testcase('strict: more than one of in, args, ctx fails', function()
  local bad = runner.makeRunner(u.map({
    OMNI = u.map({ version = 1 }),
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = 5, args = u.list({ 5 }), out = 5 }),
    }) }) }),
  }))('fib')
  expectmsg(function() bad.runset(bad.set('g'), FIB) end, 'more than one of in, args, ctx')
end)

testcase('strict: err together with out fails', function()
  local bad = runner.makeRunner(u.map({
    OMNI = u.map({ version = 1 }),
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = -1, err = true, out = 5 }),
    }) }) }),
  }))('fib')
  expectmsg(function() bad.runset(bad.set('g'), FIB) end, 'both err and out')
end)

testcase('strict: a null id fails even under null-normalisation', function()
  local bad = runner.makeRunner(u.map({
    OMNI = u.map({ version = 1 }),
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = 1, out = 1, id = u.NULL }),
    }) }) }),
  }))('fib')
  expectmsg(function() bad.runset(bad.set('g'), FIB) end, 'entry id is not a string')
end)

testcase('strict: an empty set fails unless marked empty', function()
  local bad = runner.makeRunner(u.map({
    OMNI = u.map({ version = 1 }),
    fib = u.map({
      g = u.map({ set = u.list({}) }),
      h = u.map({ set = u.list({}), empty = true }),
    }),
  }))('fib')
  expectmsg(function() bad.runset(bad.set('g'), FIB) end, 'empty test set')
  bad.runset(bad.set('h'), FIB)
end)

testcase('a legacy spec (no OMNI block) stays lenient', function()
  local bad = runner.makeRunner(u.map({
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = 6, matches = u.map({ out = 999 }), out = 8 }),
    }) }) }),
  }))('fib')
  bad.runset(bad.set('g'), FIB)
end)

testcase('reports entry index and id', checkmessage)

print('\n' .. PASSCOUNT .. ' passed, ' .. FAILCOUNT .. ' failed')

os.exit(0 == FAILCOUNT and 0 or 1)
