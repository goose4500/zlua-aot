-- The empty block intentionally makes the whole chunk ineligible for the
-- numeric backend without adding meaningful work at runtime.
do end
local x = 3.0
local y = 7.0
x = x * x + y / 2
print(x)
