local Kernel = require("jet.core.kernel")
local config = require("jet.julia.config")

---@class julia.Kernel : jet.Kernel
local JuliaKernel = setmetatable({}, { __index = Kernel })
JuliaKernel.__index = JuliaKernel ---@private

---@class (partial) jet.Kernel.Buffers
---@field vars julia.Vars

---Load Positron.jl in the kernel, then open the variables comm.
---
---The comm must be opened only after Positron has registered its comm
---targets; otherwise IJulia closes it.
---@param kernel julia.Kernel
local start_variables = function(kernel)
	local positron_path = config.options.positron_path
	if not positron_path then
		vim.notify("jet.julia: set `positron_path` to enable the variables pane", vim.log.levels.WARN)
		return
	end

	local bootstrap = require("jet.julia.bootstrap")
	bootstrap.run(kernel, bootstrap.positron_code(positron_path), function(ok, err)
		if not ok then
			vim.notify("jet.julia: failed to load Positron.jl: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		vim.schedule(function() kernel.bufs.vars = require("jet.julia.vars").init(kernel) end)
	end)
end

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
	out.hooks.on_lua_client_start.start_variables = start_variables
	return out
end

---@param k jet.Kernel
---@return boolean
JuliaKernel.matches = function(k) return k.spec ~= nil and k.spec.language == "julia" end

return JuliaKernel
