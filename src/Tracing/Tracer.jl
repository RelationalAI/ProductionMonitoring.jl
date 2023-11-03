## Tracing Functionality

import Printf: @sprintf
import JSON
import Random

using Base.Threads: @spawn
using Logging
using ProductionMonitoring.TransactionLogging
using ProductionMonitoring.DebugLevels

########################################
## Active Context & Active Span
########################################
struct ActiveCtx
    current_span::Span
end

const SPAN_CONTEXT = ScopedValue{ActiveCtx}()

function ActiveCtx()
    return ActiveCtx(root_span())
end

function TransactionLogging.span_id_is_present(::AbstractLogger)
    return !isnothing(ScopedValues.get(SPAN_CONTEXT))
end
function TransactionLogging.get_span_id()
    return SPAN_CONTEXT[].current_span.id
end

function with_ActiveCtx(f, trctx::ActiveCtx)
    with(SPAN_CONTEXT => trctx) do
        f()
    end
end

"""
    active_ctx()

Creates and returns a new `ActiveCtx` with the (optionally) given `id`. Also sets this
as the active_ctx for the current task.
"""
function active_ctx()
    # Optimize the common code-path to only lookup `:trace_ctx` once (i.e., avoid calling
    # `haskey(..)` and then `get(..)`). Also call `create_active_ctx()` only once per task.
    # ctx = get(task_local_storage(), :trace_ctx, nothing)
    maybe_ctx = @inline ScopedValues.get(SPAN_CONTEXT)
    return @something(maybe_ctx, ActiveCtx())::ActiveCtx
end

########################################
## Private functions for the Tracing
## Library
########################################

function _span_start(name::String, ctx::ActiveCtx = active_ctx())
    # only cache the current span if its a root span
    _is_root(ctx.current_span) && cache(ctx.current_span)
    s = Span(name, ctx.current_span)
    # cache the current span
    cache(s)
    span_start(tracing_config.backend, s, ctx)
    return s
end

function _span_end(span::Span, ctx::ActiveCtx = active_ctx())
    _is_root(span) && error("Cannot end the root-span")

    # Handle any sub-spans for which time may have been accumulated: start & end them now.
    sub_span_times = _get_and_clear_sub_span_times!(span)
    for (name, time) in sub_span_times
        sub_span = _span_start(name)
        with_ActiveCtx(ActiveCtx(sub_span)) do
            try
                sub_span.start_time = span.start_time
                sub_span.end_time = span.start_time + time
            finally
                _span_end(sub_span)
            end
        end
    end

    # attach the database name to the span
    lg = Logging.current_logger()
    if TransactionLogging.has_database_name(lg)
        db_name = TransactionLogging.get_database_name(lg)
        span_attribute!(span, "rai.database_name", db_name)
    end
    # attach the database id to the span
    if TransactionLogging.has_database_id(lg)
        db_id = TransactionLogging.get_database_id(lg)
        span_attribute!(span, "rai.database_id", db_id)
    end
    # attach the account name to the span
    if TransactionLogging.has_account_name(lg)
        ac_name = TransactionLogging.get_account_name(lg)
        span_attribute!(span, "rai.account_name", ac_name)
    end
    # attach the compute name to the span
    if TransactionLogging.has_engine_name(lg)
        cp_name = TransactionLogging.get_engine_name(lg)
        span_attribute!(span, "rai.engine_name", cp_name)
    end
    # attach commit to the span
    if TransactionLogging.has_commit(lg)
        commit = TransactionLogging.get_commit(lg)
        span_attribute!(span, "rai.commit", commit)
    end

    # Now close the current span.
    span.end_time == 0 && (span.end_time = in_now())
    span_end(tracing_config.backend, span, ctx)

    send(span)
end

function _span(name, ex::Expr; root_sc = nothing, tracing_level::Option{Int64} = nothing, caller_module::Option{String} = nothing)
    quote
        # (evaluates to the last value of the user provided `ex`)
        begin
            should_trace = (tracing_config.tracing_enabled &&
                        should_emit_tracing($(esc(tracing_level)), $(esc(caller_module))))
            local ctx, span, old_ctx
            # Set up tracing
            if should_trace
                # get current active span
                # or create an explicit root span
                ctx = if isnothing($(esc(root_sc)))
                    active_ctx()
                else
                    ActiveCtx(root_span($(esc(root_sc))))
                end
                name = $(esc(name))
                # START THE SPAN
                span = _span_start(name, ctx)
                old_ctx = scoped_values_set_context(SPAN_CONTEXT => ActiveCtx(span))
            end
            try
                # Don't interpolate the expression twice, per general macro good-practice.
                $(esc(ex))
            catch e
                if should_trace
                    # Only pass the type of the exception as error. Previously we had some exceptions containing
                    # bigger datastructures that would get stringified, and it would in some cases cause some
                    # paged datastructure errors. The error will still be logged when it is normally handled,
                    # but this at least give us the type of the exception, and makes sure the span is marked
                    # correctly in DD as error. Related issue: RAI-10408
                    span.error = typeof(e)
                    # IMPORTANT: previously we added stacktrace here as span attribute. This was performing
                    # very badly with our sysimage from the binary build. DO NOT ADD BACK UNLESS THAT IS SOLVED!
                end
                rethrow()
            finally
                if should_trace
                    # STOP THE SPAN
                    _span_end(span, ctx)
                    scoped_values_reset_context(old_ctx)
                end
            end
        end
    end
end

function _span_func(expr::Expr; tracing_level::Option{Int64} = nothing, caller_module::Option{String} = nothing)
    if length(expr.args[1].args) == 2 && expr.args[1].head == :(::)
        # extract return Type
        T = expr.args[1].args[2]
        # extract function name
        funcname = expr.args[1].args[1].args[1]
        # extract args
        args = expr.args[1].args[1].args[2:end]
    else
        T = Any
        funcname = expr.args[1].args[1]
        args = expr.args[1].args[2:end]
    end
    # extract body
    body = expr.args[2]
    return quote
        function $(esc(funcname))($((esc(arg) for arg in args)...))::$(esc(T))
            $(_span(string(funcname), body; tracing_level=tracing_level, caller_module=caller_module))
        end
    end
end

function _generate_name(ex::Expr, src::LineNumberNode)
    if ex.head == :call
        name = string(ex.args[1])
        # Heuristic special treatement: if this is an operator (checked via length == 1),
        # use the entire expression instead. Check whether it is too long though.
        length(name) <= 1 && (name = string(ex))
        length(name) <= 80 || error("The name of a @sub_span is too long: $name")
        return name
    else
        # For expression blocks just use the filename and line.
        return string(basename(string(src.file)), ":", src.line)
    end
end

function _sub_span(name, ex::Expr; tracing_level::Option{Int64} = nothing, caller_module::Option{String} = nothing)
    return quote
        # As of Dec '20, the most expensive part about this macro are the two calls
        # to `now()`. Together they cost 45-50ns. Note: `time_ns()` is slightly slower.
        local start_time = in_now()
        # Need to wrap this in a try-finally for now, even though this costs ~20ns!
        # Otherwise, we cannot handle the case where `ex` contains a `return` correctly.
        try
            # Do not add `return` here, to not prematurely exit a function surrounding
            # the macro expansion.
            $(esc(ex))
        finally
            @inbounds begin
                if tracing_config.tracing_enabled && should_emit_tracing($(esc(tracing_level)), $(esc(caller_module)))
                    # Since this is a sub-span, a trace is guaranteed to exist. Therefore we
                    # can call active_ctx().
                    ctx = active_ctx()
                    span = ctx.current_span
                    if !_is_root(span)
                        _inc_sub_span_time!(span, $(esc(name)), in_now() - start_time)
                    end
                end
            end
        end
    end
end

function _span_attribute(key::String, value, tracing_level::Option{Int64}, caller_module::Option{String})
    quote
        begin
            if tracing_config.tracing_enabled && should_emit_tracing($(esc(tracing_level)), $(esc(caller_module)))
                ctx = active_ctx()
                span = ctx.current_span
                if !_is_root(span)
                    span_attribute!(span, $(esc(key)) , $(esc(value)))
                    span_attribute(tracing_config.backend, $(esc(key)), $(esc(value)), span, ctx)
                end
            end
        end
    end
end

########################################
# Publicly Accessible Methods for the
# Tracing Library
########################################
"""
    span_bag(key, value, ctx::ActiveCtx = active_ctx())

Adds the (key,value) pair to the current active span's SpanContext bag.

e.g.:
    ```
    @span "outer span" begin
        # adding (k,v) to the context bag
        span_bag("k", "v")
        @span "inner span" begin # nested span
            # get from context
            v = get_span_bag("k")
            ...
        end
    end
    ```
"""
function span_bag(key, value, ctx::ActiveCtx = active_ctx())
    if tracing_config.tracing_enabled
        span = ctx.current_span
        _is_root(span) && return nothing
        span_bag!(span, key, value)
        span_bag(tracing_config.backend, key, value, span, ctx)
    end

    return nothing
end

"""
    span_metric(key::String, value::Float64, ctx::ActiveCtx = active_ctx())

Merges the (key,value) pair to the current active span's metrics.
Note: Only used for the print backend

e.g.,
    ```
    @span "outer span" begin
        @span "inner span-1" begin
            @span "inner inner span" begin
                span_metric("metric1",1.0)
            end
        end
        @span "inner span-2" begin # nested span
            span_metric("metric1",1.0)
            span_metric("metric2",1.0)
        end
    end
    ```
"""
function span_metric(key::String, value::Float64, ctx::ActiveCtx = active_ctx())
    if tracing_config.tracing_enabled
        span = ctx.current_span
        _is_root(span) && return nothing
        span_merge_metrics!(span, key, value)
    end

    return nothing
end


"""
    get_span_bag(key, ctx::ActiveCtx = active_ctx())

Get current Span's SpanContext bag value via key

e.g.:
    ```
    @span "outer span" begin
        # adding (k,v) to the context bag
        span_bag("k", "v")
        @span "inner span" begin # nested span
            # get from context
            v = get_span_bag("k")
            ...
        end
    end
    ```
"""
function get_span_bag(key, ctx::ActiveCtx = active_ctx())
    if tracing_config.tracing_enabled
        span = ctx.current_span
        _is_root(span) && return nothing
        return get(span.span_context.bag, key, nothing)
    end

    return nothing
end

"""
    @span name::String ex::Expr

Creates a Span with a given explicit name.

e.g.:
    ```
    @span "my-span" myfunction()
    ```

    ```
    @span "outer span" begin
        @span "inner span" begin # nested span
          myfunction()
        end
    end
    ```
"""
macro span(name, ex::Expr)
    return _span(name, ex)
end

"""
    @span name::String tracing_level::Int64 ex::Expr

    Creates a Span with a given explicit name and tracing level

    e.g.:
        @span "span name" 2 begin
            ...
        end
"""
macro span(name, tracing_level::Int64, ex::Expr)
    return _span(name, ex; tracing_level=tracing_level, caller_module=string(__module__))
end

# With explicit root SpanContext. used mainly for creating a span
# that is a continuation from a distributed trace.
# i.e., root_sc is the `Extracted` SpanContext.
macro span(name, root_sc, ex::Expr)
    return _span(name, ex; root_sc = root_sc)
end

"""
    @span name::String tracing_level::Int64 root_sc ex::Expr

    Creates a Span with a given name, tracing level, and root SpanContext
"""
macro span(name, tracing_level::Int64, root_sc, ex::Expr)
    return _span(name, ex; tracing_level=tracing_level, caller_module=string(__module__), root_sc=root_sc)
end

_is_func_def(f) = isa(f, Expr) && (f.head === :function || Base.is_short_function_def(f))

"""
    @span ex::Expr

    Creates a Span without an explicit name.
"""
macro span(ex::Expr)
    _is_func_def(ex) && return _span_func(ex)
    return _span(_generate_name(ex, __source__), ex)
end

"""
    @span tracing_level::Int64 ex::Expr

    Creates a Span with tracing level and without a name
"""
macro span(tracing_level::Int64, ex::Expr)
    _is_func_def(ex) && return _span_func(ex, tracing_level=tracing_level, caller_module=string(__module__))
    return _span(_generate_name(ex, __source__), ex; tracing_level=tracing_level, caller_module=string(__module__))
end

# Sub-spans macros with and without a name given explicitly.
"""
    @sub_span name::String ex::Expr

    Creates a Subspan with a given explicit name.
"""
macro sub_span(name, ex::Expr)
    return _sub_span(name, ex)
end

"""
    @sub_span name::String tracing_level::Int64 ex::Expr

    Creates a Subspan with a given explicit name and tracing level
"""
macro sub_span(name, tracing_level::Int64, ex::Expr)
    return _sub_span(name, ex; tracing_level=tracing_level, caller_module=string(__module__))
end

"""
    @sub_span ex::Expr

    Creates a Subspan without an explicit name.
"""
macro sub_span(ex::Expr)
    return _sub_span(_generate_name(ex, __source__), ex)
end

"""
    @sub_span tracing_level::Int64 ex::Expr

    Creates a Subspan with tracing level and without an explicit name.
"""
macro sub_span(tracing_level::Int64, ex::Expr)
    return _sub_span(_generate_name(ex, __source__), ex; tracing_level=tracing_level, caller_module=string(__module__))
end

"""
    @span_attribute key::String value tracing_level::Int64

Tags the (key,value) pair to the current active span. Setting the tracing_level is optional

```
    @span "outer span" begin
        # tagging outer span
        @span_attribute "k1" "v1"
        @span "inner span" begin # nested span
            # tagging inner span
            @span_attribute "k2" "v2"
            myfunction()
        end
    end
```
"""
macro span_attribute(key::String, value, tracing_level::Option{Int64} = nothing)
    return _span_attribute(key, value, tracing_level, string(__module__))
end

"""
    @span_no_threshold name::String ex::Expr

Creates a Span with a given explicit name and without a duration threshold for emitting.

e.g.:
    ```
    @span_no_threshold "my-span" myfunction()
    ```
"""
macro span_no_threshold(name, ex::Expr)
    return esc(quote
        @span $name begin
            @span_attribute "no_threshold" "true"
            $ex
        end
    end)
end

"""
    @span_no_threshold name::String root_sc::SpanContext ex::Expr

Creates a Span with a given explicit name, a root SpanContext and without a duration
threshold for emitting.

e.g.:
    ```
    @span_no_threshold "my-span" root_sc myfunction()
    ```
"""
macro span_no_threshold(name, root_sc, ex::Expr)
    return esc(quote
        @span $name $root_sc begin
            @span_attribute "no_threshold" "true"
            $ex
        end
    end)
end

########################################
# Backend Specific Tracing Functionality
########################################
abstract type TracingBackend end
struct NoneBackend <: TracingBackend end
const backend_mapping = Dict{String,Type}()

# interface / possible overrides for TracingBackend
gen_trace_id(::Type{B}) where {B<:TracingBackend} = rand(UInt64)
function send_span(::Type{B}, span::Span) where {B<:TracingBackend} end
function span_start(::Type{B}, span::Span, ctx::ActiveCtx) where {B<:TracingBackend} end
function span_end(::Type{B}, span::Span, ctx::ActiveCtx) where {B<:TracingBackend} end
function span_attribute(
    ::Type{B},
    key::String,
    value::AttributeValue,
    span::Span,
    ctx::ActiveCtx,
) where {B<:TracingBackend} end

function span_bag(
    ::Type{B},
    key::String,
    value::AttributeValue,
    span::Span,
    ctx::ActiveCtx,
) where {B<:TracingBackend} end

include("datadog.jl")
include("zipkin.jl")
include("xray.jl")
include("print.jl")
include("test.jl")

export active_ctx
export span_start, span_end
export span_bag, get_span_bag, span_metric
export @span, @sub_span, @span_attribute, @span_no_threshold
