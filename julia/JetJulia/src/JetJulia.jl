"""
    JetJulia

Kernel-side support for jet.julia: serves the `positron.variables` comm from
inside a running IJulia kernel.

The module is meant to be `include`d into the kernel's `Main` (see
`lua/jet/julia/bootstrap.lua`), not loaded as a package, so that it works from
any project: `using IJulia` resolves to the copy the kernel already loaded,
and the module adds no dependencies to the user's environment. Packages such as
Tables.jl are only used if the user has already loaded them.

Call [`start`](@ref) once to register the comm target.
"""
module JetJulia

using IJulia

# Test items live next to the code they test (see https://julia-testitems.org).
# Test runners find `@testitem` blocks by scanning the source, so no dependency
# on TestItems.jl is needed here; this no-op keeps the files loadable.
macro testitem(args...)
    return nothing
end

include("variables.jl")
include("protocol.jl")
include("comm.jl")

@testitem "the source can be included into a kernel's Main" begin
    using IJulia
    kernel_main = Module(:KernelMain)
    Base.include(kernel_main, joinpath(pkgdir(JetJulia), "src", "JetJulia.jl"))
    @test isdefined(kernel_main, :JetJulia)
    @test kernel_main.JetJulia.start() === nothing
    @test kernel_main.JetJulia.STARTED[]
    @test kernel_main.JetJulia.on_post_execute in IJulia._postexecute_hooks
    IJulia.pop_postexecute_hook(kernel_main.JetJulia.on_post_execute)
end

end # module
