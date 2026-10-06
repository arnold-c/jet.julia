# Bounded, transport-free table pages. No evaluation of arbitrary expressions:
# viewers use the same access paths as the variables pane.
const VIEW_PAGE_SIZE = 100
const VIEW_MAX_COLUMNS = 100
const VIEW_CELL_LENGTH = 200

function viewer_cell(value)
    text = value isa AbstractString ? String(value) : compact_string(value)
    # Keep a cell on one screen line, including strings with embedded newlines.
    return ellipsize(
        replace(text, '\n' => "\\n", '\r' => "\\r", '\t' => "\\t"),
        VIEW_CELL_LENGTH,
    )
end

function table_page(value; offset::Integer = 0, limit::Integer = VIEW_PAGE_SIZE)
    istable(value) ||
        throw(ArgumentError("The viewer currently supports Tables.jl tables only"))
    offset >= 0 || throw(ArgumentError("offset must be nonnegative"))
    1 <= limit <= VIEW_PAGE_SIZE ||
        throw(ArgumentError("limit must be between 1 and $VIEW_PAGE_SIZE"))
    cols, names = table_columns(value)
    total_columns = length(names)
    total_rows = isempty(names) ? 0 : length(table_column(cols, first(names)))
    names = first(names, VIEW_MAX_COLUMNS)
    columns = [table_column(cols, name) for name in names]
    all(c -> length(c) == total_rows, columns) ||
        throw(ArgumentError("Table columns have unequal lengths"))
    offset = min(offset, total_rows)
    rows = [
        [viewer_cell(c[firstindex(c) + i - 1]) for c in columns]
        for i in (offset + 1):min(offset + limit, total_rows)
    ]
    return Dict{String, Any}(
        "names" => viewer_cell.(string.(names)),
        "types" => [ellipsize(string(eltype(c)), 30) for c in columns],
        "rows" => rows,
        "offset" => offset,
        "total_rows" => total_rows,
        "total_columns" => total_columns,
        "columns_truncated" => total_columns > VIEW_MAX_COLUMNS,
    )
end

function handle_request(service::Service, ::Val{:table_page}, params)
    offset = param(params, "offset", 0)
    limit = param(params, "limit", VIEW_PAGE_SIZE)
    offset isa Integer && limit isa Integer ||
        throw(ArgumentError("offset and limit must be integers"))
    return table_page(resolve(path_param(params), service.mod); offset, limit)
end

@testitem "table pages are bounded and preserve column order" begin
    using Tables
    value = (alpha = collect(1:205), beta = fill("line\nwith\tspaces", 205))
    page = JetJulia.table_page(value)
    @test page["names"] == ["alpha", "beta"]
    @test page["types"] == ["Int64", "String"]
    @test length(page["rows"]) == 100
    @test page["rows"][1] == ["1", "line\\nwith\\tspaces"]
    @test page["total_rows"] == 205
    @test JetJulia.table_page(value; offset = 200)["rows"][end][1] == "205"
    @test isempty(JetJulia.table_page(value; offset = 999)["rows"])
    @test isempty(JetJulia.table_page((a = Int[],))["rows"])
    @test_throws ArgumentError JetJulia.table_page(3)
    @test_throws ArgumentError JetJulia.table_page(value; offset = -1)
    @test_throws ArgumentError JetJulia.table_page(value; limit = 101)
    @test length(JetJulia.viewer_cell(repeat("α", 500))) <= 200
    wide = NamedTuple{Tuple(Symbol("c$i") for i in 1:101)}(Tuple([i] for i in 1:101))
    page = JetJulia.table_page(wide)
    @test length(page["names"]) == 100
    @test page["total_columns"] == 101
    @test page["columns_truncated"]
end

@testitem "table pages resolve variables through RPC" begin
    using Tables
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(df = (a = [1, 2],)))
    service = JetJulia.Service("c", sandbox)
    request = Dict(
        "id" => 1,
        "method" => "table_page",
        "params" => Dict{String, Any}("path" => ["df"]),
    )
    @test JetJulia.respond(service, request)["result"]["rows"] == [["1"], ["2"]]
    request["params"]["offset"] = "bad"
    @test JetJulia.respond(service, request)["error"]["code"] == JetJulia.INVALID_PARAMS
end
