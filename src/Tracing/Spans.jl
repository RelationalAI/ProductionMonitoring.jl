## Span Datastructures and Functionality
## Implementation

import DataStructures: OrderedDict
using Base: @lock, AbstractLock
using ProductionMonitoring.TransactionLogging
using ProductionMonitoring.DebugLevels

const Option{T} = Union{Nothing,T}

# SpanContext Struct
mutable struct SpanContext
    # traceId
    traceid::UInt64
    trace_starttime::Int64
    # parent spanId
    spanid::UInt64
    # Context bag of (k,v) pairs
    bag::Dict{Any,Any}
end

# Child span context
SpanContext(new_span_id::UInt64, parent_sc::SpanContext) =
    SpanContext(parent_sc.traceid, parent_sc.trace_starttime, new_span_id, copy(parent_sc.bag))

# New Root SC
SpanContext(traceid::UInt64) = SpanContext(traceid, in_now(), 0, Dict())
# Empty SC
SpanContext() = SpanContext(0, in_now(), 0, Dict())


# Span Struct
mutable struct Span
    # Span identifier that is only unique within a trace (typically a random
    # number because identifiers can be generated across a distributed system)
    id::UInt64

    # taskoid , i.e., objectid(current_task)
    taskoid::UInt64

    # threadid
    threadid::UInt64

    # name of span
    name::String

    # Spans know their parent (0 for the root), but parents cannot know their
    # children (spans can be across process etc)
    parent_span::Option{Span}

    # Associated SpanContext
    span_context::SpanContext

    # Start & End timestamps
    start_time::UInt64
    end_time::UInt64

    # Errors and StackTraces
    error::Option{Any}

    # Span Tags <K,V> pairs.
    attributes::Option{Dict{String,Any}}

    # For any sub-spans the elapsed time is accumulated in this dict, indexed by their
    # names, see also the `@sub_span` macro below. Guarded by `span_lock`.
    sub_span_times::Option{OrderedDict{String,Int64}}

    # Span (sub)durations breakdown
    # Only used for the PrintBackend
    aggs::Option{OrderedDict{String,Float64}}

    # Span metrics <K,V> pairs
    # Only used for the PrintBackend
    metrics::Option{Dict{String,Float64}}

    ## Used to lock the KVs in the Span stucture
    ## TODO: We can further improve this by pushing finer grained locks
    ## within each of those dictionaries
    span_lock::AbstractLock

    # Nesting level
    nesting::Int
end

## Efficient inlined now() function
@inline function in_now()::Int64
    tv = Libc.TimeVal()
    return (tv.sec * 1000000 + tv.usec) * 1000
end

Span(id, name, parent, span_context, start_time, nesting) = Span(
    id,
    objectid(current_task()),
    Threads.threadid(),
    name,
    parent,
    span_context,
    start_time,
    0,
    nothing,
    nothing,
    nothing,
    nothing,
    nothing,
    ReentrantLock(),
    nesting,
)

function Span(name::String, parent_span::Span)
    local id = 0
    while id == 0
        id = rand(UInt64)
    end
    return Span(
        id,
        name,
        parent_span,
        SpanContext(id, parent_span.span_context),
        in_now(),
        parent_span.nesting + 1,
    )
end

## The AttributeValue can be a string, or a nullary function
## that computes a string.
const AttributeValue = Union{AbstractString,Function}


function _get_span_attributes(span::Span)
    if isnothing(span.attributes)
        span.attributes = Dict{String,Any}()
    end
    return span.attributes
end

function _get_span_aggs(span::Span)
    if isnothing(span.aggs)
        span.aggs = OrderedDict{String,Float64}()
    end
    return span.aggs
end

function _get_and_clear_sub_span_times!(span::Span)::Vector{Pair{String,Int64}}
    @lock span.span_lock begin
        isnothing(span.sub_span_times) && return Pair{String,Int64}[]
        ts = collect(span.sub_span_times)
        empty!(span.sub_span_times)
        return ts
    end
end

@inline function _inc_sub_span_time!(span::Span, name::String, val::Int64)::Nothing
    @lock span.span_lock begin
        if isnothing(span.sub_span_times)
            span.sub_span_times = OrderedDict{String,Int64}()
        end
        prev = get(span.sub_span_times, name, 0)
        span.sub_span_times[name] = prev + val
        return nothing
    end
end

function _get_span_metrics(span::Span)
    if isnothing(span.metrics)
        span.metrics = Dict{String,Float64}()
    end
    return span.metrics
end


"""
    span_attribute!(span::Span, key::String, value::AttributeValue)

Add a `value` under the key `key` to the attributes field of a Span object.
In general the `value` is a string, or a nullary function, that computes a string.
"""
function span_attribute!(span::Span, key::String, value::AttributeValue)
    @lock span.span_lock begin
        atts = _get_span_attributes(span)
        atts[key] = value
    end
end

"""
    span_bag!(span::Span, k, v)

Add a `v` under the key `k` in the bag field of a Span's SpanContext object.
"""
function span_bag!(span::Span, k, v)
    @lock span.span_lock begin
        span.span_context.bag[k] = v
    end
end

"""
    span_merge_aggs!(span::Span, k, v)

merge a `v` under the key `k` in the agg field of a Span Object.
This is only used for the print-backend.
"""
function span_merge_aggs!(span::Span, k, v)
    @lock span.span_lock begin
        ags = _get_span_aggs(span)
        _span_merge!(ags, k, v)
    end
end

"""
    span_merge_metrics!(span::Span, k, v)

merge a `v` under the key `k` in the metrics field of a Span Object.
This is only used for the print-backend.
"""
function span_merge_metrics!(span::Span, k, v)
    @lock span.span_lock begin
        mts = _get_span_metrics(span)
        _span_merge!(mts, k, v)
    end
end

## Helper function for merge
function _span_merge!(curr_aggs::AbstractDict, k, v)
    if haskey(curr_aggs, k)
        curr_aggs[k] += v
    else
        curr_aggs[k] = v
    end
end

# Returns `true` if `span` is the root-span.
@inline _is_root(span::Span) = span.id == 0
function _is_root(span::Any)
    @warn_with_current_backtrace "Encountered unexpected span type: $(typeof(span))"
    return false
end

"""
Turn something stored in the range of the attributes Dict of a Span object into a String.
It might be a Function, which computes a string on demand.
"""
attribute_to_string(x::String)::String = x
attribute_to_string(x::Function)::String = x()
attribute_to_string(x::Any)::String = string(x)

"""
    root_span()

Creates a dummy root span instance. The root span is the topmost span. It is the entry point
to nested traces. Within a single root span context, all attributes of nested spans are
collected.
"""
function root_span()::Span
    # unfortunately we don't have combo macros for @warn_with_verbosity and
    # @warn_with_current_backtrace, so the backtrace part is duplicated here.
    # backtrace disabled due to regression
    DebugLevels.@error_with_verbosity 1 "getting root span with no existing span context" #\n$(TransactionLogging.current_stacktrace_to_string(Base.backtrace()))"
    current_logger = Logging.current_logger()
    trace_id = ""
    if TransactionLogging.has_trace_id(current_logger)
        trace_id = parse(UInt64, TransactionLogging.get_trace_id(current_logger))
        DebugLevels.@warn_with_verbosity 1 "found trace id on current logger $trace_id"
    else
        trace_id = gen_trace_id()
        TransactionLogging.set_trace_id!(current_logger, "$trace_id")
        DebugLevels.@warn_with_verbosity 1 "no trace id found"
    end
    # The root span is the parent of top-level spans, at `nesting` level -1. This avoids
    # some special cases below.
    Span(0, "root", nothing, SpanContext(trace_id), 0, -1)
end

# Explicit Root span with a predefined SpanContext
function root_span(root_sc::SpanContext)
    Span(0, "root", nothing, root_sc, 0, -1)
end

export attribute_to_string, span_attribute!, root_span
export span_merge_metrics!, span_merge_aggs!
