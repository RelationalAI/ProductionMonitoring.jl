####################################
# Buffering & Send spans to the wire
# configuration
####################################

const SerializedSpan = Dict{String,Any}
const MAX_SPANS_PER_BATCH = 200 #unit: spans
const SPANS_BUFFER_SIZE = 5000  #unit: spans
const DEFAULT_BATCH_DELAY = 1   #unit: seconds
# Channel buffer of Spans
global SPANS_BUFFER = Channel{Dict{String,Any}}(SPANS_BUFFER_SIZE)

function new_spans_buffer!()
    close(Tracing.SPANS_BUFFER)
    global SPANS_BUFFER = Channel{Dict{String,Any}}(SPANS_BUFFER_SIZE)
end

export SPANS_BUFFER
