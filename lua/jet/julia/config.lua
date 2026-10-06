---@class jet.julia.Config
---Path to the `julia/Positron` directory of a positron-julia checkout (with
---`Pkg.instantiate()` already run in it). Required for the variables pane
---while it is backed by Positron.jl.
---@field positron_path? string
---Top-level variables to hide from the variables pane: a list of names, or a
---predicate receiving the variable (`access_key`, `display_type`, `kind`, ...).
---Positron.jl already hides names starting with `_` or `#`.
---@field exclude? string[] | fun(var: table): boolean

local M = {}

---@type jet.julia.Config
M.options = {}

---@param opts? jet.julia.Config
M.set = function(opts)
	M.options = vim.tbl_deep_extend("force", {}, opts or {})
	if M.options.positron_path then
		M.options.positron_path = vim.fn.expand(M.options.positron_path)
	end
end

return M
