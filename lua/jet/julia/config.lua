---@class jet.julia.Config
---What serves the variables pane: "jetjulia" (default; the `julia/JetJulia`
---code in this plugin, no extra packages) or "positron" (Positron.jl, which
---needs an instantiated checkout at `positron_path`; it is appended to
---LOAD_PATH, so installation in the user's project is not required).
---@field variables? "jetjulia" | "positron"
---Path to the `julia/Positron` directory of a positron-julia checkout (with
---`Pkg.instantiate()` already run in it). Only used when `variables` is
---"positron".
---@field positron_path? string
---Top-level variables to hide from the variables pane: a list of names, or a
---predicate receiving the variable (`access_key`, `display_type`, `kind`, ...)
---and returning true to hide it.
---Both backends already hide names starting with `_` or `#`.
---Exclusion is client-side only and does not prevent lookup or deletion.
---@field exclude? string[] | fun(var: table): boolean
---@field viewer? jet.julia.ViewerConfig

---@alias jet.julia.Keybinding string | string[] | false

---@class jet.julia.ViewerKeymaps
---@field close? jet.julia.Keybinding
---@field refresh? jet.julia.Keybinding
---@field next_page? jet.julia.Keybinding
---@field previous_page? jet.julia.Keybinding
---@field scroll_right? jet.julia.Keybinding
---@field scroll_left? jet.julia.Keybinding
---@field next_slice? jet.julia.Keybinding
---@field previous_slice? jet.julia.Keybinding
---@field select_slice? jet.julia.Keybinding Mouse binding for selecting slice tabs.

---@class jet.julia.ViewerConfig
---@field keymaps? jet.julia.ViewerKeymaps | false Set false to disable all viewer mappings.

local M = {}

local defaults = {
	variables = "jetjulia",
	viewer = {
		keymaps = {
			close = "q",
			refresh = "r",
			next_page = "]p",
			previous_page = "[p",
			scroll_right = "<Tab>",
			scroll_left = "<S-Tab>",
			next_slice = { "<C-n>", "]s" },
			previous_slice = { "<C-p>", "[s" },
			select_slice = "<LeftMouse>",
		},
	},
}

---@type jet.julia.Config
M.options = vim.deepcopy(defaults)

---Replace options by merging opts over fresh defaults; expand positron_path.
---Existing viewers retain the keymaps captured when they were opened.
---@param opts? jet.julia.Config
M.set = function(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	if M.options.positron_path then
		M.options.positron_path = vim.fn.expand(M.options.positron_path)
	end
end

return M
