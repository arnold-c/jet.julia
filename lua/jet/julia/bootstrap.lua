---Julia code sent to a freshly connected kernel, and the plumbing to run it.

local M = {}

---Quote a path as a Julia string literal, including literal dollar signs.
---@param s string
---@return string # A Julia string literal
local julia_string = function(s) return (vim.json.encode(s):gsub("%$", "\\$")) end

---Julia code which loads JetJulia into the kernel's `Main` and registers its
---comm dispatch, post-execute updates and completion improvements.
---
---The source is `include`d, not loaded as a package, so it works from any
---project and adds nothing to the user's environment. The statements are
---separate so each runs in the world age created by the previous one.
---
---@param jetjulia_dir string The `julia/JetJulia` directory of this plugin
---@return string
M.jetjulia_code = function(jetjulia_dir)
	return table.concat({
		"isdefined(Main, :JetJulia) || Base.include(Main, " .. julia_string(jetjulia_dir .. "/src/JetJulia.jl") .. ")",
		"Main.JetJulia.start()",
		"nothing",
	}, "\n")
end

---Run `code` silently and report success or failure exactly once.
---
---An error message is remembered until `execute_reply` or `status: idle`.
---Whichever completion signal arrives first wins; no timeout is installed.
---The completion callback runs in the message handler, not via vim.schedule.
---
---@param kernel jet.Kernel
---@param code string
---@param on_done fun(ok: boolean, err?: string)
M.run = function(kernel, code, on_done)
	local done = false
	local err ---@type string?

	---Guard the completion callback against duplicate reply/idle messages.
	---@param ok boolean
	---@param e? string
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
