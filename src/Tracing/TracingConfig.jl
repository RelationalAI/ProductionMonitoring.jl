## Tracing Configuration

using ProductionMonitoring.ThreadingUtils: PeriodicTask, @spawn_sticky_periodic_task, stop_periodic_task!

# AbstractThreshold is the super types of all the available span thresholds.
# Each of the subtype is solely used by a should_span_be_filtered method.
abstract type AbstractThreshold end

# FixedThreshold filters spans that have a duration smaller than span_threshold_sec
struct FixedThreshold <: AbstractThreshold
    span_threshold_sec::Number
end

function should_span_be_filtered(threshold::FixedThreshold, span::Span)
    return (span_duration(span) / 1e9) < threshold.span_threshold_sec
end

# DynamicThreshold filters spans that meets the following condition:
#       (span_duration / (txn_start_time - now()+1)) < span_threshold_percent
# where:
#  - span_duration is the duration of the span (span.end_time - span.start_time),
#  - txn_start_time is the starttime of the root of the transaction, usually handle_v2_txn.
# Note that this condition is evaluated after a span has completed.
struct DynamicThreshold <: AbstractThreshold
    span_threshold_percent::Number
end

# Return the duration of a span as an UInt64
span_duration(span::Span) = (span.end_time - span.start_time)

function should_span_be_filtered(threshold::DynamicThreshold, span::Span)
    time_since_beginning_of_txn = span.end_time - span.span_context.trace_starttime
    # +1 is just to make sure we have no div by zero.
    ratio = span_duration(span) / (time_since_beginning_of_txn + 1)
    return ratio < threshold.span_threshold_percent
end

# No threshold is applied, so all the spans are sent.
struct NoThreshold <: AbstractThreshold end

should_span_be_filtered(threshold::NoThreshold, span::Span) = false

mutable struct TracingConfig
    tracing_enabled::Bool
    tracing_caching::Bool
    backend::Type
    profile_level::Union{Nothing,Symbol}
    # Background buffering Daemon for the DataDog agent
    datadog_bg::Union{Nothing,PeriodicTask}
    zipkin_bg::Union{Nothing,PeriodicTask}
    span_threshold::AbstractThreshold
    was_disabled::Bool
end

const tracing_config =
    TracingConfig(false, false, NoneBackend, nothing, nothing, nothing, NoThreshold(), false)

function should_span_be_filtered(span::Span)
    return should_span_be_filtered(tracing_config.span_threshold, span)
end

function send(span::Span)
    tracing_config.tracing_enabled || return nothing
    # If the span has an error or if it is marked as @span_no_threshold,
    # then it is sent no matter its duration.
    use_threshold =  isnothing(span.error) &&
        (isnothing(span.attributes) ||
        (get(span.attributes, "no_threshold", "false") != "true"))

    if use_threshold && should_span_be_filtered(span)
        inc!(METRICS.trace_spans_filtered)
        return nothing
    end
    send_span(tracing_config.backend, span)
    return nothing
end

function cache(s::Span)
    tracing_config.tracing_caching && add_span_to_cache(s)
end

function gen_trace_id()
    gen_trace_id(tracing_config.backend)
end

function start_datadog_exporter!()
    if isnothing(tracing_config.datadog_bg)
        tracing_config.datadog_bg =
            @spawn_sticky_periodic_task "DatadogTraceUploader" Dates.Second(
                DEFAULT_BATCH_DELAY,
            ) datadog_buffer_spans_and_send!() datadog_buffer_spans_and_send!()
        @info "Datadog tracing will send spans to $(get_datadog_trace_backend_url())"
    end
end

function start_zipkin_exporter!()
    if isnothing(tracing_config.zipkin_bg)
        tracing_config.zipkin_bg =
            @spawn_sticky_periodic_task "ZipkinTraceUploader" Dates.Second(
                DEFAULT_BATCH_DELAY,
            ) zipkin_buffer_spans_and_send() zipkin_buffer_spans_and_send()
    end
end

# This function is called from _stop!(server::RAIServer)
function stop_exporters!()
    if !isnothing(tracing_config.datadog_bg)
        stop_periodic_task!(tracing_config.datadog_bg)
        tracing_config.datadog_bg = nothing
    elseif !isnothing(tracing_config.zipkin_bg)
        stop_periodic_task!(tracing_config.zipkin_bg)
        tracing_config.zipkin_bg = nothing
    end
end

"""
    enable_tracing(backend)

    Enable tracing and set the corresponding tracing backend.

    We currently support the following backends:
   - PrintBackend: print traces
    - ZipkinBackend: send traces to (Open)Zipkin
    - XRay: send traces to AWS XRay
    - DataDogBackend: send traces to DataDog Tracing

Convenience method to enable tracing, by default with the `PrintBackend`.
"""
function enable_tracing(
    backend::Type{B} = PrintBackend;
    restart_ok::Bool = false,
) where {B<:TracingBackend}
    if tracing_config.was_disabled && !restart_ok
        @error "enable_tracing called after disable_tracing. This is not safe! DO NOT DO THIS"
        # TODO(janrous): consider throwing an exception here
    end
    tracing_config.tracing_enabled = true
    tracing_config.backend = backend
    if backend == DataDogBackend
        start_datadog_exporter!()
    elseif backend == ZipkinBackend
        start_zipkin_exporter!()
    end
    return nothing
end

"""
    current_tracing_backend()

Return the current tracing backend
"""
function current_tracing_backend()
    return tracing_config.backend
end

"""
    global_profile_level()::Union{Nothing,Symbol}

Returns the configured profiling granularity (either nothing, `:keys`, or `:functions`).
"""
function global_profile_level()
    return tracing_config.profile_level
end

"""
    disable_tracing()

Stops tracing and shuts down datadog exporter thread if present.

Note that this should only be used once at the end of the Server lifecycle.

Due to issues with Julia scheduling that can result in prolonged monitoring
blackouts we need to ensure that the exporter thread is started on a high
priority thread and this can't be guaranteed unless this is done at the
server startup.
"""
function disable_tracing()
    tracing_config.tracing_enabled = false
    tracing_config.backend = NoneBackend
    tracing_config.was_disabled = true
    stop_exporters!()
end


"""
    enable_tracing_cache()

Enable tracing caching. Only used for local-dev environments.
"""
function enable_tracing_cache()
    tracing_config.tracing_caching = true
    return nothing
end

"""
    disable_tracing_cache()

Disable tracing caching. Only used for local-dev environments.
"""
function disable_tracing_cache()
    tracing_config.tracing_caching = false
    return nothing
end

"""
    enable_profiling!(level::Symbol = :functions)

Sets the specified level globally.
"""
function enable_profiling!(level::Symbol = :functions)
    if level !== :keys && level !== :functions && level !== :regions
        throw("Unknown profiling level $(level).")
    end
    tracing_config.profile_level = level
    return nothing
end

"""
    disable_profiling!()

Disables profiling at any level globally.
"""
function disable_profiling!()
    tracing_config.profile_level = nothing
    return nothing
end

"""
    enable_span_threshold_sec(span_threshold_sec::Number)

Enables span threshold using a fixed threshold. Spans with duration that exceeds the
threshold (measured in seconds) are the only spans emitted.
"""
function enable_span_threshold_sec(span_threshold_sec::Number)
    if span_threshold_sec < 0
        @warn "[TRACING] Span threshold value can't be negative: '$(span_threshold_sec)', \
                span threshold is disabled"
    elseif !tracing_config.tracing_enabled
        @warn "[TRACING] Span threshold sec is set to: '$(span_threshold_sec)' sec without \
                enabling tracing, span threshold is disabled"
    elseif tracing_config.backend == PrintBackend
        @warn "[TRACING] Span threshold does not have an effect when used with \
                PrintBackend tracing mode, span threshold is disabled"
    else
        tracing_config.span_threshold = FixedThreshold(span_threshold_sec)
        @info "[TRACING] Span threshold enabled" span_threshold_sec
        return nothing
    end
    # We ended up with an incorrect value
    disable_span_threshold()
    return nothing
end

"""
    enable_span_threshold_percent(span_threshold_percent::Number)

Enables span threshold using a dynamic threshold. Spans with duration that exceeds the
dynamic threshold determined using the provided ratio are the only spans emitted.
"""
function enable_span_threshold_percent(span_threshold_percent::Number)
    if span_threshold_percent < 0
        @warn "[TRACING] Span percent threshold value can't be negative: \
                '$(span_threshold_percent)', span threshold is disabled"
    elseif span_threshold_percent > 1.0
        @warn "[TRACING] Span percent threshold value can't be greater than 1: \
                '$(span_threshold_percent)', span threshold is disabled"
    elseif !tracing_config.tracing_enabled
        @warn "[TRACING] Span percent threshold is set to: '$(span_threshold_percent)' \
                without enabling tracing, span threshold is disabled"
    elseif tracing_config.backend == PrintBackend
        @warn "[TRACING] Span percent threshold does not have an effect when used with \
                PrintBackend tracing mode, span threshold is disabled"
    else
        tracing_config.span_threshold = DynamicThreshold(span_threshold_percent)
        @info "[TRACING] Span percent threshold enabled" span_threshold_percent
        return nothing
    end
    # We ended up with an incorrect value
    disable_span_threshold()
    return nothing
end

"""
    disable_span_threshold()

Disables span threshold. All spans will be  emitted
"""
function disable_span_threshold()
    tracing_config.span_threshold = NoThreshold()
    return nothing
end

"""
    is_span_threshold_set()

Returns ture if the span threshold is set, false if not
"""
function is_span_threshold_set()
    return !(tracing_config.span_threshold isa NoThreshold)
end

export enable_tracing
export disable_tracing, gen_trace_id
export enable_tracing_cache, disable_tracing_cache
export enable_span_threshold_sec, enable_span_threshold_percent
export is_span_threshold_set
