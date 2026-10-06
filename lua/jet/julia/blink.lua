---A blink.cmp source for runtime completion from the current Julia kernel.
---
---```lua
---sources = {
---  default = { 'jet_julia', 'lsp', 'path', 'snippets', 'buffer' },
---  providers = { jet_julia = { name = 'Julia', module = 'jet.julia.blink' } },
---}
---```

local completion = require("jet.julia.completion")

local Source = {}
Source.__index = Source

function Source.new(opts)
	return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled() return vim.bo.filetype == "julia" and completion.current_kernel() ~= nil end

function Source:get_trigger_characters() return { "." } end

function Source:get_completions(ctx, callback)
	local kernel = completion.current_kernel()
	local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
	local prefix = ctx.line:sub(1, col)

	local respond = function(items)
		callback({ items = items, is_incomplete_backward = true, is_incomplete_forward = false })
	end

	if not kernel or prefix:match("^%s*$") then
		respond({})
		return function() end
	end

	return completion.request(kernel, prefix, vim.fn.strchars(prefix), function(content)
		respond(content and completion.to_items(content, prefix, row) or {})
	end)
end

return Source
