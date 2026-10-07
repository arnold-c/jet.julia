-- Run from the repository root: nvim --headless -u NONE -l tests/viewer.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local config = require("jet.julia.config")
local view = require("jet.julia.view")
local requests = {}
package.loaded["jet.julia.comm"] = {
	-- Record the requested page and synchronously return a deterministic 3D grid.
	rpc_request = function(_, _, _, params, callback)
		table.insert(requests, params)
		callback({
			names = { "1" }, types = { "Int64" }, rows = { { "1" } }, row_labels = { "1" },
			offset = 0, total_rows = 1, total_columns = 1, columns_truncated = false,
			shape = { 1, 1, 2 }, slice = params.slice or 1, slice_first = 1, slice_last = 2, slice_count = 2,
		})
	end,
}
---Apply options, open the fake grid and wait for its scheduled UI update.
---@param opts? jet.julia.Config
---@return integer buf
local open = function(opts)
	config.set(opts)
	view.open({ bufs = { vars = { comm_id = "test" } } }, { "a" })
	assert(vim.wait(1000, function() return vim.bo.filetype == "juliaview" end), "viewer did not open")
	return vim.api.nvim_get_current_buf()
end
---Return the current buffer's normal-mode mapping details for assertions.
---@param key string
---@return table
local mapping = function(key) return vim.fn.maparg(key, "n", false, true) end
---Wipe a test viewer buffer so its buffer-local maps cannot leak between cases.
---@param buf integer
local close = function(buf) vim.api.nvim_buf_delete(buf, { force = true }) end

local buf = open()
assert(mapping("<Tab>").rhs == "zL")
assert(mapping("<S-Tab>").rhs == "zH")
assert(mapping("<C-n>").buffer == 1)
assert(type(mapping("<C-n>").callback) == "function")
mapping("<C-n>").callback()
assert(requests[#requests].slice == 2)
assert(vim.wait(1000, function()
	return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("[ k=2 ]", 1, true) ~= nil
end))
mapping("<C-p>").callback()
assert(requests[#requests].slice == 1)
assert(vim.wait(1000, function()
	return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("[ k=1 ]", 1, true) ~= nil
end))
close(buf)

buf = open({ viewer = { keymaps = {
	scroll_right = "L", scroll_left = false,
	next_slice = { "j", "n" }, previous_slice = "k", select_slice = false,
} } })
assert(mapping("L").rhs == "zL")
assert(vim.tbl_isempty(mapping("<Tab>")))
assert(vim.tbl_isempty(mapping("<S-Tab>")))
assert(vim.tbl_isempty(mapping("<C-n>")))
assert(vim.tbl_isempty(mapping("]s")))
assert(vim.tbl_isempty(mapping("<LeftMouse>")))
assert(type(mapping("j").callback) == "function")
assert(type(mapping("n").callback) == "function")
assert(type(mapping("k").callback) == "function")
local help = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
assert(help:find("L scroll right", 1, true))
assert(help:find("j/n next slice", 1, true))
assert(not help:find("scroll left", 1, true))
assert(not help:find("select slice tab", 1, true))
close(buf)

buf = open({ viewer = { keymaps = false } })
assert(#vim.api.nvim_buf_get_keymap(buf, "n") == 0)
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "")
close(buf)

-- Configuration changes cannot mutate the defaults.
config.set()
assert(config.options.viewer.keymaps.scroll_left == "<S-Tab>")
assert(vim.deep_equal(config.options.viewer.keymaps.next_slice, { "<C-n>", "]s" }))
print("JuliaView keymap tests passed")
