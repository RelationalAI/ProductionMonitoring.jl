## TracesCache: A Cache for all traces/spans
## created during a session

import DataStructures: OrderedDict
using Logging
using Base: @lock

struct TracesCache
    # Within a session we can collect spans here to make it easier to do some
    # process-specific investigation after the fact.
    # The datastructure is an OrderedDict of TraceID => vector of [Spans]
    # That means a vector of spans are lumped up per TraceID.

    # Note: A traceID is created implicitly by the upmost root span
    # that created these nested spans. A traceID can also come from
    # a distributed service or process.

    # TODO: to allow for future memory management,
    # e.g., window semantics
    traces::OrderedDict{UInt64,Vector{Span}}
end

# Traces Cache Lock
const TRACES_CACHE_LOCK = ReentrantLock()
# Single global TracesCache instance
const traces_cache = TracesCache(OrderedDict{UInt64,Span}())

"""
    clear_traces_cache()

Clears the Traces Cache.
"""
function clear_traces_cache()
    @lock TRACES_CACHE_LOCK begin
        empty!(traces_cache.traces)
    end
end

"""
    add_span_to_cache(s::Span)

Adds the span to the Traces Cache
"""
function add_span_to_cache(s::Span)
    @lock TRACES_CACHE_LOCK begin
        trc_id = s.span_context.traceid
        if haskey(traces_cache.traces, trc_id)
            push!(traces_cache.traces[trc_id], s)
        else
            traces_cache.traces[trc_id] = [s]
        end
    end
end

"""
    get_traces_from_cache()

Returns a snapshot of the Traces Cache
"""
function get_traces_from_cache()
    return @lock TRACES_CACHE_LOCK begin
        copy(traces_cache.traces)
    end
end

export get_traces_from_cache, clear_traces_cache, add_span_to_cache
