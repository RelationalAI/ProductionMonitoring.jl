module ThreadingUtils

import DataStructures
import Dates
import ProductionMonitoring.Metrics
using Base: Semaphore, acquire, release, wait
using Base.Threads: Atomic, @spawn, Condition
using Dates: Period
using ProductionMonitoring.DebugLevels: @warn_with_verbosity
using ProductionMonitoring.Metrics: AbstractMetricCollection, Gauge, Counter, inc!, dec!
using ScopedValues
using ProductionMonitoring.TransactionLogging
using ProductionMonitoring.TransactionLogging: @error_with_current_exceptions, @warn_with_current_exceptions

include("exception.jl")
include("Future.jl")
include("SynchronizedCache.jl")
include("WeakRefCache.jl")
include("ParallelDict.jl")
include("micrometrics.jl")
include("semaphore.jl")

# log a warning if a periodic task takes longer than this (in seconds)
const MAX_PERIODIC_TASK_DURATION = 10

Base.@kwdef struct ThreadingMetrics <: AbstractMetricCollection
    threading_spawn_calls_total::Counter = Counter()
    threading_spawn_in_flight::Gauge = Gauge()
    failures_to_log_errors::Counter = Counter()
end

const THREADING_UTILS_METRICS = ThreadingMetrics()

function __init__()
    global metric_manager
    if isa(metric_manager[], Nothing)
        metric_manager[] = MicrometricManager()
    end

    Metrics.publish_metrics_from(THREADING_UTILS_METRICS)
end

"""
    @spawn_with_error_log expr
    @spawn_with_error_log "..error msg.." expr

Exactly like `@spawn`, except that it wraps `expr` in a try/catch block that will print any
exceptions that are thrown from the `expr` to stderr, via `@error`. You can
optionally provide an error message that will be printed before the exception is displayed.

This is useful if you need to spawn a "background task" whose result will never be
waited-on nor fetched-from.
"""
macro spawn_with_error_log(expr)
    spawn_with_error_log_expr(expr)
end
macro spawn_with_error_log(message, expr)
    spawn_with_error_log_expr(expr, message)
end
function spawn_with_error_log_expr(expr, message = "@spawn_with_error_log failed:")
    e = gensym("err")
    return esc(
        quote
            $ThreadingUtils.inc!($ThreadingUtils.THREADING_UTILS_METRICS.threading_spawn_calls_total)
            $ThreadingUtils.inc!($ThreadingUtils.THREADING_UTILS_METRICS.threading_spawn_in_flight)
            $Base.Threads.@spawn try
                $(expr)
            catch $e
                $TransactionLogging.@error_with_current_exceptions $(message)
                rethrow()
            finally
                $ThreadingUtils.dec!($ThreadingUtils.THREADING_UTILS_METRICS.threading_spawn_in_flight)
            end
        end
    )
end

"""
    PeriodicTask

This structure is a wrapper around background periodic Task and can be used to inspect the
state of the task itself and to safely terminate the background periodic task by signalling
via `should_terminate`.
"""
struct PeriodicTask
    # Name of the periodic task. Attached to error logs for debuggability.
    name::String

    # Specifies how often the underlying periodic task should be run.
    period::Period

    # The Timer used to run the task periodically.
    timer::Timer

    # When set to true, the underlying periodic task will terminate before next
    # iteration.
    should_terminate::Atomic{Bool}

    # The underlying periodic task itself.
    task::Task
end

"""
    @spawn_periodic_task period expr [name] [ending_expr]

Run `expr` once every `period` and returns `PeriodicTask` that will carry out this logic. The task
can be terminated by calling `stop_periodic_task!`. Optional `name` can be specified and
this will be attached to error logs and (eventually) metrics for easier debuggability.

`period` must be a `Dates.Period`.

`ending_expr` is run when the task ends. This could be useful to flush some pending data.

# First example
```julia
import Dates

disk_stuff = DiskStuff()
my_task = @spawn_periodic_task Dates.Seconds(30) dump_some_stuff_to_disk(disk_stuff) "DiskDumper"
# ... do some stuff ...
stop_periodic_task!(my_task)

istaskfailed(my_task) && throw(SystemError("Periodic task has failed!!"))

# Second example

The ending expression can be used as follows:
```
using ThreadingUtils: @spawn_periodic_task, stop_periodic_task!
using Dates

my_task = @spawn_periodic_task Dates.Second(5) println("hello") "my task" println("bye bye!")
# wait a bit
stop_periodic_task!(my_task)
```
"""
macro spawn_periodic_task(period, expr, name="Unnamed", ending_expr=nothing)
    # TODO(janrous): add number of iteratons, number of failures and last successful
    # iteration timestamp once metrics with labels are available.
    return quote
        n = $(esc(name))
        p = $(esc(period))
        timer = Timer(p; interval = p)
        should_terminate = Atomic{Bool}(false)
        # TODO(janrous): we can improve the timing precision by calculating how
        # much time has elapsed since last_execution when we are about to enter
        # sleep and subtract that from period.
        task = @spawn begin
            @info "Scheduled periodic task $(n)"
            while !should_terminate[]
                try
                    wait(timer)
                    local t0 = time_ns()
                    $(esc(expr))
                    local duration = (time_ns() - t0) / 1e9
                    if duration > MAX_PERIODIC_TASK_DURATION
                        @warn_with_verbosity(1, "$(n): took too long", duration, MAX_PERIODIC_TASK_DURATION)
                    end
                catch err
                    # close(timer) will notify and throw an `EOFError` to the
                    # waiting task.
                    if !isa(err, EOFError)
                        try
                            @error_with_current_exceptions "$(n): periodic task failed"
                        catch inner_err
                            # We've seen logging fail in tests due to a race condition between
                            # Suppressors.jl and Base.ConsoleLogger.
                            # See https://github.com/JuliaLang/julia/issues/47759
                            # Catch this case so the periodic task can keep going.
                            $ThreadingUtils.inc!(
                                $ThreadingUtils.THREADING_UTILS_METRICS.failures_to_log_errors,
                            )
                        end
                    else
                        # isa(err, EOFError) is true, so we execute the expression once more
                        # before shutting down.
                        $(esc(ending_expr))
                    end
                end
            end
        end
        # TODO: if name is not given, use module:lineno of the caller
        _pt = PeriodicTask(n, p, timer, should_terminate, task)
        wkr = WeakRef(_pt)
        atexit() do
            if wkr.value !== nothing
                stop_periodic_task!(wkr.value)
            end
        end
        _pt
    end
end

macro spawn_sticky_periodic_task(name, period, expr, ending_expr=nothing)
    return quote
        n = $(esc(name))
        p = $(esc(period))
        timer = Timer(p; interval = p)
        should_terminate = Atomic{Bool}(false)
        # With `:interactive`, this task will run on a thread from the interactive
        # thread pool.
        task = @spawn :interactive begin
            @info "Scheduled sticky periodic task $(n)"
            while !should_terminate[]
                try
                    wait(timer)
                    local t0 = time_ns()
                    $(esc(expr))
                    local duration = (time_ns() - t0) / 1e9
                    if duration > MAX_PERIODIC_TASK_DURATION
                        @warn_with_verbosity(1, "$(n): took too long", duration, MAX_PERIODIC_TASK_DURATION)
                    end
                catch err
                    if !isa(err, EOFError)
                        try
                            @error_with_current_exceptions "$(n): sticky periodic task failed"
                        catch inner_err
                            # We've seen logging fail in tests due to a race condition between
                            # Suppressors.jl and Base.ConsoleLogger.
                            # See https://github.com/JuliaLang/julia/issues/47759
                            # Catch this case so the periodic task can keep going.
                            $ThreadingUtils.inc!(
                                $ThreadingUtils.THREADING_UTILS_METRICS.failures_to_log_errors,
                            )
                        end
                    else
                        # isa(err, EOFError) is true, so we execute the expression once more
                        # before shutting down.
                        $(esc(ending_expr))
                    end
                end
            end
        end
        _pt = PeriodicTask(n, p, timer, should_terminate, task)
        wkr = WeakRef(_pt)
        atexit() do
            if wkr.value !== nothing
                stop_periodic_task!(wkr.value)
            end
        end
        _pt
    end
end

"""
    stop_periodic_task!(task::PeriodicTask)

Triggers termination of the periodic task.
"""
function stop_periodic_task!(pt::PeriodicTask)
    pt.should_terminate[] = true
    close(pt.timer)
    wait(pt.task)
    return pt
end

# Reflection methods for the inner ::Task struct.
Base.istaskdone(t::PeriodicTask) = istaskdone(t.task)
Base.istaskfailed(t::PeriodicTask) = istaskfailed(t.task)
Base.istaskstarted(t::PeriodicTask) = istaskstarted(t.task)

"""
    acquire(s::Semaphore, n::Int)

Wait for at least 1 permit of the `sem_size` permits to be available, then acquires *n*
permits.

We allow to acquire the semaphore even if that exceeds its assigned size. In that case, its
internal counter will exceed `sem_size`. For example, this pattern allows us to deal with
very large pages that otherwise would not fit into a limiting semaphore, while still
limiting the number of these very large acquires to 1.
"""
function Base.acquire(s::Semaphore, n::Int)
    lock(s.cond_wait)
    try
        while s.curr_cnt >= s.sem_size
            wait(s.cond_wait)
        end

        s.curr_cnt += n
        notify(s.cond_wait; all=false)
    finally
        unlock(s.cond_wait)
    end
    return nothing
end

"""
    release(s::Semaphore, n::Int)

Return n permits to the pool,
possibly allowing another task to acquire them
and resume execution.
"""
function Base.release(s::Semaphore, n::Int)
    lock(s.cond_wait)
    try
        s.curr_cnt >= n || error("release count must match acquire count")
        s.curr_cnt -= n
        notify(s.cond_wait; all=false)
    finally
        unlock(s.cond_wait)
    end
    return nothing
end


# Similar to @lock macro, acquires a semaphore, runs the expression, and finally releases
# the semaphore. If n and expr are provided, this acquires the semaphore `n` times and runs
# expr on it (see `acquire` below). If expr==nothing, this acquires the semaphore 1 time and
# runs the expression `n` on it. This allows you to use the macro either as
# `@acquire semaphore some_fn(...)` or `@acquire semaphore N some_fn(...)` as needed.
macro acquire(s, n, expr)
    quote
        # Eval these once in case they have side-effects
        s = $(esc(s))
        n = $(esc(n))

        Base.acquire(s, n)
        try
            $(esc(expr))
        finally
            Base.release(s, n)
        end
    end
end
macro acquire(s, expr)
    quote
        # Eval s once in case it has side-effects
        s = $(esc(s))

        Base.acquire(s)
        try
            $(esc(expr))
        finally
            Base.release(s)
        end
    end
end

"""
    resize_semaphore!(s::Semaphore, sem_size::Int)::Nothing

Resizes a semaphore. This is only meant to be used during a module's __init__, before the
semaphore is in use, to make sure we pick a size based on the number of runtime threads.
"""
function resize_semaphore!(s::Semaphore, sem_size::Int)
    @lock s.cond_wait begin
        @assert s.curr_cnt == 0 "resize! called on a semaphore that is already in use"
        s.sem_size = sem_size
    end
    return nothing
end

_assert_singly_locked(lock) = nothing
function _assert_singly_locked(lock::ReentrantLock)
    @assert lock.reentrancy_cnt == 1
    nothing
end

"""
    @scoped_unlock l expr

The "opposite" of `@lock`. Unlocks `l`, executes `expr`, then relocks `l`.
"""
macro scoped_unlock(l, expr)
    quote
        temp = $(esc(l))
        _assert_singly_locked(temp)
        unlock(temp)
        try
            $(esc(expr))
        finally
            lock(temp)
        end
    end
end

# copy/pasted from Base, but with LIFO ordering
# Replace with https://github.com/JuliaLang/julia/pull/47277 once it lands
function waitfirst(c::Base.GenericCondition)
    ct = current_task()
    # function _wait2(c::GenericCondition, waiter::Task)
    Base.assert_havelock(c)
    # here's where we pushfirst! instead of push! for LIFO instead of FIFO ordering on
    # wakeup
    pushfirst!(c.waitq, ct)
    # since _wait2 is similar to schedule, we should observe the sticky bit now
    if ct.sticky && Threads.threadid(ct) == 0
        # Issue #41324
        # t.sticky && tid == 0 is a task that needs to be co-scheduled with
        # the parent task. If the parent (current_task) is not sticky we must
        # set it to be sticky.
        # XXX: Ideally we would be able to unset this
        ct.sticky = true
        tid = Threads.threadid()
        ccall(:jl_set_task_tid, Cint, (Any, Cint), ct, tid-1)
    end
    token = Base.unlockall(c.lock)
    try
        return wait()
    catch
        ct.queue === nothing || Base.list_deletefirst!(ct.queue, ct)
        rethrow()
    finally
        Base.relockall(c.lock, token)
    end
end

include("task_group.jl")
include("retry.jl")


function wait_then_run_as_future(func, futures::Vector{<:Future})
    return Future{Any}(;spawn=true) do
        wait_until_done(futures)
        return func()
    end
end

# be careful!! this can cause deadlocks if tasks that block on each other are spawned within
# the same task group
function wait_then_run_as_future(func, futures::Vector{<:Future}, task_group)
    return submit_task!(task_group) do
        wait_until_done(futures)
        return func()
    end
end

export THREADING_UTILS_METRICS, waitfirst

end # module
