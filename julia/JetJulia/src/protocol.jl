# The `positron.variables` JSON-RPC protocol, independent of the transport.
#
# Requests are `Dict`s as decoded from a comm message
# (`{"jsonrpc": "2.0", "id": ..., "method": ..., "params": ...}`); `respond`
# turns one into the reply message. Events (`refresh`, `update`) are built by
# `refresh!` and `update!`.

const METHOD_NOT_FOUND = -32601
const INVALID_PARAMS = -32602
const INTERNAL_ERROR = -32603

"A JSON-RPC error, sent to the client as an `error` reply."
struct RpcError <: Exception
    code::Int
    message::String
end

"""
State of one open variables comm: the module being inspected, a version
counter (bumped whenever the client is told something changed) and the
snapshot the client last saw.
"""
mutable struct Service
    comm_id::String
    mod::Module
    version::Int
    snapshot::Dict{String, Any}
end
Service(comm_id::AbstractString, mod::Module = Main) = Service(
    String(comm_id),
    mod,
    0,
    Dict{String, Any}(),
)

#
# Messages
#

result_message(id, result) = Dict{String, Any}(
    "jsonrpc" => "2.0",
    "id" => id,
    "result" => result,
)

function error_message(id, err::RpcError)
    return Dict{String, Any}(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict{String, Any}("code" => err.code, "message" => err.message),
    )
end

event_message(name::AbstractString, params) = Dict{String, Any}(
    "jsonrpc" => "2.0",
    "method" => String(name),
    "params" => params,
)

#
# Events
#

"Describe every variable and remember the snapshot; the result of `list` and the `refresh` event."
function refresh!(service::Service)
    variables = collect_variables(service.mod)
    service.version += 1
    service.snapshot = snapshot(service.mod)
    return Dict{String, Any}(
        "variables" => variables,
        "length" => length(variables),
        "version" => service.version,
    )
end

"Parameters of an `update` event, or `nothing` if nothing changed since the last snapshot."
function update!(service::Service)
    current = snapshot(service.mod)
    changed, removed = diff(service.snapshot, current)
    isempty(changed) && isempty(removed) && return nothing

    time = now_ms()
    assigned = Dict{String, Any}[]
    for name in changed
        try
            push!(assigned, variable(name, getglobal(service.mod, Symbol(name)); time))
        catch
            # The variable disappeared or cannot be inspected; the next update fixes it.
        end
    end

    service.version += 1
    service.snapshot = current
    return Dict{String, Any}(
        "assigned" => assigned,
        "unevaluated" => Dict{String, Any}[],
        "removed" => removed,
        "version" => service.version,
    )
end

#
# Requests
#

param(params, key::AbstractString, default = nothing) = params isa AbstractDict ?
    get(params, key, default) :
    default

function path_param(params)
    path = param(params, "path")
    path isa AbstractVector || throw(RpcError(INVALID_PARAMS, "Missing `path`"))
    return String[string(k) for k in path]
end

function delete_global!(mod::Module, name::AbstractString)
    isdefined(Base, :delete_binding) ||
        throw(RpcError(METHOD_NOT_FOUND, "Deleting variables needs Base.delete_binding"))
    sym = Symbol(name)
    is_visible(mod, sym) || return false
    Base.delete_binding(mod, sym)
    return true
end

function clipboard_text(value, format::AbstractString)
    mime = format == "text/html" && showable(MIME("text/html"), value) ?
        MIME("text/html") :
        MIME("text/plain")
    io = IOBuffer()
    show(IOContext(io, :limit => false), mime, value)
    return String(take!(io))
end

handle_request(::Service, ::Val{M}, params) where {M} = throw(RpcError(
    METHOD_NOT_FOUND,
    "Unknown method: $M",
))

handle_request(service::Service, ::Val{:list}, params) = refresh!(service)

function handle_request(service::Service, ::Val{:inspect}, params)
    children, total = inspect(resolve(path_param(params), service.mod))
    return Dict{String, Any}("children" => children, "length" => total)
end

function handle_request(service::Service, ::Val{:clipboard_format}, params)
    value = resolve(path_param(params), service.mod)
    return Dict{String, Any}("content" => clipboard_text(
        value,
        param(params, "format", "text/plain"),
    ))
end

function handle_request(service::Service, ::Val{:delete}, params)
    names = param(params, "names", String[])
    return String[string(n) for n in names if delete_global!(service.mod, string(n))]
end

function handle_request(service::Service, ::Val{:clear}, params)
    for name in visible_names(service.mod)
        delete_global!(service.mod, String(name))
    end
    return nothing
end

handle_request(::Service, ::Val{:view}, params) = throw(RpcError(
    METHOD_NOT_FOUND,
    "Viewing variables is not supported",
))

handle_request(::Service, ::Val{:query_table_summary}, params) = throw(RpcError(
    METHOD_NOT_FOUND,
    "Table summaries are not supported",
))

"Methods after which the client must be told about removed variables."
const MUTATING_METHODS = ("clear", "delete")

function rpc_error(e)
    e isa RpcError && return e
    e isa KeyError && return RpcError(INVALID_PARAMS, "Variable not found: $(e.key)")
    e isa ArgumentError && return RpcError(INVALID_PARAMS, e.msg)
    return RpcError(INTERNAL_ERROR, ellipsize(sprint(showerror, e), 500))
end

"Handle one request and return the reply message. Never throws."
function respond(service::Service, request::AbstractDict)
    id = get(request, "id", nothing)
    try
        method = get(request, "method", nothing)
        method isa AbstractString || throw(RpcError(INVALID_PARAMS, "Missing `method`"))
        return result_message(
            id,
            handle_request(service, Val(Symbol(method)), get(request, "params", nothing)),
        )
    catch e
        return error_message(id, rpc_error(e))
    end
end

@testitem "list replies with the visible variables" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(x = 1))
    Core.eval(sandbox, :(xs = [1, 2]))
    service = JetJulia.Service("c", sandbox)

    reply = JetJulia.respond(service, Dict("id" => 5, "method" => "list"))
    @test reply["jsonrpc"] == "2.0"
    @test reply["id"] == 5
    result = reply["result"]
    @test [v["access_key"] for v in result["variables"]] == ["x", "xs"]
    @test result["length"] == 2
    @test result["version"] == 1
    @test service.version == 1
end

@testitem "inspect returns children and their total" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(nt = (a = 1, b = [1, 2, 3])))
    service = JetJulia.Service("c", sandbox)

    reply = JetJulia.respond(
        service,
        Dict("id" => 1, "method" => "inspect", "params" => Dict("path" => ["nt"])),
    )
    @test [v["access_key"] for v in reply["result"]["children"]] == ["a", "b"]
    @test reply["result"]["length"] == 2

    reply = JetJulia.respond(
        service,
        Dict("id" => 2, "method" => "inspect", "params" => Dict("path" => ["nt", "b"])),
    )
    @test [v["access_key"] for v in reply["result"]["children"]] == ["[1]", "[2]", "[3]"]
end

@testitem "inspect of a missing variable is an invalid-params error" begin
    sandbox = Module(:Sandbox, false)
    service = JetJulia.Service("c", sandbox)

    reply = JetJulia.respond(
        service,
        Dict("id" => 1, "method" => "inspect", "params" => Dict("path" => ["nope"])),
    )
    @test !haskey(reply, "result")
    @test reply["id"] == 1
    @test reply["error"]["code"] == JetJulia.INVALID_PARAMS

    reply = JetJulia.respond(
        service,
        Dict("id" => 2, "method" => "inspect", "params" => Dict()),
    )
    @test reply["error"]["code"] == JetJulia.INVALID_PARAMS
end

@testitem "clipboard_format renders the full value" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(xs = $(collect(1:3))))
    service = JetJulia.Service("c", sandbox)

    request = Dict(
        "id" => 1,
        "method" => "clipboard_format",
        "params" => Dict("path" => ["xs"], "format" => "text/plain"),
    )
    content = JetJulia.respond(service, request)["result"]["content"]
    @test occursin("1", content) && occursin("3", content)
end

@testitem "unknown and unsupported methods are method-not-found errors" begin
    service = JetJulia.Service("c", Module(:Sandbox, false))
    for method in ("bogus", "view", "query_table_summary")
        reply = JetJulia.respond(
            service,
            Dict("id" => 1, "method" => method, "params" => Dict("path" => ["x"])),
        )
        @test reply["error"]["code"] == JetJulia.METHOD_NOT_FOUND
    end
    @test JetJulia.respond(service, Dict("id" => 1))["error"]["code"] ==
        JetJulia.INVALID_PARAMS
end

@testitem "delete and clear remove globals" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(a = 1))
    Core.eval(sandbox, :(b = 2))
    Core.eval(sandbox, :(c = 3))
    service = JetJulia.Service("c", sandbox)

    reply = JetJulia.respond(
        service,
        Dict(
            "id" => 1,
            "method" => "delete",
            "params" => Dict("names" => ["a", "missing"]),
        ),
    )
    @test reply["result"] == ["a"]
    @test JetJulia.visible_names(sandbox) == [:b, :c]

    reply = JetJulia.respond(
        service,
        Dict(
            "id" => 2,
            "method" => "clear",
            "params" => Dict("include_hidden_objects" => false),
        ),
    )
    @test haskey(reply, "result") && reply["result"] === nothing
    @test isempty(JetJulia.visible_names(sandbox))
end

@testitem "update! reports changes, then nothing" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(a = 1))
    service = JetJulia.Service("c", sandbox)
    refresh = JetJulia.refresh!(service)
    @test refresh["version"] == 1
    @test JetJulia.update!(service) === nothing
    @test service.version == 1

    Core.eval(sandbox, :(a = 2))
    Core.eval(sandbox, :(b = "new"))
    update = JetJulia.update!(service)
    @test sort!([v["access_key"] for v in update["assigned"]]) == ["a", "b"]
    @test update["removed"] == String[]
    @test update["version"] == 2

    Base.delete_binding(sandbox, :a)
    update = JetJulia.update!(service)
    @test update["assigned"] == []
    @test update["removed"] == ["a"]
    @test JetJulia.update!(service) === nothing
end

@testitem "event messages have the JSON-RPC notification shape" begin
    msg = JetJulia.event_message("update", Dict("version" => 3))
    @test msg ==
        Dict("jsonrpc" => "2.0", "method" => "update", "params" => Dict("version" => 3))
    @test !haskey(msg, "id")
end
