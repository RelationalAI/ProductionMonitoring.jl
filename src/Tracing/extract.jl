## Extraction/Injection of SpanContexts
## Connecting to the outer world

using HTTP
using Unicode
####################
# Format
####################

struct Format
    # BaggageHeaderPrefix specifies the prefix that will be used in
    # HTTP headers or text maps to prefix baggage keys.
    BaggageHeaderPrefix::String

    # TraceIDHeader specifies the key that will be used in HTTP headers
    # or text maps to store the trace ID.
    TraceIDHeader::String

    # ParentIDHeader specifies the key that will be used in HTTP headers
    # or text maps to store the parent ID.
    ParentIDHeader::String

    # PriorityHeader specifies the key that will be used in HTTP headers
    # or text maps to store the sampling priority value.
    PriorityHeader::String
end

const DD_TRACE_ID_HEADER = "x-datadog-trace-id"
const DD_PARENT_ID_HEADER = "x-datadog-parent-id"

#####################
# DataDog HTTP Format
DataDogFormat = Format(
    "ot-baggage-",
    DD_TRACE_ID_HEADER,
    DD_PARENT_ID_HEADER,
    "x-datadog-sampling-priority",
)

#####################
# Opentracing HTTP Format


#####################
# Carriers
#####################
struct Carrier
    payload::Vector{Pair{String,String}}
end

# HTTPHeadersCarrier Constructor
Carrier(req::HTTP.Request) = Carrier(req.headers)

# TextMapCarrier Constructor
Carrier(d::Dict{String,String}) = Carrier(collect(d))

function set!(c::Carrier, k, v)
    c.payload[k] = v
end

function for_each_key(f::Function, c::Carrier)
    for (k, v) in c.payload
        f((k, v))
    end
end

#######################
# Main Functionality
#######################
"""
    extract(f::Format, c::Carrier)

  Extracts a SpanContext from the given Carrier `c` via the input Format `f`.
  returns nothing if the extraction is malformed.
"""
function extract(f::Format, c::Carrier)
    sc = SpanContext()

    for_each_key(c) do (kk, v)
        k = Unicode.normalize(kk; casefold = true)
        if k == f.TraceIDHeader
            sc.traceid = parse(UInt64, v)
        elseif k == f.ParentIDHeader
            sc.spanid = parse(UInt64, v)
        elseif startswith(k, f.BaggageHeaderPrefix)
            sc.bag[k[length(f.BaggageHeaderPrefix)+1:end]] = v
        else
            # do nothing
        end
    end
    if sc.spanid == 0 || sc.traceid == 0
        return nothing
    end
    return sc
end

function extract_or_create(f::Format, c::Carrier)
    sc = extract(f, c)
    !isnothing(sc) && return sc

    sc = SpanContext(gen_trace_id())
end
