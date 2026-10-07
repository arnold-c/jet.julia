# Source attribution and third-party notices

This inventory covers the Lua and Julia source shipped in this repository,
including `tests/viewer.lua` and `tests/bootstrap.lua`. Source-level notices
identify adaptations; license texts are retained in `LICENSES/`. These
third-party notices do not assign a license to the repository's original code.

The review compared the current code and local revision history with the
upstream sources linked below. Upstream `main` links are reference locations,
not claims about the exact revision originally copied: the local history does
not record those upstream revisions. Preserve these notices when modifying or
redistributing the adapted portions.

## jet.ark — Jacob Scott (MIT)

Upstream: [wurli/jet.ark](https://github.com/wurli/jet.ark).
Copyright (c) 2025 Jacob Scott.
Full license: [`LICENSES/jet.ark-MIT.txt`](../LICENSES/jet.ark-MIT.txt).

| Local file | Upstream source | Adapted scope and changes |
| --- | --- | --- |
| `lua/jet/julia/vars.lua` | [`lua/jet/ark/ark_kernel/vars.lua`](https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/ark_kernel/vars.lua) | Variables pane, comm-driven tree, grouping, keymaps and rendering. Modified for Julia, replacement updates, session namespaces, client-side exclusions, single-line text, window-relative columns and JuliaView. |
| `lua/jet/julia/highlights.lua` | [`lua/jet/ark/highlights.lua`](https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/highlights.lua) | Default highlight definitions and ColorScheme reapplication; renamed groups and private setup state. |
| `lua/jet/julia/comm.lua` | [`lua/jet/ark/comm/util.lua`](https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/comm/util.lua) | JSON-RPC send/listener pattern and parent-message matching. Modified for one-shot result/error callbacks and notification filtering. |
| `lua/jet/julia/kernel.lua` | [`lua/jet/ark/ark_kernel/init.lua`](https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/ark_kernel/init.lua) | In-place kernel subclass conversion and client-start hook; replaced Ark services with Julia backend bootstrap. |
| `lua/jet/julia/init.lua` | [`lua/jet/ark/init.lua`](https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/init.lua) | Setup prerequisite guard and variables-command pattern; Julia-specific commands, configuration and keyed kernel-init hook. |

Local revision `852f65f4` explicitly records that the pane was ported from
jet.ark. The wire-schema reference in `variables.jl` and `protocol.jl` is
jet.ark's [`resources/positron-comms`](https://github.com/wurli/jet.ark/tree/main/resources/positron-comms),
which describes the Positron variables protocol; this repository does not
vendor those JSON files or jet.ark's generated comm bindings.

The category helper in `vars.lua` also links to
[Positron's variables grouping](https://github.com/posit-dev/positron/blob/main/src/vs/workbench/services/positronVariables/common/positronVariablesInstance.ts).
That is a behaviour reference; the Lua grouping is inherited from the
jet.ark pane, not a vendored TypeScript implementation.

## positron-julia / Positron.jl — Elastic License 2.0

Upstream: [TidierOrg/positron-julia](https://github.com/TidierOrg/positron-julia)
(previously `ntluong95/positron-julia`). The Julia backend is named
**Positron.jl**; there is no upstream module called `positron.julia`.

Upstream Julia source notice:

> Copyright (C) 2025 Posit Software, PBC. All rights reserved.
> Licensed under the Elastic License 2.0.

Retained upstream license and introductory notice:
[`LICENSES/Elastic-2.0.txt`](../LICENSES/Elastic-2.0.txt), from the upstream
[`LICENSE`](https://github.com/TidierOrg/positron-julia/blob/main/LICENSE).
Upstream source headers refer to `LICENSE.txt`; the local notice points to the
actual retained license file instead.

`julia/JetJulia/src/variables.jl` contains rewritten/adapted portions of
[`julia/Positron/src/variables.jl`](https://github.com/TidierOrg/positron-julia/blob/main/julia/Positron/src/variables.jl):
per-type variable classification, compact `show`/IOContext rendering, table
summaries, length/size reporting, visibility filtering, wire descriptions and
collection/path inspection. The file now uses dictionary wire values rather
than generated structs, optional loaded Tables.jl rather than DataFrames
imports, bounded Unicode-safe displays, module-scoped lookup, capped children,
first-axis array slices and fingerprint-based updates. Its header explicitly
identifies it as modified. These adapted portions must not be described as
MIT-only merely because the Lua pane came from jet.ark.

Local revision `8af328e9` records the variables-comm port into JetJulia.
`protocol.jl` and `comm.jl` implement the same service contract using separate
transport-free dispatch and direct IJulia transport. Relevant design/protocol
references are the upstream variables service above and
[`julia/Positron/src/comm.jl`](https://github.com/TidierOrg/positron-julia/blob/main/julia/Positron/src/comm.jl).
They do not vendor Positron's generated request types, `PositronComm` wrapper,
logging infrastructure or data explorer. Matching protocol names and message
fields alone are not evidence of verbatim source copying.

JetJulia is the sole runtime service; no external Positron.jl backend is
loaded. The `positron.variables` comm target and variable vocabulary remain
in active use as the wire protocol. Removing the optional backend does not
remove the provenance or license obligations of the adapted source.

## IJulia.jl — MIT

Upstream: [JuliaLang/IJulia.jl](https://github.com/JuliaLang/IJulia.jl),
reviewed against v1.34.4, as recorded in the project's original environment.

Copyright © 2013 by Steven G. Johnson, Fernando Perez, Jeff Bezanson,
Stefan Karpinski, Keno Fischer, and other contributors.
Full license: [`LICENSES/IJulia-MIT.txt`](../LICENSES/IJulia-MIT.txt), from
upstream [`LICENSE.md`](https://github.com/JuliaLang/IJulia.jl/blob/v1.34.4/LICENSE.md).

- `julia/JetJulia/src/columns.jl`: cursor conversion, completion-reply shape
  and reply sending follow/adapt `complete_request` in
  [`src/handlers.jl`](https://github.com/JuliaLang/IJulia.jl/blob/v1.34.4/src/handlers.jl).
  Matching is replaced with table-column completion and a delegating wrapper.
- `julia/JetJulia/src/completion.jl`: whole-buffer parse-start replacement
  follows the upstream `find_parsestart` comment; the inline regression test
  adapts the upstream completion pipeline without its transport.

Calling IJulia's comm/publish APIs elsewhere is dependency usage, not itself
source copying.

## Remaining files

No copied upstream implementation was identified in `connect.lua`,
`bootstrap.lua`, `config.lua`, `view.lua`, `tests/viewer.lua`,
`tests/bootstrap.lua`,
`julia/JetJulia/src/viewer.jl` or the module-loading/test macro in
`julia/JetJulia/src/JetJulia.jl`. They integrate with the credited components;
shared API names and standard Neovim/Julia idioms are not labelled as copied
code. This is a source/history review, not proof of otherwise undocumented
provenance or a legal determination of derivative-work boundaries.

For future ports, add a source URL (preferably pinned to the revision used),
the upstream copyright and license, the adapted scope, and a prominent
modification notice at the source. Retain the full applicable license in
`LICENSES/` and update this inventory. Do not infer an upstream license from a
different project with which it interoperates.
