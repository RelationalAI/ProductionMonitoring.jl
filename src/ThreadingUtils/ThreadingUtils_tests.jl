# TODO(low priority): Rewrite this test based on mocked timer and mocked wall time, to deflake it.
# This test is meant to test that the periodic task is behaving as expected: running the
# right number of times in a given window. However, writing wall-time tests are not safe
# for CI, given that CI machines are very variable, julia may do GC at any time, etc etc.
# So this test is disabled. It should be rewritten to not depend on wall time at all.
#@testitem "spawn_periodic_task timing" begin
#    using ProductionMonitoring.ThreadingUtils
#    using Base.Threads: Atomic, atomic_add!
#    using Dates
#    const ERROR_RATIO_ALLOWED = .2 # Allow up to plus minus 20% error from expected value.
#    function value_approximately(val, expected)
#        local hi_threshold = expected * (1 + ERROR_RATIO_ALLOWED)
#        local lo_threshold = expected * (1 - ERROR_RATIO_ALLOWED)
#        @test hi_threshold >= val >= lo_threshold
#    end
#
#    accumulator = Atomic{Int64}(0)
#    t = ThreadingUtils.@spawn_sticky_periodic_task "Adder" Dates.Millisecond(9) atomic_add!(accumulator, 1)
#    sleep(0.1)
#    @test istaskstarted(t)
#    @test istaskstarted(t.task)
#    @test !istaskdone(t)
#    @test !istaskdone(t.task)
#
#    base_value = accumulator[]
#
#    sleep(0.5)
#    value_approximately(accumulator[] - base_value, 50)
#
#    sleep(0.25)
#    value_approximately(accumulator[] - base_value, 75)
#
#    ThreadingUtils.stop_periodic_task!(t)
#    @test istaskdone(t)
#    @test !istaskfailed(t)
#    @test istaskdone(t.task)
#    @test !istaskfailed(t.task)
#
#    curr_value = accumulator[]
#    sleep(0.15)
#    @test accumulator[] == curr_value
#end

@testitem "spawn_sticky_periodic_task on correct threadpool" begin
    using ProductionMonitoring.ThreadingUtils
    using Dates
    @static if Threads.nthreads(:interactive) > 0
        tlock = ReentrantLock()
        scheduled_at = Dict{Int,Symbol}()
        tasks = Dict{Int,ThreadingUtils.PeriodicTask}()
        task_executed = Dict{Int,Int}()
        Threads.@threads :static for i in 1:Threads.nthreads()
            @lock tlock begin
                t = ThreadingUtils.@spawn_sticky_periodic_task "T-$i" Dates.Millisecond(100) begin
                    scheduled_at[i] = Threads.threadpool()
                    task_executed[i] = 1
                end
                tasks[i] = t
            end
        end
        # wait for all sticky tasks to get executed and inserted into tasks dict
        while true
            ready = @lock tlock sum(values(task_executed)) == length(tasks) == Threads.nthreads()
            ready && break
            sleep(0.05)
        end
        for t in values(tasks)
            ThreadingUtils.stop_periodic_task!(t)
        end
        for i in 1:Threads.nthreads()
            @test scheduled_at[i] == :interactive
        end
    else
        @test true
    end
end

@testitem "periodic task with exceptions" begin
    using ProductionMonitoring.ThreadingUtils
    using Base.Threads: Atomic, atomic_add!
    using Dates
    function increment_up_to_five(v::Atomic{Int64})
        v[] >= 5 && throw(OverflowError("My spoon is too big!"))
        atomic_add!(v, 1)
    end

    acc = Atomic{Int64}(0)
    t = ThreadingUtils.@spawn_sticky_periodic_task "Exceptional" Dates.Millisecond(10) increment_up_to_five(acc)
    sleep(0.1)
    @test istaskstarted(t)
    @test istaskstarted(t.task)
    @test !istaskdone(t)
    @test !istaskdone(t.task)

    sleep(0.1)
    @test acc[] == 5
    sleep(0.1)
    @test acc[] == 5

    ThreadingUtils.stop_periodic_task!(t)
    # TODO(janrous): once we have instrumentation, make sure that
    # number_of_iterations = number_of_errors + 5
end

@testitem "spawn named periodic task" begin
    using ProductionMonitoring.ThreadingUtils
    using Dates
    t = ThreadingUtils.@spawn_periodic_task Dates.Millisecond(10) sleep(0.01) "HasName"
    @test t.name == "HasName"
    ThreadingUtils.stop_periodic_task!(t)
end

@testitem "spawn named sticky periodic task" begin
    using ProductionMonitoring.ThreadingUtils
    using Dates
    t = ThreadingUtils.@spawn_sticky_periodic_task "Named" Dates.Millisecond(10) sleep(0.01)
    @test t.name == "Named"
    ThreadingUtils.stop_periodic_task!(t)
end

@testitem "finalizer on PeriodicTask-captured variable" begin
    using ProductionMonitoring.ThreadingUtils
    using Dates
    mutable struct ___MutableFoo
        x::Ref{Int}
    end

    ref = Ref(1)
    x = ___MutableFoo(ref)
    finalizer(x) do x
        ref[] = 3
    end
    t = ThreadingUtils.@spawn_periodic_task Dates.Millisecond(1) begin
        x.x[] = 2
    end
    sleep(0.1)
    @test ref[] == 2
    ThreadingUtils.stop_periodic_task!(t)
    t = x = nothing
    GC.enable(true)
    GC.gc()
    @test ref[] == 3
end

@testitem "Task terminates quickly" begin
    using ProductionMonitoring.ThreadingUtils
    using Dates
    t = ThreadingUtils.@spawn_periodic_task Dates.Second(2) println("me slow!") "Sloth"
    sleep(0.1)
    @test istaskstarted(t)
    before = Dates.now()
    ThreadingUtils.stop_periodic_task!(t)
    duration = Dates.now() - before
    println("stop_periodic_task duration is $duration")
    @test duration < Dates.Millisecond(500)
end

@testitem "overacquired semaphore" begin
    using ProductionMonitoring.ThreadingUtils
    using ProductionMonitoring.ThreadingUtils: @acquire
    s = Base.Semaphore(5)

    Base.acquire(s)
    @test s.curr_cnt == 1
    Base.release(s)
    @test s.curr_cnt == 0
    Base.acquire(s, 3)
    @test s.curr_cnt == 3
    Base.release(s, 3)
    @test s.curr_cnt == 0
    Base.acquire(s, 5)
    @test s.curr_cnt == 5
    @async Base.acquire(s)
    @test s.curr_cnt == 5
    Base.release(s)
    yield()
    @test s.curr_cnt == 5
    Base.release(s, 5)
    @test s.curr_cnt == 0

    Base.acquire(s, 5)
    @test s.curr_cnt == 5
    @async Base.acquire(s, 5)
    @async Base.acquire(s, 5)
    @test s.curr_cnt == 5
    Base.release(s)
    yield()
    @test s.curr_cnt == 9
    Base.release(s)
    yield()
    @test s.curr_cnt == 8
    Base.release(s, 3)
    yield()
    @test s.curr_cnt == 5
    Base.release(s)
    yield()
    @test s.curr_cnt == 9
    Base.release(s, 5)
    @test s.curr_cnt == 4

    @acquire s nothing
    @test s.curr_cnt == 4
    Base.release(s)
    @acquire s 10 nothing
    @test s.curr_cnt == 3
    Base.acquire(s, 2)
    @test s.curr_cnt == 5

    Base.release(s, 5)
    yield()
    @test s.curr_cnt == 0
    @acquire s begin @test s.curr_cnt == 1 end
    @test s.curr_cnt == 0
    @acquire s 5 begin @test s.curr_cnt == 5 end
    @test s.curr_cnt == 0
end

@testitem "spawn_with_error_log metrics" begin
    using ProductionMonitoring.ThreadingUtils
    using ProductionMonitoring.Metrics
    using ProductionMonitoring.ThreadingUtils: @spawn_with_error_log
    Metrics.zero_all_metrics()
    @test_broken Metrics.value_of("threading_spawn_in_flight") == 0
    @test_broken Metrics.value_of("threading_spawn_calls_total") == 0

    synchronizer = Channel()
    tasks = Channel(Inf)

    @test_broken Metrics.value_of("threading_spawn_in_flight") == 0
    for i in 1:128
        # Block on the channel
        t = @spawn_with_error_log begin take!(synchronizer) end
        put!(tasks, t)
        @test_broken Metrics.value_of("threading_spawn_in_flight") == i
        @test_broken Metrics.value_of("threading_spawn_calls_total") == i
    end
    close(tasks)
    @test_broken Metrics.value_of("threading_spawn_in_flight") == 128
    @test_broken Metrics.value_of("threading_spawn_calls_total") == 128

    # Unblock the tasks
    for i in 1:128
        put!(synchronizer, nothing)
    end
    close(synchronizer)
    for t in tasks
        wait(t)
    end
    @test_broken Metrics.value_of("threading_spawn_in_flight") == 0
    @test_broken Metrics.value_of("threading_spawn_calls_total") == 128
end
