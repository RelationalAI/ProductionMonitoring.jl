export TaskGroup, submit_task!, wait_group, TaskTreeJoin

struct TaskQueueEntry
    # We use (user-provided-priority, submit-timestamp) as the priority, to encourage
    # LIFO behaviour when many tasks are submitted with identical priorities.
    priority::Tuple{Int,Float64}
    f::Function
    future::Future
    scope::ScopedValues.Scope
end

Base.isless(a::TaskQueueEntry, b::TaskQueueEntry) = a.priority < b.priority

const DEFAULT_NUM_WORKERS = max(256, 4*Threads.nthreads())
# A workaround for ScopeStorage not being defined in the package in Julia 1.11
# https://github.com/vchuravy/ScopedValues.jl/issues/14
const _EMPTY_SCOPE = ScopedValues.Scope(
    isdefined(ScopedValues, :ScopeStorage) ?
        ScopedValues.ScopeStorage() :
        Base.ScopedValues.ScopeStorage()
)

# In older Julia versions, the ScopedValues.jl package uses tasks' `logstate` field to
# propagate the scope and exposes a convenient function `enter_scope` as an implementation
# detail. On Julia 1.11+ it directly overrides the tasks' `scope` field without needing the
# `enter_scope` function, so we need to define an equivalent here.
if !isdefined(ScopedValues, :enter_scope)
    function _scoped_values_enter_scope(f, scope::ScopedValues.Scope)
        ct = Base.current_task()
        current_scope = ct.scope::Union{Nothing, ScopedValues.Scope}
        ct.scope = scope
        try
            return f()
        finally
            ct.scope = current_scope
        end
    end
else
    using ScopedValues: enter_scope as _scoped_values_enter_scope
end

# Simple worker pool to avoid creating hundreds of thousands of Julia Task objects.
# TaskGroup allows up to max_workers simultaneous julia tasks, processing a priority
# queue of tasks specified as julia closures. If there are fewer than max_workers tasks
# when a new task is submitted via submit_task!(), a new task is created; if a task finishes
# a task and finds the task queue entry, it exits.
mutable struct TaskGroup
    name::String
    cond::Condition
    pq::Vector{TaskQueueEntry}
    # This can temporarily exceed `max_workers` due to the scoped_release mechanism that is
    # needed to prevent deadlocks when tasks depend on each other.
    num_active_workers::Int
    num_workers::Int
    max_workers::Int
    throttle::Semaphore
    suppress_warnings::Bool

    # NB if you specify max_queued_tasks, calls to submit_task!() may block until
    # the task queue is < max_queued_tasks. So you must never create tasks that depend
    # on the Future of a task they themselves will spawn, or deadlock may result.
    function TaskGroup(
        name::String
        ;max_workers=DEFAULT_NUM_WORKERS,
        max_queued_tasks=typemax(Int),
        suppress_warnings=false
    )
        new(
            name,
            Condition(),
            Vector{TaskQueueEntry}(),
            0,
            0,
            max_workers,
            Semaphore(max_queued_tasks),
            suppress_warnings,
        )
    end
end

function not_too_busy(tg::TaskGroup)
    @lock tg.cond begin
        # Each worker should have a few tasks in queue, but not too many
        return tg.num_workers + length(tg.pq) < 4*tg.max_workers
    end
end

function set_max_workers!(tg::TaskGroup, max_workers)
    @lock tg.cond begin
        @assert tg.num_active_workers == 0 "Can't modify max workers while active workers exist"
        tg.max_workers = max_workers
        return nothing
    end
end

function get_max_workers(tg::TaskGroup)
    @lock tg.cond begin
        return tg.max_workers
    end
end

# Smaller priority runs sooner.
function submit_task!(f::Function, tg::TaskGroup, future_type::Type{T} = Any; priority=1000) where T
    acquire(tg.throttle)
    fut = Future{T}()
    scope = @something(ScopedValues.current_scope(), _EMPTY_SCOPE)::ScopedValues.Scope
    @lock tg.cond begin
        DataStructures.heappush!(tg.pq, TaskQueueEntry((priority,time()),f,fut,scope))
        _maybe_spawn_worker(tg)
    end
    return fut
end

function _maybe_spawn_worker(tg::TaskGroup)
    @assert islocked(tg.cond)
    if tg.num_active_workers < tg.max_workers && !isempty(tg.pq)
        tg.num_active_workers += 1
        tg.num_workers += 1
        @spawn_with_error_log _worker_task(tg)
    end
    return nothing
end

function _worker_task(tg::TaskGroup)
    while true
        # Get next task
        task = @lock tg.cond begin
            @assert tg.num_active_workers <= tg.max_workers
            # Shutdown if there are no more tasks
            if isempty(tg.pq)
                tg.num_active_workers -= 1
                tg.num_workers -= 1
                notify(tg.cond; all=false)
                return nothing
            end
            DataStructures.heappop!(tg.pq)
        end

        # Allow another task to be submitted
        release(tg.throttle)

        # Do the thing
        try
            _scoped_values_enter_scope(task.scope) do
                task.future[] = task.f()
            end
        catch e
            setexception!(task.future, FastCapturedException(e, catch_backtrace()))
            if !tg.suppress_warnings
                @warn_with_current_exceptions "TaskGroup $(tg.name) task had exception"
            end
        end
    end
end

# Allow another worker for this task group to make progress, by relinquishing the token of
# the current worker. Will proactively spawn an additional worker if needed. The token can
# then be reacquired later using `scoped_reacquire`.
function _scoped_release(tg::TaskGroup)
    @lock tg.cond begin
        tg.num_active_workers -= 1
        notify(tg.cond; all=false)
        # Without this we may still deadlock, because while a worker could make progress,
        # one might not exist. It is not guaranteed that scoped release is always followed
        # by a task submission.
        _maybe_spawn_worker(tg)
    end
    return nothing
end

# Reacquire the worker token previously relinquished via `scoped_release`. Might block until
# worker tokens are available again.
function _scoped_reacquire(tg::TaskGroup)
    @lock tg.cond begin
        while tg.num_active_workers >= tg.max_workers
            wait(tg.cond)
        end
        tg.num_active_workers += 1
    end
    return nothing
end

"""
    @scoped_release task_group expr

Allows another worker to make progress for the current task group. Will spawn a worker if
needed. Must be called from a worker already running in the task group.
"""
macro scoped_release(task_group, expr)
    quote
        temp = $(esc(task_group))
        _scoped_release(temp)
        try
            $(esc(expr))
        finally
            _scoped_reacquire(temp)
        end
    end
end

# Intended for testing or shutdowns. Usage on hot path needs a
# faster implementation first.
function wait_group(tg::TaskGroup)::Nothing
    while true
        @lock tg.cond begin
            if tg.num_active_workers == 0
                return nothing
            end
            @scoped_unlock tg.cond sleep(0.1)
        end
    end
end

"""
    TaskTreeJoin

An utility to wait on a tree of tasks where the root is the first
submitted one. Similar to `@sync` macro but work for TaskGroup.
All descendants tasks must be submitted through submit_task!(f, tg, ttj).
"""
mutable struct TaskTreeJoin
    cond::Threads.Condition
    counter::Int

    function TaskTreeJoin()
        return new(Threads.Condition(), 0)
    end
end
function submit_task!(f::Function, tg, ttj)
    @lock ttj.cond ttj.counter += 1
    fut = submit_task!(tg) do
        try
            f()
        catch e
            @lock ttj.cond notify(ttj.cond, e; error=true)
            rethrow()
        finally
            @lock ttj.cond begin
                ttj.counter -= 1
                ttj.counter == 0 && notify(ttj.cond; all=true)
            end
        end
    end
    return fut
end
function Base.wait(ttj::TaskTreeJoin)
    @lock ttj.cond begin
        while ttj.counter > 0
            Threads.wait(ttj.cond)
        end
    end
end
