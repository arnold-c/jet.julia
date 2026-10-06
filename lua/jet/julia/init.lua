local M = {}

---@param opts? table Currently unused; reserved for later milestones.
M.setup = function(opts)
	local jet = require("jet")
	assert(jet.did_setup(), 'jet.nvim has not done setup; run `require("jet").setup({})` before loading jet.julia')

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
end

return M
