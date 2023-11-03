# JSONLogger
# ========================================================================================

# We limit the message length because Datadog fails to ingest structured log messages that
# are around ~60KB and the truncation breaks the json format and drops all the indexing
# attributes.
# Our Julia stack traces can be enormous and hit this limit while also being extremely
# valuable for debugging purposes. We split the log messages into smaller pieces to capture
# all info while still maintaining the searchable attributes.
const DEFAULT_MAX_MESSAGE_SIZE = UInt64(40 * 1024)  # 40Kb

# Max number of characters in the text components of user-added attributes.
# The built-in attributes (dbname, request id, etc) don't count against the limit.
const DEFAULT_MAX_ATTR_CHAR_COUNT = 16 * 1024
# Max number of characters per attribute.
const DEFAULT_ATTR_CHAR_LIMIT = 400

"""
    struct JSONLogger <: AbstractLogger

## Fields
- `stream::IO=stderr`: The stream the log message will be written to.
- `min_level::LogLevel=Info`: The logging level to use.
- `inner_state::InnerLogState`: Contains request_id, transaction_id, and some internal state to limit log output

Logger which outputs JSON formatted logs and includes request_id and transaction_id when present.
Logs all messages with level greater than or equal to `min_level` to `stream`.
"""
struct JSONLogger <: AbstractLogger
    stream::IO
    min_level::LogLevel
    max_message_size::UInt64
    max_attr_char_count::UInt64
    attr_char_limit::UInt64
    inner_state::InnerLogState
    function JSONLogger(;
        stream::IO=stderr,
        min_level::LogLevel=Info,
        request_id::AbstractString="",
        transaction_id::AbstractString="",
        commit::AbstractString="",
        build_timestamp::AbstractString="",
        trace_id::AbstractString="",
        max_message_size=DEFAULT_MAX_MESSAGE_SIZE,
        max_attr_char_count=DEFAULT_MAX_ATTR_CHAR_COUNT,
        attr_char_limit=DEFAULT_ATTR_CHAR_LIMIT,
        database_name::AbstractString="",
        account_name::Union{String, Nothing}=nothing,
        engine_name::Union{String, Nothing}=nothing,
    )
        return new(
            stream,
            min_level,
            max_message_size,
            max_attr_char_count,
            attr_char_limit,
            InnerLogState(
                request_id=request_id,
                transaction_id=transaction_id,
                commit=commit,
                build_timestamp=build_timestamp,
                trace_id=trace_id,
                database_name=database_name,
                account_name=account_name,
                engine_name=engine_name,
            ),
        )
    end
end

# Implementing the logger interface: a lightly modified version of SimpleLogger
# ========================================================================================
function Logging.shouldlog(logger::JSONLogger, level, _module, group, id)
    return should_log(logger, id)
end

Logging.min_enabled_level(logger::JSONLogger) = logger.min_level

Logging.catch_exceptions(logger::JSONLogger) = false

function Logging.handle_message(
    logger::JSONLogger,
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
    levelstr = level == Warn ? "Warning" : string(level)

    kwargs_dict, verbosity = handle_special_kwargs(logger, id; kwargs...)

    if should_emit_log(level, verbosity, string(_module))
        message = string(message)
        kwargs_attrs, attr_reject_string = manage_kwarg_length(logger.max_attr_char_count, logger.attr_char_limit, kwargs_dict...)

        logcontent = Dict(
            "level" => levelstr,
            "timestamp" => string(Dates.now()),
            "attrs" => kwargs_attrs,
            "thread_id" => Base.Threads.threadid(),
        )
        if has_request_id(logger)
            logcontent["request_id"] = get_request_id(logger)
        end
        if has_transaction_id(logger)
            logcontent["rai.transaction_id"] = string(get_transaction_id(logger))
        end
        if has_database_name(logger)
            dbname = string(get_database_name(logger))
            attr_dbname = dbname
            if length(dbname) > logger.attr_char_limit
                attr_dbname = SubString(attr_dbname, 1, logger.attr_char_limit)
                message = string(message, "\nfull rai.database_name: ", dbname)
            end
            logcontent["rai.database_name"] = attr_dbname
        end
        if has_database_id(logger)
            logcontent["rai.database_id"] = get_database_id(logger)
        end
        if has_account_name(logger)
            logcontent["rai.account_name"] = string(get_account_name(logger))
        end
        if has_engine_name(logger)
            logcontent["rai.engine_name"] = string(get_engine_name(logger))
        end
        if has_commit(logger)
            logcontent["rai.commit"] = get_commit(logger)
        end
        if has_build_timestamp(logger)
            logcontent["rai.build_timestamp"] = get_build_timestamp(logger)
        end
        if has_trace_id(logger)
            logcontent["dd.trace_id"] = get_trace_id(logger)
        end
        if span_id_is_present(logger)
            # We want to be able to correlate logs with spans, just like traces, but this is
            # not being exposed in datadog yet. We have a ticket open for datadog and we
            # will update this accordingly
            logcontent["dd.span_id"] = string(get_span_id())

            # Adding the span_id as an event attribute for now
            logcontent["span_id"] = string(get_span_id())
        end

        # append code location from which message came to end of emitted message
        # borrowed from ConsoleLogger
        suffix = ""
        if !(Info <= level < Warn)
            _module !== nothing && (suffix *= "$(_module)")
            if filepath !== nothing
                _module !== nothing && (suffix *= " ")
                suffix *= Base.contractuser(filepath)
                if line !== nothing
                    suffix *= ":$(isa(line, UnitRange) ? "$(first(line))-$(last(line))" : line)"
                end
            end
            !isempty(suffix) && (suffix = "\n@ " * suffix)
        end

        if length(attr_reject_string) > 0
            message = string(message, "\ndropped attributes:\n$attr_reject_string")
        end
        max_len = logger.max_message_size
        if max_len > 0 && sizeof(message) > max_len
            # the last valid index of the message. we're not shooting for exactly
            # max_message_size for each message, just kind of close.
            last_index = lastindex(message)
            num_msgs = Int(ceil(last_index / max_len))
            multipart_log_id = string(rand(UInt64))

            for i = 1:num_msgs
                # offset is essentially zero-indexed here so we can use nextind below
                offset = (i - 1) * max_len

                # with long characters, it is possible for the remaining character to have
                # been included in the previous message. if so, we keep the emtpy message
                # but still emit it so the message numbering is still accurate.
                # this will probably never matter.

                # the @view here is to ensure current_msg is type stable
                current_msg = @view ""[1 : end]

                # this logic is not perfect; long characters may be duplicated if they
                # straddle the offset just right. however, the extra complexity doesn't seem
                # worth it to fix.
                if offset <= last_index
                    start_i = nextind(message, offset)
                    end_i = nextind(message, min(offset + max_len, last_index) - 1)
                    current_msg = @view message[start_i : end_i]
                end

                logcontent["multipart_position"] = i
                logcontent["multipart_total"] = num_msgs
                logcontent["multipart_id"] = multipart_log_id

                multipart_prefix = "log message $i of $num_msgs:\n"
                # only show suffix on last message
                maybe_suffix = i == num_msgs ? suffix : ""
                logcontent["message"] = string(multipart_prefix, current_msg, maybe_suffix)

                json_format_and_write_to_stream(logcontent, logger.stream)
            end
        else
            logcontent["message"] = message * suffix
            logcontent["multipart_position"] = 1
            json_format_and_write_to_stream(logcontent, logger.stream)
        end
    end
    return nothing
end

function json_format_and_write_to_stream(logcontent, logstream)
    buf = IOBuffer()
    iob = IOContext(buf, logstream)

    # See https://github.com/RelationalAI/raicode/issues/7687.
    logcontent["message"] = scrub_secrets(logcontent["message"])
    JSON.print(iob, logcontent)
    println(iob, "\n")
    write(logstream, take!(buf))
    # In the case of skaffold, logstream is buffered. Contrast this with the normal case
    # where stderr is used instead, and writing is not buffered. To achieve roughly the same
    # result, flush after each write when using a buffered IO.
    typeof(logstream) <: IOStream && flush(logstream)
end
