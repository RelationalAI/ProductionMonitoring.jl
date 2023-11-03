## Implementation/override for the TracingBackend interface
## representing the DataDogBackend

import HTTP
import ProductionMonitoring.Metrics
import UUIDs

using Random
using Logging
using DataStructures: MultiDict
using ProductionMonitoring.Tracing: SPANS_BUFFER, SerializedSpan
using ProductionMonitoring.Metrics: AbstractMetricCollection, Counter, Gauge, publish_metrics_from, inc!
using ProductionMonitoring.TransactionLogging:
    @warn_with_current_exceptions, has_transaction_id, get_transaction_id

const DEFAULT_SERVICE_NAME = "rai-server"
const DEFAULT_SPAN_TYPE = "web"
const ENV_DD_AGENT_HOST = "DD_AGENT_HOST"
const ENV_DD_AGENT_PORT = "DD_AGENT_PORT"
const ENV_DD_TRACE_AGENT_URL = "DD_TRACE_AGENT_URL"
const ENV_DD_VERSION = "DD_VERSION"

# we want to be able to disable actually sending the HTTP request for testing but still
# exercise the production backend code
should_send_spans() = true

Base.@kwdef struct DatadogReporterMetrics <: AbstractMetricCollection
    tracing_datadog_num_flushes_total::Counter = Counter()
    tracing_datadog_num_flushes_failed_total::Counter = Counter()
    tracing_datadog_bytes_sent_total::Counter = Counter()
    tracing_datadog_spans_sent_total::Counter = Counter()
    tracing_datadog_spans_dropped_total::Counter = Counter()
    tracing_datadog_reporter_queue_size::Gauge = Gauge()

    trace_spans_filtered::Counter = Counter()
end

struct DataDogBackend <: TracingBackend end
backend_mapping["DATADOG"] = DataDogBackend

const METRICS = DatadogReporterMetrics()
const DEFAULT_META_ATTRIBUTES = Dict{String,String}()

struct SpanBatcher
    spans_by_trace_id::MultiDict{UInt64,SerializedSpan}

    function SpanBatcher()
        new(MultiDict{UInt64,SerializedSpan}())
    end
end

function __init__()
    publish_metrics_from(METRICS; overwrite=true)
    envExtraction = Dict("env" => "DD_ENV", "version" => "DD_VERSION")
    DEFAULT_META_ATTRIBUTES["runtime-id"] = string(UUIDs.uuid4())
    defaultMeta = Dict{String,String}()
    for (metaName, envName) in envExtraction
        if haskey(ENV, envName)
            DEFAULT_META_ATTRIBUTES[metaName] = ENV[envName]
        end
    end
end

## Hook Interface override: `send_span`
function send_span(::Type{DataDogBackend}, span::Span)
    data = Dict(
        "trace_id" => span.span_context.traceid,
        "span_id" => span.id,
        "name" => span.name,
        "resource" => span.name,
        "service" => get(ENV, "DD_SERVICE", DEFAULT_SERVICE_NAME),
        "type" => DEFAULT_SPAN_TYPE,
        "start" => span.start_time,
        "duration" => (span.end_time - span.start_time),
        "meta" => copy(DEFAULT_META_ATTRIBUTES),
    )

    # TODO(RAI-17687): Make `transaction_id` a scoped value
    logger = Logging.current_logger()
    if has_transaction_id(logger)
        data["meta"]["rai.transaction_id"] = string(get_transaction_id(logger))
    end

    # inject common attributes

    if span.parent_span.id != 0
        data["parent_id"] = span.parent_span.id
    end

    data["meta"]["TaskOID"] = string(span.taskoid)
    data["meta"]["ThreadID"] = string(span.threadid)
    data["meta"]["span_id"] = string(span.id)

    if span.error !== nothing
        data["error"] = 1
        data["meta"]["error"] = string(span.error)
    end

    if !isnothing(span.attributes)
        for (k, v) in span.attributes
            v = attribute_to_string(v)
            if length(v) > 1000
                @warn "Skipping span attribute $k: $v"
                continue
            end
            data["meta"][k] = v
        end
    end

    # Add span to the Channel/Buffer
    return put!(SPANS_BUFFER, data)
end

# Flush spans to the wire
# Format for Datadog input is:
# vector{Vector{Spans}}, i.e., where the inner vector
# collects all spans from the same traceid into the
# same vector

# Default agent configuration supports env variables that can override the
# host:port or url where the traces are sent to, see:
#
# https://docs.datadoghq.com/tracing/setup_overview/setup/python/?tab=containers
# We can configure this using DD_AGENT_HOST:DD_AGENT_PORT.
# Alternatively, DD_TRACE_AGENT_URL and DD_DOGSTATSD_URL can be set to use variety
# of backends.
# DD_DOGSTATSD_HOST, DD_DOGSTATD_PORT, DD_DOGSTATD_URL need to be used in Metrics.

"""
Holds reference to datadog trace backend url string. This will be set once at startup.
"""
const __TRACE_BACKEND_URL__ = Ref{String}()

"""
Returns the url to which the traces should be sent to.

This method caches the result in TRACE_BACKEND_URL so that we make it more efficient on
subsequent lookups.
"""
function get_datadog_trace_backend_url()
    if !isassigned(__TRACE_BACKEND_URL__)
        host = get(ENV, ENV_DD_AGENT_HOST, "localhost")
        port = get(ENV, ENV_DD_AGENT_PORT, "8126")
        be_addr = get(ENV, ENV_DD_TRACE_AGENT_URL, "http://$host:$port")
        __TRACE_BACKEND_URL__[] = "$be_addr/v0.4/traces"
    end
    return __TRACE_BACKEND_URL__[]
end

function try_send(data::MultiDict{UInt64,SerializedSpan})
    payload = collect(values(data))
    payload_str = JSON.json(payload)

    try
        should_send_spans() && HTTP.request(
            "PUT",
            get_datadog_trace_backend_url(),
            ["Content-Type" => "application/json"],
            payload_str,
        )
        !should_send_spans() && @warn_every_n_seconds 10 "Sending spans to datadog is disabled."
        @debug("DataDog Background Daemon sent $(length(payload)) traces")

        # Measure how many times we send spans to datadog, and how big each payload is.
        # Payload size is a rough proxy for how much memory we're using for spans.
        inc!(METRICS.tracing_datadog_num_flushes_total)
        inc!(METRICS.tracing_datadog_bytes_sent_total, length(payload_str))
        inc!(METRICS.tracing_datadog_spans_sent_total, length(payload))
    catch e
        inc!(METRICS.tracing_datadog_spans_dropped_total, length(payload))
        inc!(METRICS.tracing_datadog_num_flushes_failed_total)
        @warn_with_current_exceptions(
            "Failed to send Spans payload to DataDog due to the following error: $e"
        )
    end
end

# Push a span onto the batch for that transaction, and send the batch if it's full
function push_maybe_send!(batcher::SpanBatcher, span::SerializedSpan)
    # Create a trace batch per transaction. Each batch has spans from a single
    # transaction so that we don't mix up spans from different traces in the same batch.
    trace_id = span["trace_id"]
    push!(batcher.spans_by_trace_id, span["trace_id"] => span)
    # If the number of spans for a specific trace id has reached the max size per
    # batch, we send the spans as a batch to Datadog and delete the trace id from
    # batcher.spans_by_trace_id.
    spans = batcher.spans_by_trace_id[trace_id]
    if length(spans) >= MAX_SPANS_PER_BATCH
        # Converting to MultiDict because Datadog wouldn't have it any other way.
        trace_batch = MultiDict{UInt64,SerializedSpan}(trace_id => spans)
        try_send(trace_batch)
        delete!(batcher.spans_by_trace_id, trace_id)
    end
end

function send_remaining(batcher::SpanBatcher)
    for (trace_id, spans) in batcher.spans_by_trace_id
        # Converting to MultiDict because Datadog wouldn't have it any other way.
        trace_batch = MultiDict{UInt64,SerializedSpan}(trace_id => spans)
        try_send(trace_batch)
    end
end

# Buffer spans and send to the wire
function datadog_buffer_spans_and_send!()
    batcher = SpanBatcher()
    while isready(SPANS_BUFFER)
        Metrics.set!(
            METRICS.tracing_datadog_reporter_queue_size,
            Float64(length(SPANS_BUFFER.data)),
        )
        span = take!(SPANS_BUFFER)
        push_maybe_send!(batcher, span)
    end
    # There could be a situation where the last trace batch of a transaction hasn't reached
    # the max_spans_per_batch size and therefore it won't be sent to DD inside the loop.
    # Hence, we flush any remaining trace batches here.
    send_remaining(batcher)
end

export datadog_buffer_spans_and_send!
