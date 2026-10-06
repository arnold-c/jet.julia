-- Adapted from jet.ark (https://github.com/wurli/jet.ark), MIT License,
-- Copyright (c) 2025 Jacob Scott.

local M = {}

---@type table<string, vim.api.keyset.highlight>
M.colours = {
	JuliaVarsCategory = { bold = true },
	JuliaVarsIndent = { link = "ComplHint" },
	JuliaVarsName = { link = "Special" },
	JuliaVarsValue = { link = "Normal" },
	JuliaVarsType = { link = "ComplHint" },
}

M.set_highlights = function()
	for group, hl in pairs(M.colours) do
		hl.default = true
		vim.api.nvim_set_hl(0, group, hl)
	end
end

local did_setup = false

M.setup = function()
	if did_setup then
		return
	end
	did_setup = true

	M.set_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = M.set_highlights })
end

return M
