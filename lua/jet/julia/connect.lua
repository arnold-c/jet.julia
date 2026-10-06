local api = require("jet.api")
local JuliaKernel = require("jet.julia.kernel")

local M = {}

---Select a Julia kernel running in an external jet session, attach the Lua
---client, and make it the current Julia kernel.
---
---The generic jet LSP is deliberately left running: it provides the runtime
---completions. (Static analysis, e.g. JETLS, runs as a separate LSP.)
M.connect = function()
	api.list_kernels({ status = "external", predicate = JuliaKernel.matches }, function(kernels)
		if #kernels == 0 then
			vim.notify("jet.julia: no external Julia sessions found", vim.log.levels.WARN)
			return
		end

		vim.ui.select(kernels, {
			prompt = "Connect to Julia session",
			format_item = function(k) return k:friendly_name() end,
		}, function(k)
			if not k then
				return
			end
			k:start_lua_client(function() k:set_current() end)
		end)
	end)
end

return M
