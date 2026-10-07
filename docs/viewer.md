# JuliaView

`:JuliaView name` opens a read-only preview of a table or a 1D–3D array
in the connected Julia kernel. Without an argument, it uses the word under
the cursor. Dotted variable paths are supported, not arbitrary expressions.
Press `v` on a variable in JuliaVars to open the same viewer.

The viewer and variables pane use the bundled JetJulia service. Tables.jl
must already be loaded in the kernel to recognise tables. Array previews do
not require it.

## Keymaps

Configure viewer mappings through `require('jet.julia').setup(opts)` (or
Lazy's `opts`). The defaults are:

```lua
opts = {
  viewer = {
    keymaps = {
      close = 'q',
      refresh = 'r',
      next_page = ']p',
      previous_page = '[p',
      scroll_right = '<Tab>',
      scroll_left = '<S-Tab>',
      next_slice = { '<C-n>', ']s' },
      previous_slice = { '<C-p>', '[s' },
      select_slice = '<LeftMouse>',
    },
  },
}
```

Each action accepts a key string, a list of keys, or `false` to disable it.
Omitted actions keep their defaults; specifying an action replaces all of
its default bindings. For example:

```lua
opts = {
  viewer = {
    keymaps = {
      next_slice = '<C-j>',
      previous_slice = '<C-k>',
      select_slice = false,
    },
  },
}
```

Use `viewer = { keymaps = false }` to disable all viewer mappings.
`select_slice` is a mouse action; if remapped, use another mouse key.
Mappings are normal-mode and buffer-local, installed when each viewer opens.
Reopen existing viewers after changing configuration. The help line reflects
configured bindings and omits disabled actions. This setting does not change
JuliaVars keymaps.

Horizontal scrolling moves half a window (`zL`/`zH`). Page controls fetch
up to 100 rows from the kernel. Next-page stops at the end; previous-page
clamps to zero (and can refetch the first page).
Normal vertical scrolling moves through the rows already loaded. Slice
controls select `a[:, :, k]` in 3D arrays and do nothing for tables, vectors,
or matrices. Clicking a slice tab also selects it.

Previews show at most 100 columns and shorten long cell text. Slices load on
demand, with at most nine neighboring tabs shown for large third axes.
Refresh reads the current variable rather than an immutable snapshot.

## Headless keymap tests

From the repository root, with Neovim installed:

```sh
nvim --headless -u NONE -l tests/viewer.lua
nvim --headless -u NONE -l tests/bootstrap.lua
```

These mock kernel communication and startup; no Julia kernel or jet.nvim
installation is needed. The bootstrap test checks that JetJulia is loaded
before the variables pane is initialised.
