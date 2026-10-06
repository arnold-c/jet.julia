---@class jet.julia.Config
---What serves the variables pane: "jetjulia" (default; the `julia/JetJulia`
---code in this plugin, no extra packages) or "positron" (Positron.jl, which
---needs `positron_path` and must be installed in the kernel's environment).
---@field variables? "jetjulia" | "positron"
---Path to the `julia/Positron` directory of a positron-julia checkout (with
---`Pkg.instantiate()` already run in it). Only used when `variables` is
---"positron".
---@field positron_path? string
---Top-level variables to hide from the variables pane: a list of names, or a
---predicate receiving the variable (`access_key`, `display_type`, `kind`, ...).
---Positron.jl already hides names starting with `_` or `#`.
---@field exclude? string[] | fun(var: table): boolean

local M = {}

---@type jet.julia.Config
M.options = { variables = "jetjulia" }

---@param opts? jet.julia.Config
M.set = function(opts)
	M.options = vim.tbl_deep_extend("force", { variables = "jetjulia" }, opts or {})
	if M.options.positron_path then
		M.options.positron_path = vim.fn.expand(M.options.positron_path)
	end
end

return M
