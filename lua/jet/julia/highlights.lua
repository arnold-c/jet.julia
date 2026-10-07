-- Adapted from wurli/jet.ark, lua/jet/ark/highlights.lua:
-- https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/highlights.lua
-- MIT License, Copyright (c) 2025 Jacob Scott. See LICENSES/jet.ark-MIT.txt.
-- Modified: Julia-prefixed groups and a private setup guard.

local M = {}

---@type table<string, vim.api.keyset.highlight>
M.colours = {
	JuliaVarsCategory = { bold = true },
	JuliaVarsIndent = { link = "ComplHint" },
	JuliaVarsName = { link = "Special" },
	JuliaVarsValue = { link = "Normal" },
	JuliaVarsType = { link = "ComplHint" },
}

---Install default variables-pane highlights without overriding user definitions.
M.set_highlights = function()
	for group, hl in pairs(M.colours) do
		hl.default = true
		vim.api.nvim_set_hl(0, group, hl)
	end
end

local did_setup = false

---Install highlights once and reapply defaults after each ColorScheme event.
M.setup = function()
	if did_setup then
		return
	end
	did_setup = true

	M.set_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = M.set_highlights })
end

return M
