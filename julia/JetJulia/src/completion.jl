# Fix IJulia's completion of code that follows a multi-line string.
#
# IJulia's `complete_request` hands REPLCompletions only the code from
# `find_parsestart` onwards: the first line start from which the code up to
# the cursor parses without error. When a client sends a whole buffer (jet's
# LSP does), that start can be the closing `"""` of an earlier docstring, so
# everything after looks like the inside of a string and nothing completes.
#
# IJulia notes that `find_parsestart` should become `firstindex(code)` once
# completions can parse the full text; from Julia 1.12, REPLCompletions does
# so with JuliaSyntax.

"Whether REPLCompletions copes with the whole buffer (checked on Julia 1.13)."
const FULL_TEXT_COMPLETION = VERSION >= v"1.12"

"""
    fix_completion!()

Make IJulia complete against the whole code it is sent. A no-op on Julia
versions whose completer still needs IJulia's parse start. Returns whether the
fix is active.
"""
function fix_completion!()
    FULL_TEXT_COMPLETION || return false
    @eval IJulia find_parsestart(code, cursorpos) = firstindex(code)
    return true
end

@testitem "completion after a docstring works once fixed" skip = (VERSION < v"1.12") begin
    using IJulia, REPL

    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(xs = (alpha = 1, beta = 2)))

    # IJulia's `complete_request` pipeline, minus the transport.
    function complete(code)
        cursor = lastindex(code)
        start = IJulia.find_parsestart(code, cursor)
        comps, _, _ = REPL.REPLCompletions.completions(
            code[start:end],
            cursor - start + 1,
            sandbox,
        )
        return sort!(unique!(REPL.REPLCompletions.completion_text.(comps)))
    end

    code = "x = 1\n\"\"\"\ndoc\n\"\"\"\nf(a) = a\n\nxs."
    @test JetJulia.fix_completion!()
    @test IJulia.find_parsestart(code, lastindex(code)) == 1
    @test complete(code) == ["alpha", "beta"]
    @test complete("y = 2\n\nxs.") == ["alpha", "beta"]
    @test complete("s = \"xs.") == String[] # inside a string
end
