## Implementation/override for the TracingBackend interface
## representing the ZipKinBackend

import HTTP
using Random
using DataStructures: MultiDict
using ProductionMonitoring.Tracing: SPANS_BUFFER, SerializedSpan
using ProductionMonitoring.TransactionLogging: @warn_with_current_exceptions

struct ZipkinBackend <: TracingBackend end
backend_mapping["ZIPKIN"] = ZipkinBackend

## Hook Interface override: `send_span`
function send_span(::Type{ZipkinBackend}, span::Span)
    data = Dict(
        "traceId" => string(span.span_context.traceid, base = 16, pad = 16),
        "id" => string(span.id, base = 16, pad = 16),
        "name" => span.name,
        "kind" => "CLIENT",
        "timestamp" => @sprintf("%d", span.start_time / 1000),
        "duration" => @sprintf("%d", (span.end_time - span.start_time) / 1000),
        "debug" => true,
        "tags" => Dict{String,String}(),
    )

    if span.parent_span.id != 0
        data["parentId"] = string(span.parent_span.id, base = 16, pad = 16)
    end

    if span.error !== nothing
        data["tags"]["error"] = "true"
    end

    data["tags"]["TaskOID"] = string(span.taskoid)
    data["tags"]["ThreadID"] = string(span.threadid)

    if !isnothing(span.attributes)
        for (k, v) in span.attributes
            data["tags"][k] = attribute_to_string(v)
        end
    end

    put!(SPANS_BUFFER, data)
end

# Format for zipkin input is:
# vector{Spans}, i.e., a vector of Spans
function try_send_zipkin(payload::Vector{SerializedSpan})
    try
        r = HTTP.request(
            "POST",
            "http://127.0.0.1:9411/api/v2/spans",
            ["Content-Type" => "application/json"],
            JSON.json(payload),
        )
    catch e
        @warn_with_current_exceptions(
            "Failed to send Spans payload $(length(payload)) to Zipkin due to the following error: exception=($e, $(catch_backtrace())"
        )
        for data in payload
            @warn("Failed to send span $(data["id"]) and name $(data["name"])")
        end
    end
end
function zipkin_buffer_spans_and_send()
    # Initialization
    n = 0
    next_batch = Vector{SerializedSpan}()
    # Create Batch
    while isready(SPANS_BUFFER) && n < MAX_SPANS_PER_BATCH
        span = take!(SPANS_BUFFER)
        n = n + 1
        push!(next_batch, span)
    end
    # Flush
    !isempty(next_batch) && try_send_zipkin(next_batch)
end

export zipkin_buffer_spans_and_send
