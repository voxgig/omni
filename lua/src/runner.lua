-- Omni: the shared multi-language test runner (Lua port).
--
-- Port of the canonical TypeScript implementation
-- (typescript/src/Runner.ts). Behaviour must match, case for case.

local regex = require('regex')
local u = require('util')

local M = {}

M.NULLMARK = u.NULLMARK
M.UNDEFMARK = u.UNDEFMARK
M.EXISTSMARK = u.EXISTSMARK
M.NULL = u.NULL
M.ABSENT = u.ABSENT

-- A test failure (or a malformed spec). Raised as a table, so that errors
-- raised by the subject under test (plain strings) stay distinguishable.
local OMNIMT = { __tostring = function(err) return err.message end }

function M.OmniError(message, entry)
  return setmetatable({ omni = true, message = message, entry = entry }, OMNIMT)
end

function M.isomnierror(err)
  return 'table' == type(err) and true == err.omni
end

--- The message an `err` expectation matches.
function M.errmessage(err)
  if M.isomnierror(err) then
    return err.message
  end
  if 'table' == type(err) and nil ~= err.message then
    return tostring(err.message)
  end
  return tostring(err)
end

--- Load a spec: a path to a JSON file.
function M.loadspec(path)
  local handle = io.open(path, 'r')
  if nil == handle then
    error(M.OmniError('omni: cannot read spec: ' .. path))
  end

  local text = handle:read('a')
  handle:close()

  return u.parse(text)
end

--- Find `primary.<name>`, then `<name>`, then the whole spec.
function M.resolvespec(name, alltests)
  if nil == name or '' == name then
    return alltests
  end

  local primary = u.get(u.get(alltests, 'primary'), name)
  if not u.isabsent(primary) then
    return primary
  end

  local section = u.get(alltests, name)
  if not u.isabsent(section) then
    return section
  end

  return alltests
end

--- Nulls (and absent values) become NULLMARK. Always a fresh copy.
function M.fixjson(val, donull)
  if u.isnone(val) then
    if donull then
      return u.NULLMARK
    end
    return u.NULL
  end

  if u.islist(val) then
    local out = u.list({})
    for index, entry in ipairs(val) do
      out[index] = M.fixjson(entry, donull)
    end
    return out
  end

  if u.ismap(val) then
    local out = u.map({})
    for key, entry in pairs(val) do
      rawset(out, key, M.fixjson(entry, donull))
    end
    return out
  end

  return val
end

--- The JSON form of an error: always at least {name,message}.
function M.errify(err)
  return u.map({ name = 'Error', message = M.errmessage(err) })
end

--- Match one leaf: /regex/ or case-insensitive substring for strings.
function M.matchval(check, base)
  if u.deepequal(check, base) then
    return true
  end

  local want = check
  if u.NULLMARK == want or u.UNDEFMARK == want then
    want = u.NULL
  end

  if u.isnone(want) then
    return u.isnone(base) or u.NULLMARK == base
  end

  if u.isstr(want) then
    local basestr = u.stringify(base)

    if 2 < #want and '/' == want:sub(1, 1) and '/' == want:sub(-1) then
      return regex.find(want:sub(2, #want - 1), basestr)
    end

    return nil ~= basestr:lower():find(want:lower(), 1, true)
  end

  return u.deepequal(want, base)
end

--- Convert NULLMARK sentinels back into real nulls.
function M.nullmodifier(val)
  if u.NULLMARK == val then
    return u.NULL
  end
  if u.isstr(val) then
    return (val:gsub(u.NULLMARK, 'null'))
  end
  return val
end

-- The spec-defined part of an entry (drop runner bookkeeping).
local function entrysummary(entry)
  local out = u.map({})
  for key, value in pairs(entry) do
    if 'res' ~= key and 'thrown' ~= key and 'ctx' ~= key then
      rawset(out, key, value)
    end
  end
  return out
end

-- The label of one entry, for failure messages.
local function entryref(label, index, entry)
  local id = u.get(entry, 'id')
  local idpart = u.isabsent(id) and '' or (' (' .. u.stringify(id) .. ')')
  return label .. '[' .. index .. ']' .. idpart
end

local function fail(label, index, entry, reason, expected, actual)
  local msg = 'omni: ' .. entryref(label, index, entry) .. ': ' .. reason

  if nil ~= expected then
    msg = msg .. '\n  expected: ' .. expected
  end
  if nil ~= actual then
    msg = msg .. '\n  actual:   ' .. actual
  end

  msg = msg .. '\n  entry:    ' .. u.stringify(entrysummary(entry))

  return M.OmniError(msg, entry)
end

-- Check that every leaf of `check` is present, and matches, in `base`.
local function matchcheck(label, index, entry, check, base, path)
  path = path or {}

  if u.islist(check) then
    for at, subcheck in ipairs(check) do
      local childpath = { table.unpack(path) }
      childpath[#childpath + 1] = tostring(at - 1)
      matchcheck(label, index, entry, subcheck, base, childpath)
    end
    return
  end

  if u.ismap(check) then
    for key, subcheck in pairs(check) do
      local childpath = { table.unpack(path) }
      childpath[#childpath + 1] = key
      matchcheck(label, index, entry, subcheck, base, childpath)
    end
    return
  end

  local baseval = u.getpath(base, path)

  local ok = u.deepequal(check, baseval)
    or (u.UNDEFMARK == check and u.isabsent(baseval))
    or (u.EXISTSMARK == check and not u.isnone(baseval))
    or M.matchval(check, baseval)

  if not ok then
    local where = 0 == #path and '<root>' or u.pathify(path)
    error(fail(label, index, entry, 'match failed at ' .. where,
      u.stringify(check), u.stringify(baseval)))
  end
end

M.match = matchcheck

local function checkresult(label, index, entry, args, res)
  local matched = false

  local entryerr = u.get(entry, 'err')
  if not u.isnone(entryerr) then
    error(fail(label, index, entry, 'expected error did not occur',
      u.stringify(entryerr), u.stringify(res)))
  end

  local check = u.get(entry, 'match')
  if not u.isnone(check) then
    local base = u.map({
      ['in'] = u.get(entry, 'in'),
      args = u.list(args),
      out = u.get(entry, 'res'),
      ctx = u.get(entry, 'ctx'),
    })
    matchcheck(label, index, entry, check, base)
    matched = true
  end

  local out = u.get(entry, 'out')

  if u.deepequal(res, out) then
    return
  end

  -- NOTE: a match with no explicit out is a complete check on its own.
  if matched and (u.isnone(out) or u.NULLMARK == out) then
    return
  end

  error(fail(label, index, entry, 'result mismatch', u.stringify(out), u.stringify(res)))
end

local function handleerror(label, index, entry, err)
  local entryerr = u.get(entry, 'err')

  if not u.isnone(entryerr) then
    if true == entryerr or M.matchval(entryerr, M.errmessage(err)) then
      local check = u.get(entry, 'match')
      if not u.isnone(check) then
        local base = u.map({
          ['in'] = u.get(entry, 'in'),
          out = u.get(entry, 'res'),
          ctx = u.get(entry, 'ctx'),
          err = M.errify(err),
        })
        matchcheck(label, index, entry, check, base)
      end
      return
    end

    error(fail(label, index, entry, 'error mismatch',
      u.stringify(entryerr), M.errmessage(err)))
  end

  error(fail(label, index, entry, 'unexpected error', nil, M.errmessage(err)))
end

-- Build the argument list: `ctx`, `args`, or `in`.
local function resolveargs(entry, provider)
  local args

  local hasctx = u.has(entry, 'ctx')
  local hasargs = u.has(entry, 'args')

  if hasctx then
    args = { u.get(entry, 'ctx') }
  elseif hasargs then
    local raw = u.get(entry, 'args')
    args = {}
    for index, value in ipairs(raw) do
      args[index] = value
    end
  else
    args = { u.clone(u.get(entry, 'in')) }
  end

  if (hasctx or hasargs) and 0 < #args and u.ismap(args[1]) then
    local first = u.clone(args[1])
    if nil ~= provider.contextify then
      first = provider.contextify(first)
    end
    args[1] = first
    rawset(entry, 'ctx', first)
  end

  return args
end

--- Make a runner for a spec file path (or spec value) and a provider.
function M.makeRunner(specref, provider)
  local alltests = u.isstr(specref) and M.loadspec(specref) or specref
  local useprovider = provider or {}

  return function(name, store)
    local spec = M.resolvespec(name, alltests)
    local clients = {}

    local defclient = u.get(u.get(spec, 'DEF'), 'client')

    -- A spec may define clients that a given test run never references.
    if u.ismap(defclient) and nil ~= useprovider.client then
      for clientname, cdef in pairs(defclient) do
        local copts = u.get(u.get(cdef, 'test'), 'options')
        if u.isabsent(copts) then
          copts = u.map({})
        end
        if nil ~= useprovider.inject and u.ismap(store) then
          copts = useprovider.inject(copts, store)
        end
        clients[clientname] = useprovider.client(copts)
      end
    end

    local subject = nil
    if nil ~= useprovider.subject and nil ~= name then
      subject = useprovider.subject(name)
    end

    local runpack = {
      spec = spec,
      subject = subject,
      client = useprovider,
    }

    runpack.set = function(setname)
      return u.get(spec, setname)
    end

    runpack.runsetflags = function(testspec, flags, testsubject)
      flags = flags or {}
      local donull = nil == flags.null and true or (true == flags.null)
      local label = flags.name or ((nil == name or '' == name) and 'set' or name)

      local usesubject = testsubject or subject
      if nil == usesubject then
        error(M.OmniError('omni: no test subject for: ' .. label))
      end

      local testspecmap = M.fixjson(testspec, donull)
      local testset = u.get(testspecmap, 'set')

      if not u.islist(testset) then
        error(M.OmniError('omni: test spec has no set: ' .. label))
      end

      for at, entry in ipairs(testset) do
        local index = at - 1

        if not u.ismap(entry) then
          error(M.OmniError('omni: ' .. label .. '[' .. index .. ']: entry is not a map'))
        end

        -- An entry with no `out` expects a null (or absent) result.
        if donull and u.isnone(u.get(entry, 'out')) then
          rawset(entry, 'out', u.NULLMARK)
        end

        local entrysubject = usesubject
        local clientname = u.get(entry, 'client')

        if u.isstr(clientname) then
          local client = clients[clientname]
          if nil == client then
            error(M.OmniError('omni: unknown client: ' .. clientname, entry))
          end
          if nil ~= client.subject then
            local clientsubject = client.subject(name)
            if nil ~= clientsubject then
              entrysubject = clientsubject
            end
          end
        end

        local args = resolveargs(entry, useprovider)

        local ok, result = pcall(entrysubject, table.unpack(args))

        if ok then
          local res = M.fixjson(result, donull)
          rawset(entry, 'res', res)
          checkresult(label, index, entry, args, res)
        elseif M.isomnierror(result) then
          error(result)
        else
          handleerror(label, index, entry, result)
        end
      end
    end

    runpack.runset = function(testspec, testsubject)
      return runpack.runsetflags(testspec, {}, testsubject)
    end

    return runpack
  end
end

return M
