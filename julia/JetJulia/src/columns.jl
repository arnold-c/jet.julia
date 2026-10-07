# Completion pipeline portions adapted from JuliaLang/IJulia.jl v1.34.4,
# src/handlers.jl (complete_request):
# https://github.com/JuliaLang/IJulia.jl/blob/v1.34.4/src/handlers.jl
# Copyright © 2013 Steven G. Johnson, Fernando Perez, Jeff Bezanson,
# Stefan Karpinski, Keno Fischer, and other contributors.
# MIT License; see ../../../LICENSES/IJulia-MIT.txt.
# Modified: table-column matches and a delegating request handler.
#
# Column-name completion for tables, inside indexing brackets:
#
#     df[!, <cursor>     df[:, :<cursor>     df[!, "<cursor>     df["<cursor>
#
# IJulia's completer only knows brackets of `AbstractDict`s, so `complete_request`
# is intercepted: if the text before the cursor ends in such an index of a
# table (anything Tables.jl recognises, e.g. a DataFrame), the columns are the
# completions. Everything else goes to IJulia's own handler.

const IDENT = raw"[\p{L}_][\p{L}\p{N}_!]*"

# `name` or `a.b.c`, `[`, an optional row selector (`!,` or `:,`), an optional
# opening `:` or `"`, and the partial column name. The lookbehind rejects
# `f(x).df[` and `v[1].df[`, whose receiver is not a plain name.
const COLUMN_CONTEXT = Regex(
    "(?<![\\p{L}\\p{N}_.!)\\]])($IDENT(?:\\.$IDENT)*)" *
        "\\[[ \\t]*(?:([!:])[ \\t]*,[ \\t]*)?(:|\")?([\\p{L}\\p{N}_]*)\$",
)

"""
Look up a dotted property path in `mod` without evaluating expressions.
Return `Some(value)` (including `Some(nothing)`) or `nothing` for an undefined
root. Property access uses the latest world age and may throw.
"""
function lookup(mod::Module, path::AbstractString)
    head, rest = Iterators.peel(split(path, '.'))
    isdefined(mod, Symbol(head)) || return nothing
    value = getglobal(mod, Symbol(head))
    for field in rest
        value = Base.invokelatest(getproperty, value, Symbol(field))
    end
    return Some(value)
end

"Whether `value` is indexed by column names (and not by position or key)."
is_column_indexed(value) = istable(value) &&
    !(value isa AbstractArray) &&
    !(value isa AbstractDict)

"""
    column_completion(prefix, mod) -> Union{Nothing, NamedTuple}

Column completions for the code `prefix` before the cursor, or `nothing` if the
cursor is not in a supported column position of a table in `mod`. Receivers
must be plain or dotted names; arrays/dictionaries are excluded. Supported
forms are `df[!, ...`, `df[:, ...` and `df[\"...`. Lookup failures are ignored;
Tables.jl interface errors may propagate to the installed handler, which
falls back to IJulia. The result has
`matches` (text to insert), `types` (element types) and `partial`, the text
before the cursor that the matches replace.
"""
function column_completion(prefix::AbstractString, mod::Module = Main)
    m = match(COLUMN_CONTEXT, prefix)
    m === nothing && return nothing
    receiver, selector, quote_char, partial = m.captures
    # Without a row selector only `df["col"]` is column indexing; and a bare
    # partial name is a variable, not a column.
    (selector === nothing && quote_char != "\"") && return nothing
    (quote_char === nothing && !isempty(partial)) && return nothing

    found = try
        lookup(mod, receiver)
    catch
        nothing
    end
    found === nothing && return nothing
    table = something(found)
    is_column_indexed(table) || return nothing

    cols, names = table_columns(table)
    matches, types = String[], String[]
    for name in names
        key = string(name)
        startswith(key, partial) || continue
        text = column_text(key, quote_char)
        text === nothing && continue
        push!(matches, text)
        push!(types, string(eltype(table_column(cols, name))))
    end
    return (; matches, types, partial = String(partial))
end

"How column `key` is written after `quote_char`, or `nothing` if it cannot be."
function column_text(key::AbstractString, quote_char)
    if quote_char == "\""
        return escape_string(key, ('"', '$'))
    elseif quote_char == ":"
        return Base.isidentifier(key) ? key : nothing
    else
        return Base.isidentifier(key) ?
            ":" * key :
            "\"" * escape_string(key, ('"', '$')) * "\""
    end
end

"""
The `complete_reply` content for a `complete_request` message, or `nothing` if
this is not a column completion. Offsets follow the protocol version of `msg`.
"""
function column_reply(msg::IJulia.Msg, mod::Module = Main)
    code = msg.content["code"]::String
    cursor = msg.content["cursor_pos"]::Int64
    index = min(IJulia.chr2ind(msg, code, cursor), lastindex(code))
    result = column_completion(code[1:index], mod)
    result === nothing && return nothing

    start = IJulia.ind2chr(msg, code, index - ncodeunits(result.partial))
    types = [
        Dict("text" => t[1], "type" => t[2])
        for t in zip(result.matches, result.types)
    ]
    return Dict{String, Any}(
        "status" => "ok",
        "matches" => result.matches,
        "cursor_start" => start,
        "cursor_end" => cursor,
        "metadata" => Dict("_jupyter_types_experimental" => types),
    )
end

const ORIGINAL_COMPLETE_REQUEST = Ref{Any}(nothing)

"""
    install_column_completion!()

Intercept `complete_request` so that column positions complete to column names.
Idempotent.
"""
function install_column_completion!()
    ORIGINAL_COMPLETE_REQUEST[] === nothing || return nothing
    original = IJulia.handlers["complete_request"]
    ORIGINAL_COMPLETE_REQUEST[] = original

    IJulia.handlers["complete_request"] = function (socket, kernel, msg)
        reply = try
            column_reply(msg, kernel.current_module)
        catch
            nothing # never let a failure here hide the ordinary completions
        end
        if reply === nothing
            return original(socket, kernel, msg)
        end
        IJulia.send_ipython(
            kernel.requests[],
            kernel,
            IJulia.msg_reply(msg, "complete_reply", reply),
        )
        return nothing
    end
    return nothing
end

@testitem "column completion in bracket positions" begin
    using Tables

    sandbox = Module(:Sandbox)
    Core.eval(
        sandbox,
        :(df = (alpha = [1, 2], beta = ["a", "b"], var"gamma delta" = [1.5, 2.5])),
    )
    Core.eval(sandbox, :(nested = (inner = df,)))
    Core.eval(sandbox, :(xs = [1, 2, 3]))
    Core.eval(sandbox, :(d = Dict(:a => 1)))

    # Complete against only the sandbox bindings created for this test.
    complete(prefix) = JetJulia.column_completion(prefix, sandbox)
    # Extract match text while preserving the no-column-context sentinel.
    matches(prefix) = (r = complete(prefix); r === nothing ? nothing : r.matches)

    # No prefix: symbols where possible, strings otherwise
    @test matches("df[!, ") == [":alpha", ":beta", "\"gamma delta\""]
    @test matches("df[:, ") == [":alpha", ":beta", "\"gamma delta\""]
    @test matches("df[! , ") == [":alpha", ":beta", "\"gamma delta\""]
    # After `:`, bare names (only those that are valid identifiers)
    @test matches("df[!, :") == ["alpha", "beta"]
    @test matches("df[!, :b") == ["beta"]
    # After `"`, any name
    @test matches("df[!, \"") == ["alpha", "beta", "gamma delta"]
    @test matches("df[!, \"ga") == ["gamma delta"]
    @test matches("df[\"") == ["alpha", "beta", "gamma delta"]

    # What is replaced, and the element types
    r = complete("x = df[!, :al")
    @test r.partial == "al"
    @test r.matches == ["alpha"]
    @test r.types == ["Int64"]
    @test complete("df[!, ").partial == ""

    # Dotted receivers
    @test matches("nested.inner[!, :") == ["alpha", "beta"]

    # Not column positions
    @test complete("df[") === nothing # could be a row index
    @test complete("df[1") === nothing
    @test complete("df[!, al") === nothing # a variable, not a column
    @test complete("xs[!, :") === nothing  # not a table
    @test complete("d[:") === nothing      # dict keys are IJulia's job
    @test complete("missing[!, :") === nothing
    @test complete("f(x).df[!, :") === nothing
    @test complete("nested.nope[!, :") === nothing
    @test complete("df[!, :alpha] + df[!, :") !== nothing
end

@testitem "column_reply builds a complete_reply" begin
    using IJulia, Tables

    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(df = (alpha = [1, 2], beta = ["a", "b"])))

    # Build a completion request with explicit cursor and protocol version.
    request(code, cursor, version = "5.3") = IJulia.Msg(
        ["id"],
        Dict("msg_id" => "m", "msg_type" => "complete_request", "version" => version),
        Dict("code" => code, "cursor_pos" => cursor),
    )

    code = "y = df[!, :a"
    reply = JetJulia.column_reply(request(code, length(code)), sandbox)
    @test reply["status"] == "ok"
    @test reply["matches"] == ["alpha"]
    @test reply["cursor_start"] == length(code) - 1
    @test reply["cursor_end"] == length(code)
    @test reply["metadata"]["_jupyter_types_experimental"] ==
        [Dict("text" => "alpha", "type" => "Int64")]

    # Offsets are in characters, not bytes, before the cursor
    code = "α = df[!, "
    reply = JetJulia.column_reply(request(code, length(code)), sandbox)
    @test reply["matches"] == [":alpha", ":beta"]
    @test reply["cursor_start"] == reply["cursor_end"] == length(code)

    # A cursor in the middle of the buffer only looks at the text before it
    code = "df[!, :b] + 1"
    reply = JetJulia.column_reply(request(code, 8), sandbox)
    @test reply["matches"] == ["beta"]

    @test JetJulia.column_reply(request("sin(", 4), sandbox) === nothing
end

@testitem "the installed handler answers columns and defers otherwise" begin
    using IJulia, Tables

    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(df = (alpha = [1, 2],)))

    sent = []
    deferred = []
    original = IJulia.handlers["complete_request"]
    try
        IJulia.handlers["complete_request"] = (socket, kernel, msg) -> push!(deferred, msg)
        JetJulia.ORIGINAL_COMPLETE_REQUEST[] = nothing
        JetJulia.install_column_completion!()
        handler = IJulia.handlers["complete_request"]
        @test handler !== original

        # Installing twice does not stack wrappers
        JetJulia.install_column_completion!()
        @test IJulia.handlers["complete_request"] === handler

        # Build a protocol-5.3 request with the cursor at the end of code.
        request(code) = IJulia.Msg(
            ["id"],
            Dict("msg_id" => "m", "msg_type" => "complete_request", "version" => "5.3"),
            Dict("code" => code, "cursor_pos" => length(code)),
        )

        # An ordinary request is handed to the original handler. (`kernel` is
        # only used for columns; a missing one makes the column path fail,
        # which must also fall through.)
        handler(nothing, nothing, request("sin("))
        @test length(deferred) == 1
    finally
        IJulia.handlers["complete_request"] = original
        JetJulia.ORIGINAL_COMPLETE_REQUEST[] = nothing
    end
end
