--@aot-number
function square_add(x, y)
  return x * x + y
end

local total = 0
for i = 1, 5000000 do
  total = total + square_add(i, 3)
end
print(total)
