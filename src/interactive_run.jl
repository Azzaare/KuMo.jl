struct InteractiveRun{T<:AbstractTopology} <: AbstractExecution
    algo::AbstractAlgorithm
    infrastructure::Infrastructure{T}
    output::String
    time_limit::Float64
    verbose::Bool

    function InteractiveRun(;
        algo::AbstractAlgorithm=ShortestPath(),
        infrastructure::Infrastructure{T}=Infrastructure{DirectedTopology}(),
        output::String="",
        time_limit::Float64=Inf,
        verbose::Bool=false
    ) where {T<:AbstractTopology}
        return new{T}(algo, infrastructure, output, time_limit, verbose)
    end
end

time_limit(execution::InteractiveRun) = execution.time_limit

struct InteractiveChannels <: AbstractContainers
    has_queue::Channel{Bool}
    infras::Channel{StructAction}
    loads::Channel{LoadJobAction}
    stop::Channel{Bool}
    unchecked_unload::Channel{Bool}
    unloads::Channel{UnloadJobAction}

    function InteractiveChannels()
        channels_size = typemax(Int)
        has_queue = Channel{Bool}(channels_size)
        infras = Channel{StructAction}(channels_size)
        loads = Channel{LoadJobAction}(channels_size)
        stop = Channel{Bool}(1)
        unchecked_unload = Channel{Bool}(1)
        unloads = Channel{UnloadJobAction}(channels_size)
        return new(has_queue, infras, loads, stop, unchecked_unload, unloads)
    end
end

function extract_containers(containers::InteractiveChannels)
    has_queue = containers.has_queue
    infras = containers.infras
    loads = containers.loads
    stop = containers.stop
    unchecked_unload = containers.unchecked_unload
    unloads = containers.unloads
    return has_queue, infras, loads, stop, unchecked_unload, unloads
end

"""
    init_execution(::InteractiveRun)

Initialize an interactive run.
"""
init_execution(::InteractiveRun) = InteractiveChannels()

function execute_loop(exe::InteractiveRun, args, containers, start)
    _, demands, g, _, snapshots, _, times = extract_loop_arguments(args)
    v = verbose(exe)

    v && println("Starting the interactive loop...")
    push!(times, "start_tasks" => time() - start)
    put!(containers.unchecked_unload, true)

    # @info containers

    @spawn :interactive begin
        v && println("Interactive loop started.")
        while true
            # @info "pit stop 1"
            take!(containers.has_queue)
            n = nv(g) - vtx(exe.algo)


            # @info "pit stop 2"

            # Check if the stop signal is received
            if isready(containers.stop) ? fetch(containers.stop) : false
                # @info "pit stop 3"
                v && (@info "Stopping the interactive run after $(time() - start) seconds")
                break
            end

            # Check if there are any new infrastructures
            if isready(containers.infras)
                # @info "pit stop 4"
                infra = take!(containers.infras)
                do!(exe, args, infra)
                continue
            end

            # Check if there are any jobs to unload
            if isready(containers.unloads)
                # @warn "debug 2: unload"
                unload = take!(containers.unloads)
                # take!(containers.has_queue)
                # @warn "debug 2.1: unload"
                v, c, ls = unload.node, unload.vload, unload.lloads
                rem_load!(args.state, ls, c, v, n, g)
                push_snap!(snapshots, args.state, 0, 0, 0, 0, time() - start, n)
                add_snap_to_df!()

                # @warn "debug 2.2: unload"
                isready(containers.unchecked_unload) || put!(containers.unchecked_unload, true)
                continue
            end

            # @warn "debug containters" containers.has_queue containers.unchecked_unload containers.loads containers.unloads

            # Check if there are any jobs to load
            if isready(containers.loads) && isready(containers.unchecked_unload)
                # @warn "debug 1: checking if load is valid"
                task = fetch(containers.loads)
                best_links, best_cost, best_node, is_valid = valid_load(exe, task, args)
                # @warn "debug 1: load is valid <- $is_valid"
                if is_valid
                    take!(containers.loads)
                    j = task.job
                    # @warn "inner pit stop 1" args.state best_links j.containers best_node n g

                    # Add load
                    add_load!(args.state, best_links, j.containers, best_node, n, g)

                    # @warn "inner pit stop 2"

                    # Snap new state
                    push_snap!(snapshots, args.state, 0, 0, 0, 0, time() - start, n)


                    # @warn "inner pit stop 3"

                    # Assign unload
                    @spawn begin
                        # @info "assigning unload start" containers.has_queue containers.unloads
                        sleep(j.duration)
                        # @info "inner unload assignment 1"
                        put!(containers.unloads, UnloadJobAction(time() - start, best_node, j.containers, best_links))
                        # @info "inner unload assignment 2"
                        put!(containers.has_queue, true)
                        # @info "assigning unload stop" containers.has_queue containers.unloads
                    end
                else
                    put!(containers.has_queue, true)
                    take!(containers.unchecked_unload)
                end
            end
        end
    end

    return nothing
end

struct InteractiveInterface
    args::LoopArguments
    containers::InteractiveChannels
    exe::InteractiveRun
    results::ExecutionResults
    start::Float64
end

"""
    post_simulate(s, snapshots, verbose, output)

Post-simulation process that covers cleaning the snapshots and producing an output.

# Arguments:
- `s`: simulated scenario
- `snapshots`: resulting snapshots (before cleaning)
- `verbose`: if set to true, prints information about the output and the snapshots
- `output`: output path
"""
function execution_results(exe::InteractiveRun, args, containers, start)
    df = DataFrame(
        selected=Float64[],
        total=Float64[],
        duration=Float64[],
        solving_time=Float64[],
        instant=Float64[]
    )
    return InteractiveInterface(args, containers, exe, ExecutionResults(df, args.times), start)
end

results(agent::InteractiveInterface) = agent.results

function results!(agent::InteractiveInterface)
    verbose = agent.exe.verbose
    df = make_df(clean(agent.args.snapshots), agent.exe.infrastructure.topology; verbose)
    sort!(df, :instant)

    if !isempty(agent.exe.output)
        CSV.write(joinpath(datadir(), output(agent.exe)), df)
        verbose && (@info "Output written in $(datadir())")
    end
    verbose && pretty_table(df)

    agent.results.df = df

    return results(agent)
end

##SECTION - Interface functions for Interactive runs. Uses the InteractiveInterface struct.

# stop
function stop!(agent::InteractiveInterface)
    put!(agent.containers.stop, true)
    put!(agent.containers.has_queue, true)
    return agent
end

# node
function add_node!(exe::InteractiveRun, t::Float64, r::N) where {N<:AbstractNode}
    exe.infrastructure.n += 1
    return NodeAction(exe.infrastructure.n, t, r)
end

rem_node!(::InteractiveRun, t::Float64, id::Int64) = NodeAction(id, t, nothing)

function change_node!(::InteractiveRun, t::Float64, id::Int64, r::N) where {N<:AbstractNode}
    return NodeAction(id, t, r)
end

function node!(agent::InteractiveInterface, args...)
    t = time() - agent.start
    action = node!(agent.exe, t, args...)
    put!(agent.containers.infras, action)
    put!(agent.containers.has_queue, true)
    return agent
end

# link
function add_link!(exe::InteractiveRun, t::Float64, source::Int, target::Int, r::L) where {L<:AbstractLink}
    exe.infrastructure.m += 1
    return LinkAction(t, r, source, target)
end

function rem_link!(::InteractiveRun, t::Float64, source::Int, target::Int)
    return LinkAction(t, nothing, source, target)
end

function change_link!(::InteractiveRun, t::Float64, source::Int, target::Int, r::L) where {L<:AbstractLink}
    return LinkAction(t, r, source, target)
end

function link!(agent::InteractiveInterface, args...)
    t = time() - agent.start
    action = link!(agent.exe, t, args...)
    put!(agent.containers.infras, action)
    put!(agent.containers.has_queue, true)
    return agent
end

# user
function add_user!(exe::InteractiveRun, t::Float64, loc::Int)
    exe.infrastructure.u += 1
    return UserAction(exe.infrastructure.u, loc, t)
end

function rem_user!(::InteractiveRun, t::Float64, id::Int)
    return UserAction(id, nothing, t)
end

function move_user!(::InteractiveRun, t::Float64, id::Int, loc::Int)
    return UserAction(id, loc, t)
end

function user!(agent::InteractiveInterface, args...)
    t = time() - agent.start
    action = user!(agent.exe, t, args...)
    put!(agent.containers.infras, action)
    put!(agent.containers.has_queue, true)
    return agent
end

# data
function add_data!(exe::InteractiveRun, t::Float64, loc::Int)
    exe.infrastructure.d += 1
    return DataAction(exe.infrastructure.d, loc, t)
end

function rem_data!(::InteractiveRun, t::Float64, id::Int)
    return DataAction(id, nothing, t)
end

function move_data!(::InteractiveRun, t::Float64, id::Int, loc::Int)
    return DataAction(id, loc, t)
end

function data!(agent::InteractiveInterface, args...)
    t = time() - agent.start
    action = data!(agent.exe, t, args...)
    put!(agent.containers.infras, action)
    put!(agent.containers.has_queue, true)
    return agent
end

# job
function add_job!(::InteractiveRun, t::Float64, j::J, u_id::Int, d_id::Int) where {J<:AbstractJob}
    # @info "entered add_job" LoadJobAction(t, u_id, j, d_id)
    return LoadJobAction(t, u_id, j, d_id)
end

function job!(agent::InteractiveInterface, args...)
    t = time() - agent.start
    action = job!(agent.exe, t, args...)
    put!(agent.containers.loads, action)
    put!(agent.containers.has_queue, true)
    return agent
end

function job!(
    agent::InteractiveInterface,
    backend,
    container,
    duration,
    frontend,
    data_id,
    user_id,
    ν=0.0;
    stop=Inf
)
    # deboolbug = false
    # deboolbug2 = false
    j = job(backend, container, duration, frontend)
    if ν == 0.0
        # @warn "ν is 0.0, job will be added only once"
        t = time() - agent.start
        action = add_job!(agent.exe, t, j, user_id, data_id)
        put!(agent.containers.loads, action)
        put!(agent.containers.has_queue, true)
    else
        start = time()
        @spawn while time() - start < stop
            # Check if the stop signal is received
            if isready(agent.containers.stop) ? fetch(agent.containers.stop) : false
                break
            end

            # if !deboolbug
            #     @warn "ν is $(ν), job will be added every $(ν) seconds"
            #     deboolbug = true
            # end
            t = time() - agent.start
            action = add_job!(agent.exe, t, j, user_id, data_id)
            # if !deboolbug2
            #     @warn "ν is $(ν), job will be added every $(ν) seconds" action
            #     deboolbug2 = true
            # end
            put!(agent.containers.loads, action)
            put!(agent.containers.has_queue, true)
            sleep(ν)
        end
    end
    return agent
end
