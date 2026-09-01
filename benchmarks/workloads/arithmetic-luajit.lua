function kernel(x, y)
  return x*x + x*y + y*y + x*1.01 + y*1.02 + x*x*0.03 + x*y*0.04 + y*y*0.05 + x*0.06 + y*0.07 + x*x*0.08 + x*y*0.09 + y*y*0.10 + x*0.11 + y*0.12
end

local total = 0
for i = 1, 1000000 do
  total = total + kernel(i, 3)
end
print(total)
