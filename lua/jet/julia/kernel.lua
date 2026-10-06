local Kernel = require("jet.core.kernel")

---@class julia.Kernel : jet.Kernel
local JuliaKernel = setmetatable({}, { __index = Kernel })
JuliaKernel.__index = JuliaKernel ---@private

---Modifies `kernel` in place.
---
---The filetype is set eagerly so the kernel can become the 'current' kernel
---(which enables jet's generic LSP, and with it runtime completion) as soon
---as the Lua client has started.
---@param kernel jet.Kernel
---@return julia.Kernel
JuliaKernel.from_kernel = function(kernel)
	local out = setmetatable(kernel, JuliaKernel)
	out.subclass = "julia"
	out.filetype = "julia"
	out.priority = 200
	return out
end

---@param k jet.Kernel
---@return boolean
JuliaKernel.matches = function(k) return k.spec ~= nil and k.spec.language == "julia" end

return JuliaKernel
