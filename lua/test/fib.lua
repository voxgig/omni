-- The system under test: a tiny Fibonacci library.
--
-- Every omni port ships this same library, with the same behaviour and the
-- same error messages, and tests it with the same spec file
-- (spec/fib.json).

local u = require('util')

local M = {}

--- Validate a Fibonacci index. The spec matches on these messages.
function M.fibindex(val)
  if not u.isnum(val) then
    error('fib: not a number: ' .. u.stringify(val), 0)
  end

  if val ~= math.floor(val) then
    error('fib: non-integer index: ' .. u.stringify(val), 0)
  end

  if 0 > val then
    error('fib: negative index: ' .. u.stringify(val), 0)
  end

  return math.floor(val)
end

--- The nth Fibonacci number: fib(0)=0, fib(1)=1.
function M.fibnum(index)
  if 0 == index then
    return 0
  end

  local prev = 0
  local cur = 1

  for _ = 1, index - 1 do
    prev, cur = cur, prev + cur
  end

  return cur
end

function M.fib(val)
  return M.fibnum(M.fibindex(val))
end

--- The first n Fibonacci numbers.
function M.fibseq(val)
  local count = M.fibindex(val)
  local out = u.list({})
  for index = 0, count - 1 do
    out[#out + 1] = M.fibnum(index)
  end
  return out
end

--- The Fibonacci numbers from index start to index end, inclusive.
function M.fibrange(start, stop)
  local from = M.fibindex(start)
  local to = M.fibindex(stop)
  local out = u.list({})
  for index = from, to do
    out[#out + 1] = M.fibnum(index)
  end
  return out
end

--- A description of the nth Fibonacci number. `prev` is null at index 0,
--- which exercises the runner's null handling.
function M.fibinfo(val)
  local index = M.fibindex(val)
  local num = M.fibnum(index)

  return u.map({
    n = index,
    val = num,
    even = 0 == num % 2,
    prev = 0 == index and u.NULL or M.fibnum(index - 1),
    label = 'fib(' .. u.numstr(index) .. ')=' .. u.numstr(num),
  })
end

return M
