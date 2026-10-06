# The variables model: what the `positron.variables` comm says about globals.
#
# Everything here is plain Julia with no IJulia dependency. Extend the
# per-type behaviour by adding methods to `kind`, `display_value`,
# `display_type`, `n_children`, `children`, `child` and `length_of`.
#
# Values are described with `Dict{String,Any}` (the JSON-RPC wire shape), see
# the schema in jet.ark's `resources/positron-comms/variables*.json`.
#
# Calls into packages the user may have loaded after the kernel started
# (Tables.jl, user `show` methods) rely on the caller running in the latest
# world age; the comm entry points use `Base.invokelatest`.

const MAX_DISPLAY = 500
const MAX_CHILDREN = 500
const ELLIPSIS = "…"

"Values with no inspectable children."
const Atomic = Union{
    Number,
    AbstractString,
    Function,
    Type,
    Nothing,
    Missing,
    Symbol,
    Module,
}

"Names in `Main` that are never user variables."
const HIDDEN_NAMES = (:Base, :Core, :Main, :ans, :include, :eval, :In, :Out)

#
# Optional Tables.jl support (looked up, never imported)
#

const TABLES_ID = Base.PkgId(Base.UUID("bd369af6-aec1-5ad0-b16a-f7cc5008161c"), "Tables")

tables_module() = get(Base.loaded_modules, TABLES_ID, nothing)

function istable(x)
    T = tables_module()
    T === nothing && return false
    try
        return Base.invokelatest(T.istable, x)::Bool
    catch
        return false
    end
end

"`(columns, names)` of a table."
function table_columns(x)
    T = tables_module()
    cols = Base.invokelatest(T.columns, x)
    return cols, collect(Base.invokelatest(T.columnnames, cols))
end

table_column(cols, name) = Base.invokelatest(tables_module().getcolumn, cols, name)

"`(nrow, ncol)` if `x` is a table, otherwise `nothing`."
function table_dims(x)
    istable(x) || return nothing
    try
        cols, names = table_columns(x)
        nrow = isempty(names) ? 0 : length(table_column(cols, first(names)))
        return (nrow, length(names))
    catch
        return nothing
    end
end

#
# Display helpers
#

ellipsize(s::AbstractString, n::Integer = MAX_DISPLAY) = length(s) > n ?
    first(s, n - 1) * ELLIPSIS :
    String(s)

function compact_string(x)
    io = IOBuffer()
    try
        show(IOContext(io, :compact => true, :limit => true), x)
    catch
        return "<error displaying value>"
    end
    return ellipsize(String(take!(io)))
end

#
# Per-type behaviour
#

"""
The Positron variable kind: one of `boolean`, `bytes`, `class`, `collection`,
`empty`, `function`, `map`, `number`, `other`, `string`, `table`.
"""
kind(::Bool) = "boolean"
kind(::Number) = "number"
kind(::AbstractString) = "string"
kind(::Function) = "function"
kind(::AbstractDict) = "map"
kind(::AbstractArray) = "collection"
kind(::Union{Nothing, Missing}) = "empty"
kind(::Type) = "class"
kind(x) = istable(x) ? "table" : "other"

function display_value(x)
    dims = table_dims(x)
    dims === nothing || return "[$(dims[1]) rows x $(dims[2]) columns] $(nameof(typeof(x)))"
    return compact_string(x)
end
display_value(x::AbstractArray) = compact_string(x)
display_value(x::AbstractDict) = compact_string(x)
function display_value(x::AbstractString)
    # `show` prints the whole string, so cut very long ones first.
    limit = 4 * MAX_DISPLAY
    shown = ncodeunits(x) > limit ? SubString(x, 1, thisind(x, limit)) : x
    return ellipsize(repr(shown))
end

# The type column is narrow, so types are shown compactly: the type's name
# (with parameters if short), then the shape in brackets: `Vector{Int64} [3]`,
# `Matrix{Float64} [3, 4]`, `DataFrame [10, 3]`. The full type is in `type_info`.

const MAX_TYPE_LABEL = 30

"The type of `x`, without parameters if they would make it long."
function type_label(x)
    T = typeof(x)
    s = string(T)
    return length(s) <= MAX_TYPE_LABEL ? s : string(nameof(T))
end

shape_label(dims) = "[" * join(dims, ", ") * "]"

"`Name [rows, cols]` for tables, otherwise `nothing`."
function table_label(x)
    dims = table_dims(x)
    return dims === nothing ? nothing : "$(nameof(typeof(x))) $(shape_label(dims))"
end

display_type(x) = something(table_label(x), type_label(x))
display_type(::Function) = "Function"
display_type(x::AbstractDict) = "$(type_label(x)) $(shape_label((length(x),)))"
display_type(x::Union{Tuple, NamedTuple}) = something(
    table_label(x),
    "$(type_label(x)) $(shape_label((length(x),)))",
)
function display_type(x::AbstractArray)
    return ndims(x) == 0 ? type_label(x) : "$(type_label(x)) $(shape_label(size(x)))"
end

"The number of elements: rows for tables, the first dimension for arrays."
function length_of(x)
    dims = table_dims(x)
    dims === nothing || return dims[1]
    try
        return Int(length(x))
    catch
        return 0
    end
end
length_of(x::AbstractArray) = ndims(x) == 0 ? 0 : size(x, 1)

"The total number of children `x` has (`children` returns at most `MAX_CHILDREN`)."
function n_children(x)
    dims = table_dims(x)
    dims === nothing || return dims[2]
    return fieldcount(typeof(x))
end
n_children(::Atomic) = 0
n_children(x::AbstractDict) = length(x)
n_children(x::AbstractArray) = ndims(x) == 0 ? 0 : size(x, 1)

"Child keys and values, in display order."
function children(x)
    out = Pair{String, Any}[]
    if istable(x)
        cols, names = table_columns(x)
        for name in Iterators.take(names, MAX_CHILDREN)
            push!(out, string(name) => table_column(cols, name))
        end
        return out
    end
    for f in Iterators.take(fieldnames(typeof(x)), MAX_CHILDREN)
        isdefined(x, f) && push!(out, string(f) => getfield(x, f))
    end
    return out
end
children(::Atomic) = Pair{String, Any}[]
children(x::AbstractDict) = [string(k) => v for (k, v) in Iterators.take(x, MAX_CHILDREN)]
function children(x::AbstractArray)
    ndims(x) == 0 && return Pair{String, Any}[]
    return [index_key(i) => element(x, i) for i in Iterators.take(axes(x, 1), MAX_CHILDREN)]
end

"The child of `x` with access key `key`; throws `KeyError` if there is none."
function child(x, key::AbstractString)
    if istable(x)
        cols, names = table_columns(x)
        for name in names
            string(name) == key && return table_column(cols, name)
        end
        throw(KeyError(key))
    end
    for f in fieldnames(typeof(x))
        string(f) == key && return getfield(x, f)
    end
    throw(KeyError(key))
end
child(::Atomic, key::AbstractString) = throw(KeyError(key))
function child(x::AbstractDict, key::AbstractString)
    for (k, v) in x
        string(k) == key && return v
    end
    throw(KeyError(key))
end
function child(x::AbstractArray, key::AbstractString)
    i = parse_index(key)
    i in axes(x, 1) || throw(KeyError(key))
    return element(x, i)
end

index_key(i) = "[$i]"
parse_index(key::AbstractString) = parse(Int, strip(key, ['[', ']']))

"Element `i` along the first dimension; a slice for higher-dimensional arrays."
element(x::AbstractArray, i) = ndims(x) == 1 ? x[i] : selectdim(x, 1, i)

function byte_size(x)
    try
        return Int(Base.summarysize(x))
    catch
        return 0
    end
end

#
# Variables on the wire
#

now_ms() = round(Int, time() * 1000)

"Describe `value`, stored under `key`, as a `Variable` message."
function variable(key::AbstractString, value; time::Integer = now_ms())
    display = display_value(value)
    return Dict{String, Any}(
        "access_key" => String(key),
        "display_name" => String(key),
        "display_value" => display,
        "display_type" => display_type(value),
        "type_info" => string(typeof(value)),
        "size" => byte_size(value),
        "kind" => kind(value),
        "length" => length_of(value),
        "has_children" => n_children(value) > 0,
        # Data viewing is not provided by this comm; see `:JuliaView`.
        "has_viewer" => false,
        "is_truncated" => endswith(display, ELLIPSIS),
        "updated_time" => time,
    )
end

#
# Globals
#

function is_visible(mod::Module, name::Symbol)
    s = String(name)
    (startswith(s, "#") || startswith(s, "_")) && return false
    name in HIDDEN_NAMES && return false
    isdefined(mod, name) || return false
    Base.isdeprecated(mod, name) && return false
    return !(getglobal(mod, name) isa Module)
end

# `names(Main)` lists the globals defined at the REPL; other modules need
# `all = true` to list non-exported names too.
visible_names(mod::Module = Main) = sort!(filter(
    n -> is_visible(mod, n),
    names(mod; all = mod !== Main),
))

"All visible globals of `mod` as `Variable` messages."
function collect_variables(mod::Module = Main)
    time = now_ms()
    out = Dict{String, Any}[]
    for name in visible_names(mod)
        try
            push!(out, variable(string(name), getglobal(mod, name); time))
        catch
            # Skip variables that cannot be inspected.
        end
    end
    return out
end

"""
Resolve an access-key `path` (a global name, then child keys) to a value.
Throws `KeyError` if any step is missing.
"""
function resolve(path::AbstractVector{<:AbstractString}, mod::Module = Main)
    isempty(path) && throw(ArgumentError("empty path"))
    name = Symbol(first(path))
    isdefined(mod, name) || throw(KeyError(first(path)))
    value = getglobal(mod, name)
    for key in path[(begin + 1):end]
        value = child(value, key)
    end
    return value
end

"`(children, total)` for inspecting `value`."
function inspect(value; time::Integer = now_ms())
    kids = [variable(key, v; time) for (key, v) in children(value)]
    return kids, n_children(value)
end

#
# Change detection: a cheap fingerprint per variable, so that only changed
# variables are described in full after each execution.
#

function fingerprint(x)
    try
        return (string(typeof(x)), display_value(x), length_of(x))
    catch
        return ("?", "?", 0)
    end
end

function snapshot(mod::Module = Main)
    out = Dict{String, Any}()
    for name in visible_names(mod)
        try
            out[string(name)] = fingerprint(getglobal(mod, name))
        catch
        end
    end
    return out
end

"`(changed, removed)` names between two snapshots."
function diff(old::AbstractDict, new::AbstractDict)
    changed = sort!([k for (k, fp) in new if !isequal(get(old, k, nothing), fp)])
    removed = sort!([k for k in keys(old) if !haskey(new, k)])
    return changed, removed
end

@testitem "kind covers the basic types" begin
    @test JetJulia.kind(true) == "boolean"
    @test JetJulia.kind(1) == "number"
    @test JetJulia.kind(1.5) == "number"
    @test JetJulia.kind("a") == "string"
    @test JetJulia.kind(sin) == "function"
    @test JetJulia.kind(Dict(1 => 2)) == "map"
    @test JetJulia.kind([1, 2]) == "collection"
    @test JetJulia.kind(nothing) == "empty"
    @test JetJulia.kind(missing) == "empty"
    @test JetJulia.kind(Int) == "class"
    @test JetJulia.kind((1, 2)) == "other"
end

@testitem "display_value is bounded and single-valued" begin
    @test JetJulia.display_value(1) == "1"
    @test JetJulia.display_value("hi") == "\"hi\""
    long = JetJulia.display_value("x"^10_000)
    @test length(long) == JetJulia.MAX_DISPLAY
    @test endswith(long, "…")
    @test JetJulia.display_value("α"^10_000) |> length == JetJulia.MAX_DISPLAY
    @test JetJulia.display_value(1:5) == "1:5"
end

@testitem "display_type is compact and shows the shape" begin
    @test JetJulia.display_type(1) == "Int64"
    @test JetJulia.display_type("s") == "String"
    @test JetJulia.display_type(sin) == "Function"
    @test JetJulia.display_type(Int) == "DataType"
    @test JetJulia.display_type([1, 2, 3]) == "Vector{Int64} [3]"
    @test JetJulia.display_type(ones(3, 4)) == "Matrix{Float64} [3, 4]"
    @test JetJulia.display_type(Int[]) == "Vector{Int64} [0]"
    @test JetJulia.display_type(fill(1)) == "Array{Int64, 0}"
    @test JetJulia.display_type(Dict(:a => 1)) == "Dict{Symbol, Int64} [1]"
    @test JetJulia.display_type((1, 2)) == "Tuple{Int64, Int64} [2]"

    # Long parameter lists fall back to the bare name
    @test JetJulia.display_type((x = 30, a = "testing")) == "NamedTuple [2]"
    long = Dict("a" => (1, 2, 3))
    @test JetJulia.display_type(long) == "Dict [1]"

    # The full type is still available
    @test JetJulia.variable("q", (x = 30, a = "testing"))["type_info"] ==
        "@NamedTuple{x::Int64, a::String}"
end

@testitem "length_of and n_children" begin
    @test JetJulia.length_of([1, 2, 3]) == 3
    @test JetJulia.length_of(ones(4, 2)) == 4
    @test JetJulia.length_of(fill(1)) == 0
    @test JetJulia.length_of(Dict(1 => 2, 3 => 4)) == 2
    @test JetJulia.n_children(1) == 0
    @test JetJulia.n_children("abc") == 0
    @test JetJulia.n_children(sin) == 0
    @test JetJulia.n_children(Int[]) == 0
    @test JetJulia.n_children([1, 2]) == 2
    @test JetJulia.n_children(Dict(1 => 2)) == 1
    @test JetJulia.n_children((a = 1, b = 2)) == 2
end

@testitem "children and child agree for collections" begin
    arr = [10, 20, 30]
    @test JetJulia.children(arr) == ["[1]" => 10, "[2]" => 20, "[3]" => 30]
    @test JetJulia.child(arr, "[2]") == 20
    @test_throws KeyError JetJulia.child(arr, "[4]")

    mat = [1 2; 3 4]
    @test JetJulia.child(mat, "[2]") == [3, 4]

    dict = Dict(:a => 1, "b" => 2)
    @test Dict(JetJulia.children(dict)) == Dict("a" => 1, "b" => 2)
    @test JetJulia.child(dict, "a") == 1
    @test_throws KeyError JetJulia.child(dict, "z")

    nt = (x = 1, y = "two")
    @test JetJulia.children(nt) == ["x" => 1, "y" => "two"]
    @test JetJulia.child(nt, "y") == "two"
    @test_throws KeyError JetJulia.child(1, "x")
end

@testitem "children are capped but the total is reported" begin
    big = collect(1:(JetJulia.MAX_CHILDREN + 10))
    kids, total = JetJulia.inspect(big)
    @test length(kids) == JetJulia.MAX_CHILDREN
    @test total == length(big)
end

@testitem "tables are recognised once Tables.jl is loaded" begin
    using Tables
    t = (a = [1, 2, 3], b = ["x", "y", "z"])
    @test JetJulia.kind(t) == "table"
    @test JetJulia.display_value(t) == "[3 rows x 2 columns] NamedTuple"
    @test JetJulia.display_type(t) == "NamedTuple [3, 2]"
    @test JetJulia.length_of(t) == 3
    @test JetJulia.n_children(t) == 2
    @test JetJulia.children(t) == ["a" => [1, 2, 3], "b" => ["x", "y", "z"]]
    @test JetJulia.child(t, "b") == ["x", "y", "z"]
    @test_throws KeyError JetJulia.child(t, "c")
end

@testitem "variable describes a value" begin
    v = JetJulia.variable("xs", [1, 2, 3]; time = 7)
    @test v["access_key"] == "xs"
    @test v["display_name"] == "xs"
    @test v["display_value"] == "[1, 2, 3]"
    @test v["display_type"] == "Vector{Int64} [3]"
    @test v["type_info"] == "Vector{Int64}"
    @test v["kind"] == "collection"
    @test v["length"] == 3
    @test v["has_children"] === true
    @test v["has_viewer"] === false
    @test v["is_truncated"] === false
    @test v["updated_time"] == 7
    @test v["size"] > 0

    @test JetJulia.variable("n", 1)["has_children"] === false
    @test JetJulia.variable("s", "x"^10_000)["is_truncated"] === true
end

@testitem "globals are listed and resolved" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(x = 1))
    Core.eval(sandbox, :(_hidden = 2))
    Core.eval(sandbox, :(f(a) = a))
    Core.eval(sandbox, :(nt = (p = [1, 2], q = "s")))
    Core.eval(sandbox, :(ans = 3))

    @test JetJulia.visible_names(sandbox) == [:f, :nt, :x]
    @test sort!([v["access_key"] for v in JetJulia.collect_variables(sandbox)]) ==
        ["f", "nt", "x"]

    @test JetJulia.resolve(["x"], sandbox) == 1
    @test JetJulia.resolve(["nt", "p"], sandbox) == [1, 2]
    @test JetJulia.resolve(["nt", "p", "[2]"], sandbox) == 2
    @test_throws KeyError JetJulia.resolve(["missing"], sandbox)
    @test_throws KeyError JetJulia.resolve(["nt", "zzz"], sandbox)
    @test_throws ArgumentError JetJulia.resolve(String[], sandbox)
end

@testitem "nothing-valued children can be resolved" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(d = $(Dict("k" => nothing))))
    @test JetJulia.resolve(["d", "k"], sandbox) === nothing
end

@testitem "modules are not listed as variables" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(m = $Base))
    @test isempty(JetJulia.visible_names(sandbox))
end

@testitem "diff reports changed and removed variables" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(a = 1))
    Core.eval(sandbox, :(b = [1, 2]))
    before = JetJulia.snapshot(sandbox)

    @test JetJulia.diff(before, JetJulia.snapshot(sandbox)) == (String[], String[])

    Core.eval(sandbox, :(a = 2))
    Core.eval(sandbox, :(c = "new"))
    push!(Core.eval(sandbox, :b), 3) # mutated in place
    after = JetJulia.snapshot(sandbox)
    @test JetJulia.diff(before, after) == (["a", "b", "c"], String[])

    Base.delete_binding(sandbox, :a)
    @test JetJulia.diff(after, JetJulia.snapshot(sandbox)) == (String[], ["a"])
end
