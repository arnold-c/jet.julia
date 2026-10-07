-- Setup guard and variables-command pattern adapted from wurli/jet.ark,
-- lua/jet/ark/init.lua:
-- https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/init.lua
-- MIT License, Copyright (c) 2025 Jacob Scott. See LICENSES/jet.ark-MIT.txt.
-- Modified: keyed Julia kernel hook and Julia-specific commands/configuration.

local M = {}

---Ask jet to resolve/select a connected Julia kernel and invoke callback.
---@param callback fun(k: julia.Kernel)
local with_julia_kernel = function(callback)
	require("jet.api").get_kernel({
		status = "connected",
		predicate = function(k) return k.subclass == "julia" end,
	}, callback)
end

---View a variable or dotted access-key path in a connected Julia kernel.
---Reject empty path components; never evaluate arbitrary Julia expressions.
---Requires JetJulia's viewer_page extension (not the Positron.jl backend).
---@param name string
M.open_view = function(name)
	local path = vim.split(name, ".", { plain = true })
	for _, part in ipairs(path) do
		if part == "" then
			vim.notify("jet.julia: provide a variable name, e.g. :JuliaView df", vim.log.levels.WARN)
			return
		end
	end
	with_julia_kernel(function(k) require("jet.julia.view").open(k, path) end)
end

---Open/refresh the connected Julia kernel's pane, or warn if bootstrap is not ready.
M.open_vars = function()
	with_julia_kernel(function(k)
		if k.bufs.vars then
			k.bufs.vars:open()
		else
			vim.notify("jet.julia: variables pane is not available for this kernel", vim.log.levels.WARN)
		end
	end)
end

---Configure the plugin, register commands and install the keyed kernel-init hook.
---jet.nvim setup must have completed first. Only new, unsubclassed Julia
---kernels are converted by the hook; existing viewers keep their keymaps.
---@param opts? jet.julia.Config
M.setup = function(opts)
	local jet = require("jet")
	assert(jet.did_setup(), 'jet.nvim has not done setup; run `require("jet").setup({})` before loading jet.julia')

	require("jet.julia.config").set(opts)

	vim.api.nvim_create_user_command("JuliaView", function(args)
		M.open_view(args.args ~= "" and args.args or vim.fn.expand("<cword>"))
	end, { nargs = "?", desc = "View a Julia table or 1D–3D array (variable or dotted path)" })

	local JuliaKernel = require("jet.julia.kernel")

	-- Keyed (not `table.insert`ed) so that re-running setup is idempotent.
	jet.hooks.on_kernel_init.jet_julia = function(k)
		if not k.subclass and JuliaKernel.matches(k) then
			JuliaKernel.from_kernel(k)
		end
	end

	vim.api.nvim_create_user_command(
		"JetJuliaConnect",
		function() require("jet.julia.connect").connect() end,
		{ nargs = 0, desc = "Attach to an external jet Julia session" }
	)

	vim.api.nvim_create_user_command(
		"JuliaVars",
		function() M.open_vars() end,
		{ nargs = 0, desc = "Open the Julia variables pane" }
	)
end

return M
