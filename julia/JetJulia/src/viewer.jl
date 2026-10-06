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

function validate_page(offset, limit)
    offset isa Integer && offset >= 0 ||
        throw(ArgumentError("offset must be a nonnegative integer"))
    limit isa Integer && 1 <= limit <= VIEW_PAGE_SIZE ||
        throw(ArgumentError("limit must be between 1 and $VIEW_PAGE_SIZE"))
    return nothing
end

function grid_page(
    names,
    types,
    rows,
    offset,
    total_rows,
    total_columns;
    row_labels = string.((offset + 1):(offset + length(rows))),
)
    return Dict{String, Any}(
        "names" => names,
        "types" => types,
        "rows" => rows,
        "row_labels" => row_labels,
        "offset" => offset,
        "total_rows" => total_rows,
        "total_columns" => total_columns,
        "columns_truncated" => total_columns > VIEW_MAX_COLUMNS,
    )
end

function table_page(value; offset::Integer = 0, limit::Integer = VIEW_PAGE_SIZE)
    istable(value) ||
        throw(ArgumentError("The viewer supports tables and 1D–3D arrays only"))
    validate_page(offset, limit)
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
    return grid_page(
        viewer_cell.(string.(names)),
        [ellipsize(string(eltype(c)), 30) for c in columns],
        rows,
        offset,
        total_rows,
        total_columns,
    )
end

# Common page entry point: tables and arrays share the wire grid shape.
viewer_page(value; offset = 0, limit = VIEW_PAGE_SIZE, slice = nothing) = table_page(
    value;
    offset,
    limit,
)

function viewer_page(
    value::AbstractArray;
    offset = 0,
    limit = VIEW_PAGE_SIZE,
    slice = nothing,
)
    validate_page(offset, limit)
    1 <= ndims(value) <= 3 ||
        throw(ArgumentError("Array viewing supports 1, 2 or 3 dimensions"))
    row_axis = axes(value, 1)
    col_axis = ndims(value) == 1 ? Base.OneTo(1) : axes(value, 2)
    slice_axis = ndims(value) == 3 ? axes(value, 3) : Base.OneTo(0)
    if ndims(value) == 3
        slice === nothing ||
            slice isa Integer ||
            throw(ArgumentError("slice must be an integer"))
        if isempty(slice_axis)
            slice === nothing || throw(ArgumentError("The third axis has no slices"))
        else
            slice = slice === nothing ? first(slice_axis) : slice
            slice in slice_axis || throw(ArgumentError("slice is outside the third axis"))
        end
    elseif slice !== nothing
        throw(ArgumentError("Only 3D arrays have slice tabs"))
    end

    # Translate page offsets into real axis indices (also for offset arrays).
    total_rows = length(row_axis)
    offset = min(offset, total_rows)
    indices = first(row_axis) .+ collect(offset:(min(offset + limit, total_rows) - 1))
    columns = collect(Iterators.take(col_axis, VIEW_MAX_COLUMNS))
    rows = if ndims(value) == 3 && isempty(slice_axis)
        Vector{String}[]
    else
        [
            [
                viewer_cell(
                    ndims(value) == 1 ?
                        value[i] :
                        ndims(value) == 2 ? value[i, j] : value[i, j, slice],
                )
                for j in columns
            ]
            for i in indices
        ]
    end
    page = grid_page(
        ndims(value) == 1 ? ["value"] : string.(columns),
        fill(ellipsize(string(eltype(value)), 30), length(columns)),
        rows,
        offset,
        total_rows,
        length(col_axis);
        row_labels = string.(first(indices, length(rows))),
    )
    page["shape"] = collect(size(value))
    page["slice_count"] = length(slice_axis)
    page["slice_first"] = first(slice_axis)
    page["slice_last"] = last(slice_axis)
    page["slice"] = slice
    return page
end

function handle_request(service::Service, ::Val{:viewer_page}, params)
    offset = param(params, "offset", 0)
    limit = param(params, "limit", VIEW_PAGE_SIZE)
    validate_page(offset, limit)
    return viewer_page(
        resolve(path_param(params), service.mod);
        offset,
        limit,
        slice = param(params, "slice"),
    )
end

function handle_request(service::Service, ::Val{:table_page}, params)
    offset = param(params, "offset", 0)
    limit = param(params, "limit", VIEW_PAGE_SIZE)
    offset isa Integer && limit isa Integer ||
        throw(ArgumentError("offset and limit must be integers"))
    return table_page(resolve(path_param(params), service.mod); offset, limit)
end

@testitem "array grids preserve orientation and page bounds" begin
    v = JetJulia.viewer_page([10, 20, 30])
    @test v["names"] == ["value"]
    @test v["rows"] == [["10"], ["20"], ["30"]]
    @test v["row_labels"] == ["1", "2", "3"]
    matrix = reshape(1:12, 3, 4)
    page = JetJulia.viewer_page(matrix; offset = 1, limit = 1)
    @test page["rows"] == [["2", "5", "8", "11"]]
    @test page["names"] == ["1", "2", "3", "4"]
    @test page["shape"] == [3, 4]
    @test page["row_labels"] == ["2"]
    @test isempty(JetJulia.viewer_page(matrix; offset = 999)["rows"])
    @test isempty(JetJulia.viewer_page(zeros(0, 3))["rows"])
    @test JetJulia.viewer_page(zeros(3, 0))["rows"] == [String[], String[], String[]]
    @test length(JetJulia.viewer_page(zeros(205, 101))["rows"]) == 100
    @test JetJulia.viewer_page(zeros(205, 101))["columns_truncated"]
    @test JetJulia.viewer_page(view(matrix, 2:3, 2:3))["rows"] == [["5", "8"], ["6", "9"]]
    @test_throws ArgumentError JetJulia.viewer_page(fill(1))
    @test_throws ArgumentError JetJulia.viewer_page(zeros(1, 1, 1, 1))
    @test_throws ArgumentError JetJulia.viewer_page(matrix; slice = 1)
    @test_throws ArgumentError JetJulia.viewer_page(matrix; offset = -1)
end

@testitem "array grids use real axis indices" begin
    struct ShiftedArray{T, N} <: AbstractArray{T, N}
        data::Array{T, N}
        starts::NTuple{N, Int}
    end
    Base.size(a::ShiftedArray) = size(a.data)
    Base.axes(a::ShiftedArray{T, N}) where {T, N} = ntuple(
        d -> a.starts[d]:(a.starts[d] + size(a, d) - 1),
        N,
    )
    Base.getindex(a::ShiftedArray{T, N}, indices::Vararg{Int, N}) where {T, N} = a.data[
        ntuple(d -> indices[d] - a.starts[d] + 1, N)...,
    ]

    a = ShiftedArray(reshape(collect(1:12), 2, 3, 2), (-1, 0, 5))
    page = JetJulia.viewer_page(a; offset = 1, slice = 6)
    @test page["names"] == ["0", "1", "2"]
    @test page["row_labels"] == ["0"]
    @test page["rows"] == [["8", "10", "12"]]
    @test page["slice_first"] == 5
    @test page["slice_last"] == 6
    @test JetJulia.viewer_page(a)["slice"] == 5
    @test_throws ArgumentError JetJulia.viewer_page(a; slice = 1)
end

@testitem "3D arrays load one third-axis slice at a time" begin
    a = reshape(1:18, 3, 3, 2)
    first = JetJulia.viewer_page(a)
    @test first["slice"] == 1
    @test first["slice_count"] == 2
    @test first["slice_first"] == 1
    @test first["slice_last"] == 2
    @test first["rows"] == [["1", "4", "7"], ["2", "5", "8"], ["3", "6", "9"]]
    second = JetJulia.viewer_page(a; slice = 2)
    @test second["rows"] == [["10", "13", "16"], ["11", "14", "17"], ["12", "15", "18"]]
    @test second["shape"] == [3, 3, 2]
    @test_throws ArgumentError JetJulia.viewer_page(a; slice = 0)
    @test_throws ArgumentError JetJulia.viewer_page(a; slice = 3)
    @test_throws ArgumentError JetJulia.viewer_page(a; slice = "bad")
    empty = JetJulia.viewer_page(zeros(3, 3, 0))
    @test empty["slice_count"] == 0
    @test empty["slice"] === nothing
    @test isempty(empty["rows"])
    @test_throws ArgumentError JetJulia.viewer_page(zeros(3, 3, 0); slice = 1)
end

@testitem "viewer RPC handles arrays and still handles tables" begin
    using Tables
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(a = $(reshape(1:18, 3, 3, 2))))
    Core.eval(sandbox, :(df = (x = [1, 2],)))
    service = JetJulia.Service("c", sandbox)
    params = Dict{String, Any}("path" => ["a"], "slice" => 2)
    request = Dict("id" => 1, "method" => "viewer_page", "params" => params)
    @test JetJulia.respond(service, request)["result"]["slice"] == 2
    params["slice"] = 99
    @test JetJulia.respond(service, request)["error"]["code"] == JetJulia.INVALID_PARAMS
    delete!(params, "slice")
    params["path"] = ["df"]
    @test JetJulia.respond(service, request)["result"]["rows"] == [["1"], ["2"]]
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
