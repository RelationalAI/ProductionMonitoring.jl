# LocalLogger
# ========================================================================================
"""
    struct LocalLogger <: AbstractLogger

## Fields
- `stream::IO=stderr`: The stream the log message will be written to.
- `min_level::LogLevel=Info`: The logging level to use.
- `transaction_id::String`: user-facing transaction guid for the transaction
- `console_logger::ConsoleLogger`: ConsoleLogger used internally to log the message

Logger which prepends timestamp and transaction_id to the log message before calling ConsoleLogger.
Logs all messages with level greater than or equal to `min_level` to `stream`.
"""
struct LocalLogger <: AbstractLogger
    stream::IO
    min_level::LogLevel
    inner_state::InnerLogState
    console_logger::ConsoleLogger
    function LocalLogger(;
        stream::IO=stderr,
        min_level::LogLevel=Info,
        request_id::AbstractString="",
        transaction_id::AbstractString="",
        trace_id::AbstractString="",
        database_name::AbstractString="",
        account_name::Union{String, Nothing}=nothing,
        engine_name::Union{String, Nothing}=nothing,
        console_logger=ConsoleLogger(stream, min_level),
    )
        return new(
            stream,
            min_level,
            InnerLogState(
                request_id=request_id,
                transaction_id=transaction_id,
                trace_id=trace_id,
                database_name=database_name,
                account_name=account_name,
                engine_name=engine_name
            ),
            console_logger,
        )
    end
end

# This constructor is assumed to exist by Suppressor
LocalLogger(stream::IO, level) = LocalLogger(stream=stream, min_level=level)

# Implementing the logger interface
# ========================================================================================
function Logging.shouldlog(logger::LocalLogger, level, _module, group, id)
    return should_log(logger, id)
end

Logging.min_enabled_level(logger::LocalLogger) =
    Logging.min_enabled_level(logger.console_logger)

Logging.catch_exceptions(logger::LocalLogger) =
    Logging.catch_exceptions(logger.console_logger)

function Logging.handle_message(
    logger::LocalLogger,
    level,
    message,
    _module,
    group,
    id,
    filepath,
    line;
    maxlog=nothing,
    kwargs...,
)
    requ_str = tran_str = trac_str = data_str = data_id_str = acco_str = engi_str = span_str = ""
    if has_request_id(logger)
        requ_str = " (request_id: $(get_request_id(logger)))"
    end
    if has_transaction_id(logger)
        tran_str = " (transaction_id: $(get_transaction_id(logger)))"
    end
    if has_trace_id(logger)
        trac_str = " (trace_id: $(get_trace_id(logger)))"
    end
    if has_database_name(logger)
        data_str = " (database_name: $(get_database_name(logger)))"
    end
    if has_database_id(logger)
        data_id_str = " (database_id: $(get_database_id(logger)))"
    end
    if has_account_name(logger)
        acco_str = " (account_name: $(get_account_name(logger)))"
    end
    if has_engine_name(logger)
        engi_str = " (engine_name: $(get_engine_name(logger)))"
    end
    if span_id_is_present(logger)
        span_str = " (span_id: $(get_span_id()))"
    end

    new_message = string(
            Dates.now(),
            requ_str, tran_str, trac_str, data_str, data_id_str, acco_str, engi_str, span_str,
            "\n",
            message)

    kwargs_dict, verbosity = handle_special_kwargs(logger, id; kwargs...)

    if should_emit_log(level, verbosity, string(_module))
        Logging.handle_message(
            logger.console_logger,
            level,
            new_message,
            _module,
            group,
            id,
            filepath,
            line;
            maxlog=maxlog,
            kwargs_dict...,
        )
    end
    nothing
end
