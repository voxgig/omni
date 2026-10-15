-- RUN: lua5.4 test/ext.lua
-- RUN-SOME: lua5.4 test/ext.lua ctxargs
--
-- The capability suite: spec/ext.json requires ctxargs, fn and wait, and
-- every port that carries them runs it, beside the runner flag `all`.

package.path = 'src/?.lua;test/?.lua;' .. package.path

local runner = require('runner')
local u = require('util')
local fib = require('fib')

local ONLY = arg[1]
local PASSCOUNT = 0
local FAILCOUNT = 0

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

local function fibprovider()
  local subjects = {
    fib = FIB,
    fibseq = function(n) return fib.fibseq(n) end,
    fibrange = function(a, b) return fib.fibrange(a, b) end,
    fibinfo = function(n) return fib.fibinfo(n) end,
  }

  return {
    subject = function(name) return subjects[name] end,
    contextify = function(val)
      rawset(val, 'mark', 'CTX')
      return val
    end,
  }
end

-- The ctxargs subject: the context comes first, and must arrive
-- contextified with its client attached.
local function FIBSHIFTED(ctx, start, stop)
  if 'CTX' ~= u.get(ctx, 'mark') or u.isnone(u.get(ctx, 'client')) then
    error('fib: context not delivered', 0)
  end
  local shift = u.get(ctx, 'shift')
  return fib.fibrange(start + shift, stop + shift)
end

local function makerunner(spec)
  return runner.makeRunner(spec, fibprovider())('fib')
end

local function v1(requires, set)
  return u.map({
    OMNI = u.map({ version = 1, requires = u.list(requires) }),
    fib = u.map({ g = u.map({ set = u.list(set) }) }),
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

-- `pattern` is a Lua pattern, in which `.` also matches a newline.
local function refuses(fn, pattern)
  local ok, err = pcall(fn)

  if ok then
    error('omni: expected a failure', 0)
  end

  if not runner.isomnierror(err) then
    error(err, 0)
  end

  local msg = runner.errmessage(err)
  if nil == msg:find(pattern) then
    error('omni: message does not match [' .. pattern .. ']: ' .. msg, 0)
  end
end

local R = makerunner(specfile('ext.json'))

testcase('capabilities', function()
  for _, cap in ipairs({ 'ctxargs', 'fn', 'wait' }) do
    local found = false
    for _, have in ipairs(runner.CAPABILITIES) do
      found = found or have == cap
    end
    if not found then
      error('omni: capability missing: ' .. cap, 0)
    end
  end
end)

testcase('ctxargs', function() R.runset(R.set('ctxargs'), FIBSHIFTED) end)
testcase('fn', function() R.runset(R.set('fn'), FIB) end)
testcase('wait', function() R.runset(R.set('wait'), FIB) end)

testcase('a waiting entry that passes fails the set', function()
  local W = makerunner(v1({ 'wait' }, {
    u.map({ ['in'] = 5, out = 5, wait = u.map({ cause = 'gone#1' }) }),
  }))
  refuses(function() W.runset(W.set('g'), FIB) end, '%[0%]: stale wait: gone#1')
end)

testcase('the wait flag holds an entry by id', function()
  local W = makerunner(v1({}, {
    u.map({ id = 'a', ['in'] = 6, out = 9 }),
    u.map({ ['in'] = 7, out = 13 }),
  }))
  W.runsetflags(W.set('g'), { wait = { a = { cause = 'flag#1' } } }, FIB)
end)

testcase('the wait flag fails when its entry passes', function()
  local W = makerunner(v1({}, { u.map({ id = 'a', ['in'] = 6, out = 8 }) }))
  refuses(function()
    W.runsetflags(W.set('g'), { wait = { a = { cause = 'flag#1' } } }, FIB)
  end, 'stale wait: flag#1')
end)

testcase('the wait flag must name an entry', function()
  local W = makerunner(v1({}, { u.map({ id = 'a', ['in'] = 6, out = 8 }) }))
  refuses(function()
    W.runsetflags(W.set('g'), { wait = { zz = { cause = 'c' } } }, FIB)
  end, 'wait names no entry: zz')
end)

testcase('a wait needs a cause', function()
  local W = makerunner(v1({ 'wait' }, { u.map({ ['in'] = 6, out = 9, wait = u.map({}) }) }))
  refuses(function() W.runset(W.set('g'), FIB) end, 'entry wait has no cause')
end)

testcase('wait and fn are unknown fields unless required', function()
  local W = makerunner(v1({}, {
    u.map({ ['in'] = 6, out = 9, wait = u.map({ cause = 'c' }) }),
  }))
  refuses(function() W.runset(W.set('g'), FIB) end, 'unknown entry field: wait')
  local F = makerunner(v1({}, { u.map({ fn = 'fib', ['in'] = 6, out = 8 }) }))
  refuses(function() F.runset(F.set('g'), FIB) end, 'unknown entry field: fn')
end)

testcase('an unknown fn is a spec error', function()
  local F = makerunner(v1({ 'fn' }, { u.map({ fn = 'nope', ['in'] = 6, out = 8 }) }))
  refuses(function() F.runset(F.set('g'), FIB) end, 'unknown fn: nope')
end)

testcase('ctx with args needs ctxargs, and never takes in', function()
  local N = makerunner(v1({}, {
    u.map({ ctx = u.map({ shift = 0 }), args = u.list({ 0, 1 }), out = u.list({ 0, 1 }) }),
  }))
  refuses(function() N.runset(N.set('g'), FIBSHIFTED) end, 'more than one of in, args, ctx')
  local I = makerunner(v1({ 'ctxargs' }, {
    u.map({ ['in'] = 1, ctx = u.map({ shift = 0 }), out = u.list({ 0 }) }),
  }))
  refuses(function() I.runset(I.set('g'), FIBSHIFTED) end, 'entry has in beside args or ctx')
end)

testcase('a legacy spec ignores fn and wait', function()
  local L = makerunner(u.map({
    fib = u.map({ g = u.map({ set = u.list({
      u.map({ ['in'] = 6, out = 8, fn = 'nope', wait = u.map({ cause = 'c' }) }),
    }) }) }),
  }))
  L.runset(L.set('g'), FIB)
end)

testcase("a raising hook is the entry's error, not the set's", function()
  local provider = {
    subject = function() return FIB end,
    contextify = function() error('contextify boom', 0) end,
  }
  local function run(spec) return runner.makeRunner(spec, provider)('fib') end
  local E = run(v1({}, { u.map({ ctx = u.map({ n = 6 }), err = 'contextify boom' }) }))
  E.runset(E.set('g'), FIB)
  local U = run(v1({}, { u.map({ ctx = u.map({ n = 6 }), out = 8 }) }))
  refuses(function() U.runset(U.set('g'), FIB) end,
    '%[0%]: unexpected error\n%s+actual:%s+contextify boom')
  local W = run(v1({ 'wait' }, {
    u.map({ ctx = u.map({ n = 6 }), out = 8, wait = u.map({ cause = 'hook#1' }) }),
  }))
  W.runset(W.set('g'), FIB)
  local F = runner.makeRunner(v1({ 'fn' }, { u.map({ fn = 'boom', ['in'] = 6, err = 'subject boom' }) }), {
    subject = function(name)
      if 'boom' == name then
        error('subject boom', 0)
      end
      return FIB
    end,
  })('fib')
  F.runset(F.set('g'), FIB)
end)

testcase("a waiting entry holds a hook's error raised before the subject starts", function()
  local provider = {
    subject = function(name)
      if 'boom' == name then
        error('subject boom', 0)
      end
      if 'fib' == name then
        return FIB
      end
      return nil
    end,
  }
  local function run(spec) return runner.makeRunner(spec, provider)('fib') end
  local H = run(v1({ 'fn', 'wait' }, {
    u.map({ fn = 'boom', ['in'] = 6, out = 8, wait = u.map({ cause = 'hook#2' }) }),
  }))
  H.runset(H.set('g'), FIB)
  local S = run(v1({ 'fn', 'wait' }, {
    u.map({ fn = 'boom', ['in'] = 6, err = 'subject boom', wait = u.map({ cause = 'hook#3' }) }),
  }))
  refuses(function() S.runset(S.set('g'), FIB) end, '%[0%]: stale wait: hook#3')
end)

testcase('fn needs no default subject, but an entry without fn does', function()
  local provider = {
    subject = function(name)
      if 'fibx' == name then
        return FIB
      end
      return nil
    end,
  }
  local R = runner.makeRunner(v1({ 'fn' }, { u.map({ fn = 'fibx', ['in'] = 6, out = 8 }) }), provider)('fib')
  R.runset(R.set('g'))
  local N = runner.makeRunner(v1({ 'fn' }, {
    u.map({ fn = 'fibx', ['in'] = 6, out = 8 }),
    u.map({ ['in'] = 6, out = 8 }),
  }), provider)('fib')
  refuses(function() N.runset(N.set('g')) end, '^omni: no test subject for: fib$')
  local L = runner.makeRunner(v1({}, { u.map({ ['in'] = 6, out = 8 }) }), provider)('fib')
  refuses(function() L.runset(L.set('g')) end, '^omni: no test subject for: fib$')
end)

testcase('a wait is found by an id the entry owns, never an inherited one', function()
  local R = makerunner(v1({}, {
    u.map({ id = 'constructor', ['in'] = 6, out = 8 }),
    u.map({ id = 'toString', ['in'] = 7, out = 13 }),
  }))
  R.runset(R.set('g'), FIB)
  R.runsetflags(R.set('g'), { wait = {} }, FIB)
end)

testcase('all reports every failure at once', function()
  local A = makerunner(v1({}, {
    u.map({ ['in'] = 5, out = 6 }),
    u.map({ ['in'] = 6, out = 8 }),
    u.map({ ['in'] = 7, out = 14 }),
  }))
  refuses(function() A.runsetflags(A.set('g'), { all = true }, FIB) end,
    '^omni: fib: 2 of 3 entries failed\n.*fib%[0%]: result mismatch.*fib%[2%]: result mismatch')
  refuses(function() A.runset(A.set('g'), FIB) end, '^omni: fib%[0%]: result mismatch')
end)

print('\n' .. PASSCOUNT .. ' passed, ' .. FAILCOUNT .. ' failed')

os.exit(0 == FAILCOUNT and 0 or 1)
