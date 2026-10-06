---Julia code sent to a freshly connected kernel, and the plumbing to run it.

local M = {}

---@param s string
---@return string # A Julia string literal
local julia_string = function(s) return (vim.json.encode(s):gsub("%$", "\\$")) end

---Julia code which loads Positron.jl and starts its services.
---
---The path is `push!`ed (not `pushfirst!`ed) onto `LOAD_PATH` so versions
---from the user's project win over those in Positron's own environment.
---
---@param positron_path string
---@return string
M.positron_code = function(positron_path)
	return table.concat({
		"let p = " .. julia_string(positron_path),
		"    p in LOAD_PATH || push!(LOAD_PATH, p)",
		"end",
		"using Positron",
		"Positron.get_kernel().started || Positron.start_services!()",
		"nothing",
	}, "\n")
end

---Run `code` silently and report success or failure exactly once.
---
---Completion is signalled by `execute_reply` or, failing that, `status: idle`
---(it is not yet verified which of these `send_lua` passes to its callback).
---
---@param kernel jet.Kernel
---@param code string
---@param on_done fun(ok: boolean, err?: string)
M.run = function(kernel, code, on_done)
	local done = false
	local err ---@type string?

	local finish = function(ok, e)
		if done then
			return
		end
		done = true
		on_done(ok, e)
	end

	kernel:send_lua(code, true, function(msg)
		local msg_type = msg.header.msg_type
		local content = msg.content or {}

		if msg_type == "error" then
			err = content.evalue or content.ename or "unknown error"
		elseif msg_type == "execute_reply" then
			if content.status == "ok" then
				finish(true)
			else
				finish(false, content.evalue or err)
			end
		elseif msg_type == "status" and content.execution_state == "idle" then
			finish(err == nil, err)
		end
	end)
end

return M
