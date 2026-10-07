-- Adapted from wurli/jet.ark, lua/jet/ark/comm/util.lua:
-- https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/comm/util.lua
-- MIT License, Copyright (c) 2025 Jacob Scott. See LICENSES/jet.ark-MIT.txt.
-- Modified: one-shot reply matching, event filtering and RPC error reporting.

local M = {}

---Send a JSON-RPC request over a comm and handle the reply.
---
---Replies are matched by `parent_header.msg_id`; Positron.jl parents each
---reply on the request message, as does JetJulia. Events (with a `method`)
---are ignored. The listener is removed before invoking either callback.
---Callbacks run in the message handler; UI work should use vim.schedule.
---RPC errors notify even when on_error is provided. No timeout is installed.
---
---@param kernel jet.Kernel
---@param comm_id string
---@param method string
---@param params? table
---@param callback? fun(result: any)
---@param on_error? fun(error: table) Called only for a JSON-RPC error reply.
M.rpc_request = function(kernel, comm_id, method, params, callback, on_error)
	local msg_id = kernel:comm_send(comm_id, {
		jsonrpc = "2.0",
		id = vim.fn.rand(),
		method = method,
		params = params,
	})

	kernel.hooks.on_message_received[msg_id] = function(_, msg)
		local data = msg.content and msg.content.data
		local is_reply = msg.parent_header and msg.parent_header.msg_id == msg_id and data and data.method == nil
		if not is_reply then
			return
		end

		kernel.hooks.on_message_received[msg_id] = nil

		if data.error then
			if on_error then on_error(data.error) end
			vim.notify(
				string.format("jet.julia: '%s' failed: %s", method, vim.inspect(data.error)),
				vim.log.levels.ERROR
			)
		elseif callback then
			callback(data.result)
		end
	end
end

return M
