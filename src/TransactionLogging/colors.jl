# Colorization of output support
# ========================================================================================

"Determine whether a logger supports colorization of log messages."
function supports_color(::AbstractLogger) false end
# get(io, :color, false) is how printstyled determines whether to emit ANSI color codes.
supports_color(logger::LocalLogger) = get(logger.stream, :color, false)
# ConsoleLogger logs to stderr if its underlying stream is closed (the default).
supports_color(logger::ConsoleLogger) =
    get(isopen(logger.stream) ? logger.stream : stderr, :color, false)
@static if hasfield(Task, :logstate)
    # More tears of disgust on top of the tears over in set_get.jl
    supports_color(logger::ScopedValues.ScopePayloadLogger) = supports_color(logger.logger)
end

# LogBuffer is intended for use with printstyled(), to allow log messages to contain color
# if the underlying channel supports it. Uses supports_color(), above.
struct LogBuffer <: IO
    logger::AbstractLogger
    buffer::IOBuffer
end

LogBuffer(logger::AbstractLogger) = LogBuffer(logger, IOBuffer())
# Note the call to Logging.current_logger() below - a LogBuffer shouldn't be used across a
# change of loggers, otherwise you might send ANSI escape codes somewhere they aren't
# supported.
LogBuffer() = LogBuffer(Logging.current_logger())

# Overrides to implement a subset of IO for LogBuffer.
Base.write(b::LogBuffer, x::UInt8) = write(b.buffer, x)
Base.unsafe_write(b::LogBuffer, p::Ptr{UInt8}, n::UInt) = unsafe_write(b.buffer, p, n)
Base.get(b::LogBuffer, key, default) =
    key == :color ? supports_color(b.logger) : get(b.buffer, key, default)
Base.take!(b::LogBuffer) = take!(b.buffer)

# Make a logbuffer print() like its contents. This allows the idiom:
#
#   x = LogBuffer()
#   print(x, "some stuff")
#   @info x
#
# NB. print(x::LogBuffer) will do nothing, because LogBuffer <: IO, and print(io::IO,
# xs...) tries to print xs to io. Same thing happens with eg print(stdout).
function Base.print(io::IO, b::LogBuffer)
    write(io, take!(copy(b.buffer)))
    nothing
end

# Logging Utility for bundling prints and using color-aware IO
# ========================================================================================

# set up a color-aware io buffer to write messages into, then log it as one info message
# usage:
#   log_info_with_io() do io
#       print(io, "hello")
#       printstyled(io, " world"; color=:red)
#       return (;tag=value, ...) # optionally add structured metadata for logging
#   end
function log_info_with_io(f::Function)
    io = LogBuffer()
    kws = something(f(io), ())
    msg = String(take!(io))
    @info msg kws...
end
