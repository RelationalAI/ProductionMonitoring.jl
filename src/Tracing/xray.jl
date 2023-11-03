## Implementation/override for the TracingBackend interface
## representing the XRayBackend

import Sockets: send, IPv4, UDPSocket

struct XRayBackend <: TracingBackend end
backend_mapping["XRAY"] = XRayBackend

## Hook Interface override: `send_span`
function send_span(::Type{XRayBackend}, span::Span)
    prefix = JSON.json(Dict("format" => "json", "version" => 1))

    h = string(span.span_context.traceid, base = 16, pad = 8)
    traceid = string("1-", h, "-", bytes2hex(rand(UInt8, 12)))

    data = Dict(
        "trace_id" => traceid,
        "id" => string(span.id, base = 16, pad = 16),
        "start_time" => span.start_time / 1000000000,
        "end_time" => span.end_time / 1000000000,
        "name" => span.name,
        "annotations" => Dict{String,String}(),
    )

    data["annotations"]["TaskOID"] = string(span.taskoid)
    data["annotations"]["ThreadID"] = string(span.threadid)

    if !isnothing(span.attributes)
        for (k, v) in span.attributes
            data["annotations"][k] = attribute_to_string(v)
        end
    end

    if span.parent_span.id != 0
        data["parent_id"] = string(span.parent_span.id, base = 16, pad = 16)
    end

    if !isnothing(span.error)
        data["error"] = true
    end

    s = string(prefix, "\n", JSON.json(data))
    # send payload directly
    try
        send(UDPSocket(), IPv4("127.0.0.1"), 2000, s)
    catch e
        TransactionLogging.@error_with_current_exceptions("Error while sending span `$(span.name)`: $e")
    end
    return nothing
end
