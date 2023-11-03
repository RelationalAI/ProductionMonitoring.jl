# A replacement for Base.Semaphore which supports being closed with an error, using the cancel() method.
# When the semaphore is closed, any waiters will throw the provided exception, as will any further calls
# to acquire().
mutable struct SemaphoreWithCancel
    cond::Condition
    capacity::Int
    count::Int
    error::Union{Nothing,Exception}

    function SemaphoreWithCancel(capacity::Int)
        new(Condition(), capacity, 0, nothing)
    end
end

function Base.resize!(sem::SemaphoreWithCancel, new_capacity::Int)
    @lock sem.cond begin
        sem.capacity = new_capacity
        notify(sem.cond; all=true)
    end
end

function Base.acquire(sem::SemaphoreWithCancel)
    @lock sem.cond begin
        _throw_if_errored(sem)
        while sem.count >= sem.capacity
            wait(sem.cond)
            _throw_if_errored(sem)
        end
        sem.count += 1
    end
    return nothing
end

function Base.release(sem::SemaphoreWithCancel)
    # We don't do _throw_if_errored() here, because we don't want to confuse the
    # backtrace situation if there is a release() inside a finally() block.
    @lock sem.cond begin
        notify(sem.cond; all=false)
        sem.count = max(0, sem.count-1)
    end
end

function cancel(sem::SemaphoreWithCancel, e::Exception)
    @lock sem.cond begin
        if isa(sem.error, Nothing)
            sem.error = e
            notify(sem.cond; all=true)
        end
    end
end

function _throw_if_errored(sem::SemaphoreWithCancel)
    if sem.error !== nothing
        throw(sem.error)
    end
    return nothing
end
