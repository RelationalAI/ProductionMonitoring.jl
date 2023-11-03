# TransactionLogging

## Overview
The loggers implemented in this package add some transaction data to every log
message associated with a transaction, and in the case of the JSON logger
(intended for deployment environments) also attaches the request id to every
transaction-related message.

## Logger types

### JSONLogger

The JSON logger does what it sounds like it would: structures logs in a JSON-formatted way, so multi-line
log messages can be ingested correctly by our logging platform. It supports some built-in tags that are
set at create time (transaction id, build timestamp, etc) for easier log searching. Attributes can be
attached directly to the message as well, which will be structured in the JSON (rather than appended to the
message text). These attributes are searchable in Datadog, our observability platform. For example,
`@info "my message here" nproblems=5"` will have an attribute `nproblems` on the log. If you add a facet to
that attribute in Datadog, you can then do fancier searches (numeric comparisons, etc).

### LocalLogger

A slightly augmented standard Julia `ConsoleLogger` that supports the extra macros defined for the
`JSONLogger`. The local development companion.

## Limiting log output
To limit a single log line's output frequency, use the `@{error,warn,info}_every_n_seconds` macros.

Example:
```
@info_every_n_seconds 5 "This log message will appear at a maximum every 5 seconds"
```

## Displaying color in log messages

To colorize text in log messages, you can use the `LogBuffer` object in combination with
`printstyled`:

```julia
buffer = LogBuffer()
print(buffer, "this is ordinary text, but ")
printstyled(buffer, "this text is blue", color=:blue)
@info buffer
```

This will colorize the text, or not, depending on the value of `Logging.current_logger()`
when the `LogBuffer` is constructed. Log output sent to consoles supporting ANSI escape
codes will be colorized; log output sent to `JSONLogger` will not.

There is also a helper function which uses `LogBuffer` for color-aware logging and supports
adding structured metadata to logs:

```julia
log_info_with_io() do io
    print(io, "this is ordinary text, but ")
    printstyled(io, "this text is blue", color=:blue)
    return (;color="blue")
end
```

## Displaying stacktraces
`Base.display_error()` is oriented towards REPL usage, so while it's fine to
use it for displaying stacktraces tests or benchmarks, it should never be used
in production code.  Instead, a few macros are defined in this package to make
stacktrace logging easier and deployment-compatible.

Any time you would normally use `Base.display_error()` (typically after
catching an exception), `@error_with_current_exceptions` or a related macro should be used
instead. `@error_with_current_exceptions` and `@warn_with_current_exceptions` automatically
append `current_exceptions()` to the logged message using `Base.display_error()`
internally to format the stacktraces.

For example, the following code is a typical usage of `Base.display_error`:
```
try
    error("oh my, an error!")
catch
    @error "encountered an error while doing something:"
    Base.display_error(stdout, current_exceptions())
end
```

Output:
```
┌ Error: 2021-01-06T15:37:32.785 (txn_id: 1)
│ encountered an error while doing something:
└ @ RAICode.Server ~/workspace/raicode/src/Server/Server.jl:553
ERROR: oh my, an error!
Stacktrace:
 [1] error(::String) at ./error.jl:33
 [2] handle_txn(::HTTP.Messages.Request, ::RAIServer, ::UInt64) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:551
 [3] (::RelationalAI.Server.var"#16#17"{typeof(RelationalAI.Server.handle_not_found),Dict{Tuple{String,String},Function},HTTP.Messages.Request,RAIServer,UInt64,String})() at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:539
 [4] with_logstate(::Function, ::Any) at ./logging.jl:408
 [5] with_logger(::Function, ::TransactionLogging.LocalLogger) at ./logging.jl:514
 [6] handle(::Dict{Tuple{String,String},Function}, ::HTTP.Messages.Request, ::RAIServer; not_found::Function) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:529
 [7] handle at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:525 [inlined]
 [8] (::RelationalAI.Server.var"#10#11"{RAIServer})(::HTTP.Messages.Request) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:423
 [9] handle at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:253 [inlined]
 [10] handle(::HTTP.Handlers.RequestHandlerFunction{RelationalAI.Server.var"#10#11"{RAIServer}}, ::HTTP.Streams.Stream{HTTP.Messages.Request,HTTP.ConnectionPool.Transaction{Sockets.TCPSocket}}) at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:276
 [11] #4 at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:345 [inlined]
 [12] macro expansion at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Servers.jl:367 [inlined]
 [13] (::HTTP.Servers.var"#13#14"{HTTP.Handlers.var"#4#5"{HTTP.Handlers.RequestHandlerFunction{RelationalAI.Server.var"#10#11"{RAIServer}}},HTTP.ConnectionPool.Transaction{Sockets.TCPSocket},HTTP.Streams.Stream{HTTP.Messages.Request,HTTP.ConnectionPool.Transaction{Sockets.TCPSocket}}})() at ./task.jl:356
```

Here's what ~equivalent logging using `@error_with_current_exceptions` looks like:
```
try
    error("oh my, an error!")
catch
    @error_with_current_exceptions "encountered an error while doing something:"
end
```
Output:
```
┌ Error: 2021-01-06T15:39:24.944 (txn_id: 1)
│ encountered an error while doing something:
│ ERROR: oh my, an error!
│ Stacktrace:
│  [1] error(::String) at ./error.jl:33
│  [2] handle_txn(::HTTP.Messages.Request, ::RAIServer, ::UInt64) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:551
│  [3] (::RelationalAI.Server.var"#16#17"{typeof(RelationalAI.Server.handle_not_found),Dict{Tuple{String,String},Function},HTTP.Messages.Request,RAIServer,UInt64,String})() at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:539
│  [4] with_logstate(::Function, ::Any) at ./logging.jl:408
│  [5] with_logger(::Function, ::TransactionLogging.LocalLogger) at ./logging.jl:514
│  [6] handle(::Dict{Tuple{String,String},Function}, ::HTTP.Messages.Request, ::RAIServer; not_found::Function) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:529
│  [7] handle at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:525 [inlined]
│  [8] (::RelationalAI.Server.var"#10#11"{RAIServer})(::HTTP.Messages.Request) at /home/dana-the-dinosaur/workspace/raicode/src/Server/Server.jl:423
│  [9] handle at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:253 [inlined]
│  [10] handle(::HTTP.Handlers.RequestHandlerFunction{RelationalAI.Server.var"#10#11"{RAIServer}}, ::HTTP.Streams.Stream{HTTP.Messages.Request,HTTP.ConnectionPool.Transaction{Sockets.TCPSocket}}) at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:276
│  [11] #4 at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Handlers.jl:345 [inlined]
│  [12] macro expansion at /home/dana-the-dinosaur/.julia/packages/HTTP/IAI92/src/Servers.jl:367 [inlined]
│  [13] (::HTTP.Servers.var"#13#14"{HTTP.Handlers.var"#4#5"{HTTP.Handlers.RequestHandlerFunction{RelationalAI.Server.var"#10#11"{RAIServer}}},HTTP.ConnectionPool.Transaction{Sockets.TCPSocket},HTTP.Streams.Stream{HTTP.Messages.Request,HTTP.ConnectionPool.Transaction{Sockets.TCPSocket}}})() at ./task.jl:356
│
└ @ RelationalAI.Server ~/workspace/raicode/packages/TransactionLogging/src/TransactionLogging.jl:170
```
