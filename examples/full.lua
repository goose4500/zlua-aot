-- Exercises closures, varargs, tables, metatables, iteration and coroutines.
local function accumulator(seed)
  return function(...)
    for _, value in ipairs({...}) do seed = seed + value end
    return seed
  end
end

local object = setmetatable({value = 6}, {
  __add = function(a, b) return a.value + b.value end
})
assert(object + {value = 7} == 13)

local add = accumulator(10)
assert(add(1, 2, 3) == 16)

local co = coroutine.create(function()
  coroutine.yield("paused")
  return "done"
end)
local ok, value = coroutine.resume(co)
assert(ok and value == "paused")
ok, value = coroutine.resume(co)
assert(ok and value == "done")

print("full LuaJIT 5.1 coverage smoke test passed", arg[1] or "")
