-- Run from the repository root: nvim --headless -u NONE -l tests/bootstrap.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bootstrap = require("jet.julia.bootstrap")
local code = bootstrap.jetjulia_code('/tmp/jet $project "quoted"/julia/JetJulia')
assert(code:find("Main.JetJulia.start()", 1, true))
assert(code:find("\\$project", 1, true))
assert(code:find('\\"quoted\\"', 1, true))
assert(not code:find("LOAD_PATH", 1, true))

-- Exercise client startup without jet.nvim or a Julia kernel.
package.loaded["jet.core.kernel"] = {}
local sent, initialised
local pane = {}
package.loaded["jet.julia.vars"] = {
	---Record pane creation so bootstrap ordering can be asserted.
	init = function(kernel)
		initialised = kernel
		return pane
	end,
}
local JuliaKernel = require("jet.julia.kernel")
local kernel = {
	bufs = {},
	hooks = { on_lua_client_start = {} },
	---Capture the silent bootstrap request rather than sending it to Julia.
	send_lua = function(_, text, silent, callback)
		assert(silent)
		sent = { code = text, callback = callback }
	end,
}
JuliaKernel.from_kernel(kernel)
kernel.hooks.on_lua_client_start.start_variables(kernel)
assert(sent and sent.code:find("/julia/JetJulia/src/JetJulia.jl", 1, true))
assert(sent.code:find("Main.JetJulia.start()", 1, true))
assert(initialised == nil, "pane opened before bootstrap completed")
sent.callback({ header = { msg_type = "execute_reply" }, content = { status = "ok" } })
assert(vim.wait(1000, function() return kernel.bufs.vars == pane end), "pane did not initialise")
assert(initialised == kernel)
print("JetJulia bootstrap tests passed")
