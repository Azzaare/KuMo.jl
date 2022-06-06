using KuMo
using Test

using Ipopt

@testset "KuMo.jl" begin
    @info "Starting simulation: 4 nodes, free links"
    println()
    times, snaps = simulate(SCENARII[:four_nodes], ShortestPath(); speed=100)
    @info "Running times" times

    @info "Starting simulation: 4 nodes, square links"
    println()
    times, snaps = simulate(SCENARII[:square], ShortestPath(); speed=100)
    @info "Running times" times
end
