---Runtime completion straight from the kernel (Jupyter `complete_request`).
---
---jet's generic LSP returns no items for IJulia kernels, although the kernel
---answers `complete_request` correctly, so this asks the kernel directly.

local M = {}

local POLL_MS = 20
local TIMEOUT_MS = 2000

---The connected Julia kernel that is current for Julia buffers, if any.
---@return julia.Kernel?
M.current_kernel = function()
	local manager = require("jet.core.manager")
	local session_id = manager.filetype_current.julia
	local k = session_id and manager.kernels[session_id]
	if k and k.subclass == "julia" and k:status() == "connected" then
		return k --[[@as julia.Kernel]]
	end
end

---Send a `complete_request` and call `on_reply` with the reply content, or
---`nil` on timeout. `cursor` is in characters, as Jupyter expects.
---@param kernel julia.Kernel
---@param code string
---@param cursor integer
---@param on_reply fun(content: table?)
---@return fun() # Cancels the request
M.request = function(kernel, code, cursor, on_reply)
	local next_msg = require("jet.core.engine").get_completions(kernel.client_id, code, cursor)
	local timer = assert(vim.uv.new_timer())
	local elapsed = 0

	local finish = function(content)
		if not timer:is_closing() then
			timer:stop()
			timer:close()
			on_reply(content)
		end
	end

	timer:start(
		0,
		POLL_MS,
		vim.schedule_wrap(function()
			if timer:is_closing() then
				return
			end
			elapsed = elapsed + POLL_MS
			local ok, res = pcall(next_msg)
			if not ok or elapsed > TIMEOUT_MS then
				return finish(nil)
			end
			local msg = res.value
			if msg and msg.header.msg_type == "complete_reply" then
				return finish(msg.content)
			end
			if res.status == "done" then
				return finish(nil)
			end
		end)
	)

	return function()
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

---IJulia's experimental per-match type annotations, keyed by match text.
---@param content table
---@return table<string, string>
local match_types = function(content)
	local out = {}
	local types = content.metadata and content.metadata._jupyter_types_experimental
	for _, t in ipairs(type(types) == "table" and types or {}) do
		if t.text and t.type then
			out[t.text] = t.type
		end
	end
	return out
end

local KIND_BY_TYPE = {
	["function"] = "Function",
	type = "Class",
	keyword = "Keyword",
	module = "Module",
	macro = "Constant", -- not Function, to avoid auto-brackets after `@foo`
}

---Convert a `complete_reply` to LSP completion items replacing text on one line.
---@param content table The `complete_reply` content
---@param prefix string The line up to the cursor (what was sent as `code`)
---@param row integer 0-based line of the cursor
---@return lsp.CompletionItem[]
M.to_items = function(content, prefix, row)
	if content.status ~= "ok" or type(content.matches) ~= "table" then
		return {}
	end

	-- Reply offsets are in characters within `prefix`; edits use bytes.
	local start_byte = vim.fn.byteidx(prefix, content.cursor_start or vim.fn.strchars(prefix))
	if start_byte < 0 then
		start_byte = #prefix
	end
	local range = {
		start = { line = row, character = start_byte },
		["end"] = { line = row, character = #prefix },
	}

	local kinds = vim.lsp.protocol.CompletionItemKind
	local types = match_types(content)
	local items = {}
	for i, match in ipairs(content.matches) do
		local t = types[match]
		table.insert(items, {
			label = match,
			kind = kinds[KIND_BY_TYPE[t] or "Variable"],
			detail = t,
			sortText = string.format("%05d", i), -- keep the kernel's order
			textEdit = { newText = match, range = range },
		})
	end
	return items
end

return M
