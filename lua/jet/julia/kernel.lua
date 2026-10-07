-- Kernel subclass conversion adapted from wurli/jet.ark,
-- lua/jet/ark/ark_kernel/init.lua:
-- https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/ark_kernel/init.lua
-- MIT License, Copyright (c) 2025 Jacob Scott. See LICENSES/jet.ark-MIT.txt.
-- Modified: Julia detection and deferred backend bootstrap; no Ark services.

local Kernel = require("jet.core.kernel")

---@class julia.Kernel : jet.Kernel
local JuliaKernel = setmetatable({}, { __index = Kernel })
JuliaKernel.__index = JuliaKernel ---@private

---@class (partial) jet.Kernel.Buffers
---@field vars julia.Vars

---Julia code which loads the bundled JetJulia service for the variables comm.
---@return string?
local variables_code = function()
	local bootstrap = require("jet.julia.bootstrap")

	local dir = vim.api.nvim_get_runtime_file("julia/JetJulia", false)[1]
	if not dir then
		vim.notify("jet.julia: could not find julia/JetJulia on the runtimepath", vim.log.levels.ERROR)
		return
	end
	return bootstrap.jetjulia_code(dir)
end

---Load JetJulia in the kernel, then open the variables comm.
---
---The comm must be opened only after JetJulia has registered its comm
---target; otherwise IJulia closes it.
---@param kernel julia.Kernel
local start_variables = function(kernel)
	local code = variables_code()
	if not code then
		return
	end

	require("jet.julia.bootstrap").run(kernel, code, function(ok, err)
		if not ok then
			vim.notify("jet.julia: failed to start JetJulia: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		vim.schedule(function() kernel.bufs.vars = require("jet.julia.vars").init(kernel) end)
	end)
end

---Convert an unsubclassed jet kernel in place and install the backend-start hook.
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

---Whether the kernelspec declares Julia; missing specs do not match.
---@param k jet.Kernel
---@return boolean
JuliaKernel.matches = function(k) return k.spec ~= nil and k.spec.language == "julia" end

return JuliaKernel
