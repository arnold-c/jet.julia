local M = {}
local PAGE_SIZE = 100
local MAX_WIDTH = 40

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

-- A grid shared by table pages; later matrix slices can use the same renderer.
local render = function(page, title)
	local widths = {}
	for i, name in ipairs(page.names) do
		widths[i] = math.min(MAX_WIDTH, math.max(vim.fn.strdisplaywidth(name), vim.fn.strdisplaywidth(page.types[i])))
		for _, row in ipairs(page.rows) do
			widths[i] = math.min(MAX_WIDTH, math.max(widths[i], vim.fn.strdisplaywidth(row[i])))
		end
	end
	local number_width = math.max(3, #tostring(page.total_rows))
	local line = function(cells, label)
		local parts = { fit(label, number_width) }
		for i, cell in ipairs(cells) do
			table.insert(parts, fit(cell, widths[i]))
		end
		return table.concat(parts, " │ ")
	end
	local first = #page.rows > 0 and page.offset + 1 or 0
	local lines = {
		string.format("%s — rows %d–%d of %d, %d columns%s", title, first, page.offset + #page.rows,
			page.total_rows, page.total_columns, page.columns_truncated and " (first 100 shown)" or ""),
		"]p next page   [p previous page   r refresh   q close",
		"",
		line(page.names, "#"),
		line(page.types, ""),
	}
	for i, row in ipairs(page.rows) do
		table.insert(lines, line(row, tostring(page.offset + i)))
	end
	return lines
end

M.open = function(kernel, path)
	local vars = kernel.bufs.vars
	if not vars then
		vim.notify("jet.julia: variables comm is not ready", vim.log.levels.WARN)
		return
	end
	local title = table.concat(path, ".")
	local buf, offset, total, busy
	offset, total, busy = 0, 0, false
	local load
	load = function(next_offset)
		if busy then return end
		busy = true
		require("jet.julia.comm").rpc_request(kernel, vars.comm_id, "table_page",
			{ path = path, offset = next_offset, limit = PAGE_SIZE }, function(page)
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
						local map = function(key, fn) vim.keymap.set("n", key, fn, { buffer = buf, silent = true }) end
						map("q", "<cmd>close<cr>")
						map("r", function() load(offset) end)
						map("]p", function() if offset + PAGE_SIZE < total then load(offset + PAGE_SIZE) end end)
						map("[p", function() load(math.max(0, offset - PAGE_SIZE)) end)
					end
					offset, total = page.offset, page.total_rows
					vim.bo[buf].modifiable = true
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, render(page, title))
					vim.bo[buf].modifiable = false
				end)
			end, function() busy = false end)
	end
	load(0)
end

return M
