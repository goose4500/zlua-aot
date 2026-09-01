-- This function is compiled to a guarded native C function.
--@aot-number
function square_add(x, y)
    return x * x + y
end

-- The surrounding chunk remains fully dynamic LuaJIT code.
local dynamic = { value = square_add(4, 2) }
assert(dynamic.value == 18)
assert(type(square_add) == "function")

-- Strings fail the native number guards and execute the preserved Lua body.
assert(square_add("3", 1) == 10)
print("hybrid function AOT smoke test passed", dynamic.value)
