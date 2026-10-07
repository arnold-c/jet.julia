---Neovim grid viewer for JetJulia's viewer_page RPC (tables and 1D–3D arrays).
local M = {}
local PAGE_SIZE = 100
local MAX_WIDTH = 40

local actions = {
	{ "next_page", "next page" },
	{ "previous_page", "previous page" },
	{ "scroll_right", "scroll right" },
	{ "scroll_left", "scroll left" },
	{ "next_slice", "next slice" },
	{ "previous_slice", "previous slice" },
	{ "refresh", "refresh" },
	{ "close", "close" },
	{ "select_slice", "select slice tab" },
}

---Normalise an action binding; disabled actions/global keymaps return an empty list.
---@param keymaps jet.julia.ViewerKeymaps | false
---@param action string
---@return string[]
local keys_for = function(keymaps, action)
	local keys = keymaps and keymaps[action]
	if not keys then return {} end
	return type(keys) == "string" and { keys } or keys
end

---Describe enabled bindings in the same order as the installed actions.
---@param keymaps jet.julia.ViewerKeymaps | false
---@return string
local keymap_help = function(keymaps)
	local parts = {}
	for _, action in ipairs(actions) do
		local keys = keys_for(keymaps, action[1])
		if #keys > 0 then table.insert(parts, table.concat(keys, "/") .. " " .. action[2]) end
	end
	return table.concat(parts, "   ")
end

---Pad/truncate a grid cell to width display cells without splitting UTF-8 characters.
---@param text string
---@param width integer Positive display-cell width.
---@return string
local fit = function(text, width)
	if vim.fn.strdisplaywidth(text) > width then
		local n = vim.fn.strchars(text)
		while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, n)) > width - 1 do
			n = n - 1
		end
		text = vim.fn.strcharpart(text, 0, n) .. "…"
	end
	return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

---Show up to nine third-axis tabs around the selected slice.
---@param page table Grid page with shape and slice metadata from viewer_page.
---@return string
---@return table[] tabs Zero-based display-cell ranges [first, last) and slice indices.
local slice_tabs = function(page)
	if not page.shape or #page.shape ~= 3 then return "", {} end
	if page.slice_count == 0 then return "(no third-axis slices)", {} end
	local first = math.max(page.slice_first, math.min(page.slice - 4, page.slice_last - 8))
	local last = math.min(page.slice_last, first + 8)
	local text = first > page.slice_first and "… " or ""
	local tabs = {}
	for k = first, last do
		local label = k == page.slice and string.format("[ k=%d ]", k) or string.format("  k=%d  ", k)
		local start = vim.fn.strdisplaywidth(text)
		text = text .. label
		table.insert(tabs, { first = start, last = vim.fn.strdisplaywidth(text), slice = k })
	end
	if last < page.slice_last then text = text .. " …" end
	return text, tabs
end

---Render a shared grid with status/help/tabs, column names/types and data rows.
---@param page table Formatted viewer_page result.
---@param title string
---@param help string
---@return string[] lines
---@return table[] tabs Mouse hit-test ranges for line three.
local render = function(page, title, help)
	local widths = {}
	for i, name in ipairs(page.names) do
		widths[i] = math.min(MAX_WIDTH, math.max(vim.fn.strdisplaywidth(name), vim.fn.strdisplaywidth(page.types[i])))
		for _, row in ipairs(page.rows) do
			widths[i] = math.min(MAX_WIDTH, math.max(widths[i], vim.fn.strdisplaywidth(row[i])))
		end
	end
	local number_width = math.max(3, #tostring(page.total_rows))
	for _, label in ipairs(page.row_labels) do
		number_width = math.max(number_width, vim.fn.strdisplaywidth(label))
	end
	---Format one grid row, prefixed by its row label.
	---@param cells string[]
	---@param label string
	---@return string
	local line = function(cells, label)
		local parts = { fit(label, number_width) }
		for i, cell in ipairs(cells) do
			table.insert(parts, fit(cell, widths[i]))
		end
		return table.concat(parts, " │ ")
	end
	local first = #page.rows > 0 and page.offset + 1 or 0
	local tab_line, tabs = slice_tabs(page)
	local shape = page.shape and (" [" .. table.concat(page.shape, " × ") .. "]") or ""
	local lines = {
		string.format("%s%s — rows %d–%d of %d, %d columns%s", title, shape, first, page.offset + #page.rows,
			page.total_rows, page.total_columns, page.columns_truncated and " (first 100 shown)" or ""),
		help,
		tab_line,
		line(page.names, "#"),
		line(page.types, ""),
	}
	for i, row in ipairs(page.rows) do
		table.insert(lines, line(row, page.row_labels[i]))
	end
	return lines, tabs
end

---Asynchronously open a scratch split for an access path using the variables comm.
---Requires JetJulia's viewer_page RPC. Warn if the comm is not ready; RPC
---errors are reported by the comm helper. Bindings are snapshotted on open.
---@param kernel julia.Kernel
---@param path string[] Global name followed by child access keys, not expressions.
M.open = function(kernel, path)
	local vars = kernel.bufs.vars
	if not vars then
		vim.notify("jet.julia: variables comm is not ready", vim.log.levels.WARN)
		return
	end
	-- Snapshot bindings so the help and installed maps stay consistent if setup
	-- is called again while this viewer is open.
	local keymaps = vim.deepcopy(require("jet.julia.config").options.viewer.keymaps)
	local help = keymap_help(keymaps)
	local title = table.concat(path, ".")
	local buf, offset, total, busy, slice, slice_first, slice_last
	local tabs = {}
	offset, total, busy = 0, 0, false
	local load
	---Move within the real third-axis bounds and reset the row offset.
	---@param direction integer Usually 1 or -1.
	local change_slice = function(direction)
		if slice and slice + direction >= slice_first and slice + direction <= slice_last then
			load(0, slice + direction)
		end
	end
	---Request one page; ignore concurrent loads and replies for a wiped buffer.
	---@param next_offset integer Zero-based row offset.
	---@param next_slice? integer Real third-axis index; defaults to the current slice.
	load = function(next_offset, next_slice)
		if busy then return end
		busy = true
		require("jet.julia.comm").rpc_request(kernel, vars.comm_id, "viewer_page",
			{ path = path, offset = next_offset, limit = PAGE_SIZE, slice = next_slice or slice }, function(page)
				vim.schedule(function()
					busy = false
					if buf and not vim.api.nvim_buf_is_valid(buf) then return end
					if not buf then
						buf = vim.api.nvim_create_buf(false, true)
						vim.cmd("botright split")
						vim.api.nvim_win_set_buf(0, buf)
						vim.bo[buf].bufhidden = "wipe"
						vim.bo[buf].swapfile = false
						vim.bo[buf].filetype = "juliaview"
						vim.wo.wrap = false
						vim.wo.number = false
						vim.wo.relativenumber = false
						vim.wo.signcolumn = "no"
						vim.wo.foldcolumn = "0"
						local handlers = {
							close = "<cmd>close<cr>",
							refresh = function() load(offset) end,
							next_page = function() if offset + PAGE_SIZE < total then load(offset + PAGE_SIZE) end end,
							previous_page = function() load(math.max(0, offset - PAGE_SIZE)) end,
							scroll_right = "zL",
							scroll_left = "zH",
							next_slice = function() change_slice(1) end,
							previous_slice = function() change_slice(-1) end,
						}
						---Select a clicked tab, or move the cursor on non-tab lines in this viewer.
						handlers.select_slice = function()
							local mouse = vim.fn.getmousepos()
							if mouse.winid == 0 or vim.api.nvim_win_get_buf(mouse.winid) ~= buf then return end
							vim.api.nvim_set_current_win(mouse.winid)
							if mouse.line == 3 then
								local left = vim.fn.winsaveview().leftcol
								local column = mouse.wincol - 1 + left
								for _, tab in ipairs(tabs) do
									if column >= tab.first and column < tab.last then load(0, tab.slice); return end
								end
							elseif mouse.line > 0 then
								vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, math.max(0, mouse.column - 1) })
							end
						end
						for _, action in ipairs(actions) do
							for _, key in ipairs(keys_for(keymaps, action[1])) do
								vim.keymap.set("n", key, handlers[action[1]], {
									buffer = buf, silent = true, desc = "JuliaView: " .. action[2],
								})
							end
						end
					end
					offset, total = page.offset, page.total_rows
					slice = type(page.slice) == "number" and page.slice or nil
					slice_first, slice_last = page.slice_first, page.slice_last
					local lines
					lines, tabs = render(page, title, help)
					vim.bo[buf].modifiable = true
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
					vim.bo[buf].modifiable = false
				end)
			end, function() busy = false end)
	end
	load(0)
end

return M
