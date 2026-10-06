-- Adapted from jet.ark's `ark_kernel/vars.lua` (https://github.com/wurli/jet.ark),
-- MIT License, Copyright (c) 2025 Jacob Scott.
--
-- A client for the `positron.variables` comm. Changes from the original:
--   * no dependency on jet.ark (own RPC helper and highlight groups)
--   * `update` events replace existing variables instead of duplicating them
--   * every keymap is buffer-local; display strings are single-line

local buf = require("jet.core.kernel.buf")
local rpc = require("jet.julia.comm").rpc_request

---@class julia.var
---@field access_key string
---@field display_name string
---@field display_value string
---@field display_type string
---@field kind string
---@field has_children boolean
---@field expanded? boolean
---@field children? julia.var[]

---@class julia.flat_var : julia.var
---@field path string[]
---@field indent integer
---@field display_name_w integer
---@field display_value_w integer
---@field display_type_w integer

---@class julia.Vars : jet.Buf
---@field vars julia.var[]
---@field vars_flat (julia.flat_var | string)[]
---@field version integer
---@field length integer
---@field comm_id string
local Vars = setmetatable({}, { __index = buf })
Vars.__index = Vars ---@private

local TARGET = "positron.variables"

---@param kernel julia.Kernel
---@return julia.Vars
Vars.init = function(kernel)
	assert(kernel.session_id)

	require("jet.julia.highlights").setup()

	local out = buf.init(Vars, {
		kernel = kernel,
		name = kernel:friendly_name() .. " - Variables",
		win_name = "secondary",
	})
	-- `buf.init` assigns a shared namespace; use a per-session one instead
	out.ns = vim.api.nvim_create_namespace("jet.julia." .. kernel.session_id)

	out.vars = {}
	out.vars_flat = {}
	out.length = 0
	out.version = 0

	vim.bo[out.buf].filetype = "juliavars"
	vim.bo[out.buf].modifiable = false
	vim.bo[out.buf].buftype = "nofile"

	out.comm_id = out:start_comm()
	out:set_keymaps()

	vim.api.nvim_create_autocmd("WinResized", {
		group = vim.api.nvim_create_augroup("jet.julia." .. kernel.session_id, { clear = true }),
		callback = function()
			local win = out:win():winnr(out.buf)
			if win and vim.tbl_contains(vim.v.event.windows or {}, win) then
				out:redraw()
			end
		end,
	})

	return out
end

----------------------------------------------------------------------------
-- Comm
----------------------------------------------------------------------------

---@return string # Comm id
function Vars:start_comm()
	local comm_id = self.kernel:comm_open(TARGET, {}, {
		listener = function(msg)
			local data = msg.content.data
			if data.method == "refresh" then
				self:on_refresh(data.params)
			elseif data.method == "update" then
				self:on_update(data.params)
			end
		end,
	})
	return comm_id
end

function Vars:on_refresh(params)
	self.length = params.length
	self.version = params.version
	self.vars = params.variables
	self:redraw()
end

function Vars:on_update(params)
	self.version = params.version
	for _, key in ipairs(params.removed or {}) do
		self:rm(key)
	end
	for _, var in ipairs(params.assigned or {}) do
		local reinspect = self:upsert(var)
		if reinspect then
			self:inspect({ var.access_key })
		end
	end
	self:redraw()
end

---Replace the top-level variable with the same access key, or append it.
---@param var julia.var
---@return boolean # Whether the variable was expanded and needs re-inspecting
function Vars:upsert(var)
	for i, existing in ipairs(self.vars) do
		if existing.access_key == var.access_key then
			var.expanded = existing.expanded and var.has_children
			self.vars[i] = var
			return var.expanded == true
		end
	end
	table.insert(self.vars, var)
	return false
end

---@param key string
function Vars:rm(key)
	for i, var in ipairs(self.vars) do
		if var.access_key == key then
			table.remove(self.vars, i)
			return
		end
	end
end

---@param cb? fun()
function Vars:list(cb)
	rpc(self.kernel, self.comm_id, "list", nil, function(res)
		self.vars = res.variables
		self.length = res.length
		self.version = res.version
		if cb then
			cb()
		end
	end)
end

---@param hidden? boolean
function Vars:clear(hidden)
	rpc(self.kernel, self.comm_id, "clear", { include_hidden_objects = hidden ~= false })
end

---@param names string | string[]
function Vars:delete(names)
	names = type(names) == "string" and { names } or names
	rpc(self.kernel, self.comm_id, "delete", { names = names }, function(deleted)
		for _, key in ipairs(deleted) do
			self:rm(key)
		end
		self:redraw()
	end)
end

---@param path string[]
function Vars:inspect(path)
	assert(#path > 0)
	rpc(self.kernel, self.comm_id, "inspect", { path = path }, function(res)
		local var = self:get_var(path)
		if var then
			var.children = res.children
			var.expanded = true
			self:redraw()
		end
	end)
end

---@param path string[]
---@param format? "text/plain" | "text/html"
---@param cb fun(text: string)
function Vars:clipboard_format(path, format, cb)
	assert(#path > 0)
	rpc(self.kernel, self.comm_id, "clipboard_format", { path = path, format = format or "text/plain" }, function(res)
		cb(res.content)
	end)
end

----------------------------------------------------------------------------
-- Tree
----------------------------------------------------------------------------

---@param path string[]
---@return julia.var?
function Vars:get_var(path)
	local var ---@type julia.var?
	local children = self.vars ---@type julia.var[]?
	for _, key in ipairs(path) do
		var = nil
		for _, candidate in ipairs(children or {}) do
			if candidate.access_key == key then
				var = candidate
				break
			end
		end
		if not var then
			return nil
		end
		children = var.children
	end
	return var
end

---@param path string[]
function Vars:collapse(path)
	local var = self:get_var(path)
	if var and var.expanded then
		var.expanded = false
		self:redraw()
	end
end

---@param path string[]
function Vars:expand(path)
	local var = self:get_var(path)
	if not var or var.expanded then
		return
	end
	var.expanded = true
	if var.children then
		self:redraw()
	elseif var.has_children then
		self:inspect(path)
	end
end

----------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------

function Vars:open()
	local win = buf.open(self, nil)
	-- Columns are sized to the window; never wrap
	vim.wo[win].wrap = false
	self:list(function() self:redraw() end)
	return win
end

---The variable on the cursor line, if the line holds one.
---@return julia.flat_var?
function Vars:current_var()
	local var = self.vars_flat[vim.fn.line(".")]
	if type(var) == "table" then
		return var
	end
end

function Vars:set_keymaps()
	local map = function(modes, lhs, fn) vim.keymap.set(modes, lhs, fn, { buffer = self.buf, silent = true }) end

	map("n", "q", "<cmd>q<cr>")

	map("n", "<enter>", function()
		local var = self:current_var()
		if not var then
			return
		end
		if var.expanded then
			self:collapse(var.path)
		else
			self:expand(var.path)
		end
	end)

	map("n", "<leader>y", function()
		local var = self:current_var()
		if var then
			local reg = vim.v.register
			self:clipboard_format(var.path, "text/plain", function(text) vim.fn.setreg(reg, text) end)
		end
	end)

	---@param direction integer
	local next_var = function(direction)
		for i = vim.fn.line(".") + direction, direction > 0 and #self.vars_flat or 1, direction do
			local var = self.vars_flat[i]
			if type(var) == "table" and var.indent == 0 then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return
			end
		end
	end
	map({ "n", "x" }, "]]", function() next_var(1) end)
	map({ "n", "x" }, "[[", function() next_var(-1) end)

	map("n", ">", function()
		local var = self:current_var()
		if var then
			self:expand(var.path)
		end
	end)

	map("n", "<", function()
		local var = self:current_var()
		if not var then
			return
		end
		if var.expanded then
			self:collapse(var.path)
		elseif #var.path > 1 then
			local parent_path = vim.list_slice(var.path, 1, #var.path - 1)
			self:collapse(parent_path)
			for line, line_var in ipairs(self.vars_flat) do
				if type(line_var) == "table" and vim.deep_equal(line_var.path, parent_path) then
					vim.api.nvim_win_set_cursor(0, { line, 0 })
					return
				end
			end
		end
	end)

	map("n", "<leader>d", function()
		local var = self:current_var()
		if var and #var.path == 1 then
			self:delete(var.path)
			vim.api.nvim_win_set_cursor(0, { math.max(1, vim.fn.line(".") - 1), 0 })
		end
	end)

	map("n", "X", function() self:clear(true) end)
end

function Vars:redraw()
	local lines, extmarks = self:render()
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.bo[self.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
	for line, marks in ipairs(extmarks) do
		for _, mark in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(self.buf, self.ns, line - 1, mark[1], mark[2])
		end
	end
end

local icons = {
	caret_right = "",
	caret_down = "",
	ellipsis = "…",
}

---@alias julia.extmark_args [ integer, vim.api.keyset.set_extmark ]

---Mirrors Positron's grouping:
---https://github.com/posit-dev/positron/blob/main/src/vs/workbench/services/positronVariables/common/positronVariablesInstance.ts#L723
---@param kind string
---@return "DATA" | "FUNCTIONS" | "CLASSES" | "VALUES"
local category = function(kind)
	return kind == "table" and "DATA" or kind == "function" and "FUNCTIONS" or kind == "class" and "CLASSES" or "VALUES"
end

local CATEGORY_ORDER = { "DATA", "FUNCTIONS", "CLASSES", "VALUES" }

---@param s string
---@return string
local single_line = function(s) return (tostring(s):gsub("[\r\n]+", " ")) end

---@param var julia.var
---@param path string[]
---@param level integer
---@return julia.flat_var
local flatten = function(var, path, level)
	local flat = {}
	for k, v in pairs(var) do
		if k ~= "children" then
			flat[k] = v
		end
	end
	flat.display_name = single_line(var.display_name)
	flat.display_value = single_line(var.display_value)
	flat.display_type = single_line(var.display_type)
	flat.path = vim.list_extend(vim.deepcopy(path), { var.access_key })
	flat.indent = level * 2
	flat.display_name_w = vim.fn.strwidth(flat.display_name)
	flat.display_value_w = vim.fn.strwidth(flat.display_value)
	flat.display_type_w = vim.fn.strwidth(flat.display_type)
	return flat
end

---Whether a top-level variable is hidden by the `exclude` option.
---@param var julia.var
---@return boolean
local is_excluded = function(var)
	local exclude = require("jet.julia.config").options.exclude
	if type(exclude) == "function" then
		return exclude(var) == true
	end
	return vim.tbl_contains(exclude or {}, var.access_key)
end

---Pad or truncate `s` to exactly `width` display cells.
---@param s string
---@param width integer
---@param align? "left" | "right"
---@return string padded
---@return string text # `s`, truncated if needed (for highlight extents)
local fit = function(s, width, align)
	local w = vim.fn.strwidth(s)
	if w > width then
		s = width <= 1 and icons.ellipsis or vim.fn.strcharpart(s, 0, width - 1) .. icons.ellipsis
		w = vim.fn.strwidth(s)
	end
	local pad = string.rep(" ", math.max(width - w, 0))
	return align == "right" and pad .. s or s .. pad, s
end

-- Column widths as fractions of the window; the value gets the rest.
local NAME_MAX_FRAC = 0.35
local TYPE_MAX_FRAC = 0.3
local MIN_COL = 8
local SEP = "  "

---Flatten the (partially expanded) variable tree into display order.
---@return (julia.flat_var | string)[]
function Vars:flatten()
	local categories = {}
	for _, c in ipairs(CATEGORY_ORDER) do
		categories[c] = {}
	end
	for _, var in ipairs(self.vars) do
		if not is_excluded(var) then
			table.insert(categories[category(var.kind)], var)
		end
	end

	local out = {}

	---@param vars julia.var[]
	---@param path string[]
	---@param level integer
	local function unpack_vars(vars, path, level)
		for _, var in ipairs(vars) do
			local flat = flatten(var, path, level)
			table.insert(out, flat)
			if var.expanded and var.children then
				unpack_vars(var.children, flat.path, level + 1)
			end
		end
	end

	for _, c in ipairs(CATEGORY_ORDER) do
		if #categories[c] > 0 then
			table.insert(out, c)
			unpack_vars(categories[c], {}, 0)
			table.insert(out, "")
		end
	end

	return out
end

---@return string[]
---@return julia.extmark_args[][]
function Vars:render()
	self.vars_flat = self:flatten()

	if #self.vars_flat == 0 then
		local text = "No variables to display"
		return { text }, { { { 0, { hl_group = "Comment", end_col = #text } } } }
	end

	---@param f fun(v: julia.flat_var): integer
	local var_max = function(f)
		local widths = vim.tbl_map(function(var) return type(var) == "table" and f(var) or 0 end, self.vars_flat)
		return math.max(0, unpack(widths))
	end

	local w = self:win()
	local win = w and w:winnr(self.buf)
	local win_width = win and vim.api.nvim_win_get_width(win) or math.floor(vim.o.columns / 2)

	-- Cap the name and type columns so the line always fits the window; the
	-- value column takes what is left. Overlong text is truncated, not wrapped.
	local cap = function(max, frac) return math.min(max, math.max(MIN_COL, math.floor(win_width * frac))) end
	local name_w = cap(var_max(function(v) return v.display_name_w + v.indent end), NAME_MAX_FRAC)
	local type_w = cap(var_max(function(v) return v.display_type_w end), TYPE_MAX_FRAC)
	-- 2 cells for caret + space before the name
	local val_w = math.max(win_width - 2 - name_w - type_w - 2 * #SEP, MIN_COL)

	local lines = {} ---@type string[]
	local marks = {} ---@type julia.extmark_args[][]

	for _, v in ipairs(self.vars_flat) do
		if type(v) == "string" then
			table.insert(lines, v)
			table.insert(marks, { { 0, { hl_group = "JuliaVarsCategory", end_col = #v } } })
		else
			local indent = string.rep(" ", v.indent)
			local caret = (not v.has_children) and " " or v.expanded and icons.caret_down or icons.caret_right
			local prefix = indent .. caret .. " "

			local name_col, name = fit(v.display_name, math.max(name_w - v.indent, 1))
			local val_col, val = fit(v.display_value, val_w)
			local type_col, vtype = fit(v.display_type, type_w, "right")

			local line = prefix .. name_col .. SEP .. val_col .. SEP .. type_col
			table.insert(lines, line)

			local name_start = #prefix
			local val_start = name_start + #name_col + #SEP
			local type_end = #line

			table.insert(marks, {
				{ v.indent, { hl_group = "JuliaVarsIndent", end_col = v.indent + #caret } },
				{ name_start, { hl_group = "JuliaVarsName", end_col = name_start + #name } },
				{ val_start, { hl_group = "JuliaVarsValue", end_col = val_start + #val } },
				{ type_end - #vtype, { hl_group = "JuliaVarsType", end_col = type_end } },
			})
		end
	end

	return lines, marks
end

return Vars
