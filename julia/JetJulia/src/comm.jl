# The IJulia transport for the variables protocol (see `protocol.jl`).
#
# The client (Neovim) opens a `positron.variables` comm; IJulia then calls
# `register_comm`. Replies are parented on the request message and events on
# the message that caused them (the comm_open, the request, or the executing
# cell), since clients match replies by `parent_header.msg_id`.

const TARGET = "positron.variables"

"Currently open variables comms, by comm id."
const SERVICES = Dict{String, Service}()

const STARTED = Ref(false)

"Publish a `comm_msg` carrying `data` on IOPub, as a child of `parent`."
function publish(parent::IJulia.Msg, comm_id::AbstractString, data)
    kernel = IJulia._default_kernel
    content = Dict{String, Any}("comm_id" => String(comm_id), "data" => data)
    IJulia.send_ipython(
        kernel.publish[],
        kernel,
        IJulia.msg_pub(parent, "comm_msg", content),
    )
    return nothing
end

function send_update(service::Service, parent::IJulia.Msg, send)
    params = update!(service)
    params === nothing || send(parent, service.comm_id, event_message("update", params))
    return nothing
end

# Errors must never escape into IJulia's event loop.
function on_comm_msg(service::Service, msg::IJulia.Msg, send)
    try
        request = get(msg.content, "data", Dict{String, Any}())
        send(msg, service.comm_id, Base.invokelatest(respond, service, request))
        if get(request, "method", nothing) in MUTATING_METHODS
            Base.invokelatest(send_update, service, msg, send)
        end
    catch e
        @warn "JetJulia: error handling variables comm message" exception = (
            e,
            catch_backtrace(),
        )
    end
    return nothing
end

"Start serving a freshly opened comm: reply to requests and send the initial `refresh`."
function open_comm!(
    comm::IJulia.Comm,
    open_msg::IJulia.Msg,
    send = publish;
    mod::Module = Main,
)
    service = Service(comm.id, mod)
    SERVICES[comm.id] = service
    comm.on_msg = msg -> on_comm_msg(service, msg, send)
    comm.on_close = _ -> delete!(SERVICES, service.comm_id)
    send(open_msg, comm.id, event_message("refresh", Base.invokelatest(refresh!, service)))
    return service
end

# IJulia dispatches on the comm's target type, in place of `register_target`.
function IJulia.register_comm(
    comm::IJulia.Comm{Symbol("positron.variables")},
    msg::IJulia.Msg,
)
    try
        open_comm!(comm, msg)
    catch e
        @warn "JetJulia: failed to open the variables comm" exception = (
            e,
            catch_backtrace(),
        )
    end
    return nothing
end

"Tell open comms about variables changed by the cell that just ran."
function on_post_execute()
    kernel = IJulia._default_kernel
    kernel === nothing && return nothing
    for service in collect(values(SERVICES))
        try
            send_update(service, kernel.execute_msg, publish)
        catch e
            @warn "JetJulia: error sending a variables update" exception = (
                e,
                catch_backtrace(),
            )
        end
    end
    return nothing
end

"""
    start()

Register the variables comm target and the post-execute hook. Idempotent.
"""
function start()
    STARTED[] && return nothing
    IJulia.push_postexecute_hook(on_post_execute)
    STARTED[] = true
    return nothing
end

@testitem "register_comm is defined for the variables target" begin
    using IJulia
    @test hasmethod(
        IJulia.register_comm,
        Tuple{IJulia.Comm{Symbol("positron.variables")}, IJulia.Msg},
    )
end

@testitem "an opened comm refreshes, replies, and updates" begin
    using IJulia

    msg(type, content) = IJulia.Msg(
        ["id"],
        Dict("msg_id" => "m-$type", "msg_type" => type),
        content,
    )

    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(x = 1))

    sent = []
    send(parent, comm_id, data) = push!(sent, (parent, comm_id, data))

    fake_kernel = (comms = Dict{String, Any}(),)
    comm = IJulia.Comm{Symbol("positron.variables")}(
        "comm-1",
        false,
        identity,
        identity,
        fake_kernel,
    )
    open_msg = msg(
        "comm_open",
        Dict("comm_id" => "comm-1", "target_name" => "positron.variables"),
    )

    service = JetJulia.open_comm!(comm, open_msg, send; mod = sandbox)
    @test haskey(JetJulia.SERVICES, "comm-1")

    # The initial refresh is parented on the comm_open message.
    @test length(sent) == 1
    parent, comm_id, data = only(sent)
    @test parent === open_msg
    @test comm_id == "comm-1"
    @test data["method"] == "refresh"
    @test [v["access_key"] for v in data["params"]["variables"]] == ["x"]

    # A request gets a reply parented on the request.
    empty!(sent)
    request = msg(
        "comm_msg",
        Dict(
            "comm_id" => "comm-1",
            "data" => Dict("jsonrpc" => "2.0", "id" => 9, "method" => "list"),
        ),
    )
    comm.on_msg(request)
    parent, _, data = only(sent)
    @test parent === request
    @test data["id"] == 9
    @test haskey(data, "result")

    # Deleting sends the reply, then an update with the removal.
    empty!(sent)
    delete = msg(
        "comm_msg",
        Dict(
            "comm_id" => "comm-1",
            "data" => Dict(
                "id" => 10,
                "method" => "delete",
                "params" => Dict("names" => ["x"]),
            ),
        ),
    )
    comm.on_msg(delete)
    @test length(sent) == 2
    @test sent[1][3]["result"] == ["x"]
    @test sent[2][3]["method"] == "update"
    @test sent[2][3]["params"]["removed"] == ["x"]

    # Closing forgets the service.
    comm.on_close(msg("comm_close", Dict("comm_id" => "comm-1")))
    @test !haskey(JetJulia.SERVICES, "comm-1")
end

@testitem "errors in a comm handler do not escape" begin
    using IJulia

    sandbox = Module(:Sandbox, false)
    service = JetJulia.Service("comm-2", sandbox)
    request = IJulia.Msg(
        ["id"],
        Dict("msg_id" => "m"),
        Dict("data" => Dict("id" => 1, "method" => "list")),
    )
    boom(args...) = error("transport failed")

    @test JetJulia.on_comm_msg(service, request, boom) === nothing
end
