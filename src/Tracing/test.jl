struct TestBackend <: TracingBackend end
backend_mapping["TEST"] = TestBackend

const test_sink = Vector{Span}([])

function gen_trace_id(::Type{TestBackend})
    trunc(UInt64, Dates.datetime2unix(Dates.now()))
end

function send_span(::Type{TestBackend}, span::Span)
    global test_sink
    push!(test_sink, span)
end
