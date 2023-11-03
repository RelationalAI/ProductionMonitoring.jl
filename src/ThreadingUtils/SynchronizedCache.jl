using Base: @lock

"""
    SynchronizedCache{K,V}()

A SynchronizedCache{K,V}() is a threadsafe collection that prevents duplicate work, by
synchronizing multiple accesses to the same key, so that only one thread computes new
entries. The first thread to request a cache entry computes it, and any additional threads
that request it block until the first thread finishes. Once the value is entered in the
cache, subsequent accesses will return the cached value without recomputing.
"""
Base.@kwdef struct SynchronizedCache{K,V}
    dict::Dict{K,Future{V}} = Dict{K,Future{V}}()
    lock::ReentrantLock = ReentrantLock()
end

"""
    cache_get!(fn, cache, k)

If cache[k] is already known, return its value. If it is currently being computed
by another thread, block until that computation completes then return the value.
If there is no cache entry for k, then set cache[k]=fn() and return the result.
"""
function cache_get!(fn, cache::SynchronizedCache{K,V}, k::K) where {K,V}
    have_lock=false
    try
        lock(cache.lock); have_lock=true

        # Has someone already computed / is currently computing this key?
        if haskey(cache.dict, k)
            future = cache.dict[k]
            unlock(cache.lock); have_lock=false
            return future[]
        else
            # We're the first thread to request this key
            future = Future{V}()
            cache.dict[k] = future
            unlock(cache.lock); have_lock=false

            try
                future[] = fn()
            catch e
                @lock cache.lock begin
                    delete!(cache.dict, k)
                end
                setexception!(future, FastCapturedException(e, catch_backtrace()))
                rethrow(e)
            end
        end
    finally
        have_lock && unlock(cache.lock)
    end
end

"""
    cache_get(cache, k)

If cache[k] exists, return its value; otherwise return `nothing`.
"""
function cache_get(cache::SynchronizedCache{K,V}, k::K) where {K,V}
    lock(cache.lock); have_lock=true
    try
        # Has someone already computed / is currently computing this key?
        if haskey(cache.dict, k)
            future = cache.dict[k]
            unlock(cache.lock); have_lock=false
            return future[]
        else
            return nothing
        end
    finally
        have_lock && unlock(cache.lock)
    end
end

"""
    cache_replace!(cache, k, v)

Set cache[k]=v, replacing any value already there.
"""
function cache_replace!(cache::SynchronizedCache{K,V}, k::K, v::V) where {K,V}
    # (Note that even though we're replacing the old future with a new future, there may be
    # other threads still waiting on the old future, so we cannot cancel or close it.)
    @lock cache.lock begin
        cache.dict[k] = Future{V}(v)
    end
end

"""
    cache_delete!(cache, k)

Delete the entry for k in the cache.
"""
function cache_delete!(cache::SynchronizedCache{K,V}, k::K) where {K,V}
    @lock cache.lock begin
        delete!(cache.dict, k)
    end
end


"""
    cache_empty!(cache)

Empty the entire cache
"""
function cache_empty!(cache::SynchronizedCache{K,V}) where {K,V}
    @lock cache.lock begin
        empty!(cache.dict)
    end
end

"""
    cache_snapshot(cache)

Get lock on cache and return copy of `cache.dict`.
"""
function cache_snapshot(cache::SynchronizedCache{K,V}) where {K,V}
    @lock cache.lock begin
        dict = copy(cache.dict)
        return dict
    end
end


export SynchronizedCache, cache_get!, cache_get, cache_replace!, cache_delete!, cache_empty!, cache_snapshot
