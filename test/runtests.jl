# This file is a part of Julia. License is MIT: http://julialang.org/license
using Base.Test
include("choosetests.jl")
tests, net_on = choosetests(ARGS)
tests = unique(tests)

const max_worker_rss = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
    parse(Int, ENV["JULIA_TEST_MAXRSS_MB"]) * 2^20
else
    typemax(Csize_t)
end

const node1_tests = String[]
function move_to_node1(t)
    if t in tests
        splice!(tests, findfirst(tests, t))
        push!(node1_tests, t)
    end
end
# Base.compile only works from node 1, so compile test is handled specially
move_to_node1("compile")
# In a constrained memory environment, run the parallel test after all other tests
# since it starts a lot of workers and can easily exceed the maximum memory
max_worker_rss != typemax(Csize_t) && move_to_node1("parallel")

cd(dirname(@__FILE__)) do
    n = 1
    if net_on
        n = min(8, Sys.CPU_CORES, length(tests))
        n > 1 && addprocs(n; exeflags=`--check-bounds=yes --depwarn=error`)
        BLAS.set_num_threads(1)
    end

    @everywhere include("testdefs.jl")
    results=[]
    @sync begin
        for p in workers()
            @async begin
                while length(tests) > 0
                    test = shift!(tests)
                    local resp
                    try
                        resp = remotecall_fetch(t -> runtests(t), p, test)
                    catch e
                        resp = [e]
                    end
                    push!(results, (test, resp))

                    if (isa(resp[end], Integer) && (resp[end] > max_worker_rss)) || isa(resp, Exception)
                        if n > 1
                            rmprocs(p, waitfor=0.5)
                            p = addprocs(1; exeflags=`--check-bounds=yes --depwarn=error`)[1]
                            remotecall_fetch(()->include("testdefs.jl"), p)
                        else
                            # single process testing, bail if mem limit reached, or, on an exception.
                            isa(resp, Exception) ? rethrow(resp) : error("Halting tests. Memory limit reached : $resp > $max_worker_rss")
                        end
                    end
                end
            end
        end
    end
    # Free up memory =)
    n > 1 && rmprocs(workers(), waitfor=5.0)
    for t in node1_tests
        n > 1 && print("\tFrom worker 1:\t")
        local resp
        try
            resp = runtests(t)
        catch e
            resp = [e]
        end
        push!(results, (t, resp))
    end
    o_ts = Base.Test.DefaultTestSet("Overall")
    Base.Test.push_testset(o_ts)
    for res in results
        if isa(res[2][1], Exception)
             Base.showerror(STDERR,res[2][1])
             @show res[1]
             o_ts.anynonpass = true
        elseif isa(res[2][1], Base.Test.DefaultTestSet)
             Base.Test.push_testset(res[2][1])
             Base.Test.record(o_ts, res[2][1])
             Base.Test.pop_testset()
        elseif isa(res[2][1], Tuple{Int,Int})
             fake = Base.Test.DefaultTestSet(res[1])
             [Base.Test.record(fake, Base.Test.Pass(:test, nothing, nothing, nothing)) for i in 1:res[2][1][1]]
             [Base.Test.record(fake, Base.Test.Broken(:test, nothing)) for i in 1:res[2][1][2]]
             Base.Test.push_testset(fake)
             Base.Test.record(o_ts, fake)
             Base.Test.pop_testset()
        end
    end
    println()
    Base.Test.print_test_results(o_ts,1)
    for res in results
        if !isa(res[2][1], Exception)
            rss_str = @sprintf("%7.2f",res[2][6]/2^20)
            time_str = @sprintf("%7f",res[2][2])
            gc_str = @sprintf("%7f",res[2][5].total_time/10^9)
            percent_str = @sprintf("%7.2f",100*res[2][5].total_time/(10^9*res[2][2]))
            alloc_str = @sprintf("%7.2f",res[2][3]/2^20)
            println("Tests for $(res[1]):\n\ttook $time_str seconds, of which $gc_str were spent in gc ($percent_str % ),\n\tallocated $alloc_str MB,\n\twith rss $rss_str MB")
        else
            o_ts.anynonpass = true
        end
    end

    if !o_ts.anynonpass
        println("    \033[32;1mSUCCESS\033[0m")
    else
        println("    \033[31;1mFAILURE\033[0m")
        Base.Test.print_test_errors(o_ts)
        error()
    end
end
