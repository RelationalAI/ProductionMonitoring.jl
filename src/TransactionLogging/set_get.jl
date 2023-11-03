# TODO(PR): This is all RelationalAI-specific and should be extracted.



function has_transaction_id(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.transaction_id != ""
end

function get_transaction_id()
    return get_transaction_id(Logging.current_logger())
end

function get_transaction_id(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.transaction_id
end

has_commit(::Any) = false
function has_commit(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.commit != ""
end

function get_commit(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.commit
end

function has_build_timestamp(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.build_timestamp != ""
end

function get_build_timestamp(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.build_timestamp
end

function has_trace_id(logger::Union{JSONLogger,LocalLogger})
    return !isempty(logger.inner_state.trace_id)
end

function get_trace_id(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.trace_id
end

function set_trace_id!(logger::Union{JSONLogger,LocalLogger}, trace_id::AbstractString)
    Base.@lock logger.inner_state.lock begin
        logger.inner_state.trace_id = trace_id
        return nothing
    end
end

has_database_name(::Any) = false
function has_database_name(logger::Union{JSONLogger,LocalLogger})
    return !isempty(logger.inner_state.database_name)
end

has_database_id(::Any) = false
function has_database_id(logger::Union{JSONLogger,LocalLogger})
    return !isempty(logger.inner_state.database_id)
end

has_account_name(::Any) = false
function has_account_name(logger::Union{JSONLogger,LocalLogger})
    return !isnothing(logger.inner_state.account_name) && !isempty(logger.inner_state.account_name)
end

has_engine_name(::Any) = false
function has_engine_name(logger::Union{JSONLogger,LocalLogger})
    return !isnothing(logger.inner_state.engine_name) && !isempty(logger.inner_state.engine_name)
end

function get_database_name(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.database_name
end

function get_database_id(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.database_id
end

function get_account_name(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.account_name
end

function get_engine_name(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.engine_name
end

function set_database_name!(logger::Union{JSONLogger,LocalLogger}, db::AbstractString)
    Base.@lock logger.inner_state.lock begin
        logger.inner_state.database_name = db
        return nothing
    end
end

function set_database_id!(logger::Union{JSONLogger,LocalLogger}, id::AbstractString)
    Base.@lock logger.inner_state.lock begin
        logger.inner_state.database_id = id
        return nothing
    end
end

function set_database_name_and_id!(
    logger::Union{JSONLogger,LocalLogger},
    name::AbstractString,
    id::AbstractString
)
    Base.@lock logger.inner_state.lock begin
        logger.inner_state.database_name = name
        logger.inner_state.database_id = id
        return nothing
    end
end

function has_request_id(logger::Union{JSONLogger,LocalLogger})
    return !isempty(logger.inner_state.request_id)
end

function get_request_id(logger::Union{JSONLogger,LocalLogger})
    return logger.inner_state.request_id
end

function get_span_id end
function span_id_is_present(::Union{JSONLogger,LocalLogger})
    return false
end

function get_request_id()
    return get_request_id(Logging.current_logger())
end

# TODO: This method likely should either be a `String` constructor method,
#       or a method of the string print function `string`.
function current_exceptions_to_string(curr_exc)
    buf = IOBuffer()
    println(buf)
    ExceptionUnwrapping.summarize_current_exceptions(buf)
    println(buf, "\n===========================\n\nOriginal Error message:\n")
    Base.display_error(buf, curr_exc)
    return String(take!(buf))
end
function current_stacktrace_to_string(stacktrace)
    buf = IOBuffer()
    Base.show_backtrace(buf, stacktrace)
    return String(take!(buf))
end

@static if hasfield(Task, :logstate) # ScopedValues.jl only piggybacks on the logstate before Julia 1.11
    using ScopedValues: ScopePayloadLogger
    # Overloads for ScopedValues.jl logger (cries tears of disgust)
    # TODO: consider whether these should be scoped values or live in the top-level logger.
    # Would probably look nicer as scoped values; not sure about performance implications.
    # ========================================================================================
    update_last_logged_state(l::ScopePayloadLogger, id, duration) = update_last_logged_state(l.logger, id, duration)
    has_transaction_id(l::ScopePayloadLogger) = has_transaction_id(l.logger)
    get_transaction_id(l::ScopePayloadLogger) = get_transaction_id(l.logger)
    has_commit(l::ScopePayloadLogger) = has_commit(l.logger)
    get_commit(l::ScopePayloadLogger) = get_commit(l.logger)
    has_build_timestamp(l::ScopePayloadLogger) = has_build_timestamp(l.logger)
    get_build_timestamp(l::ScopePayloadLogger) = get_build_timestamp(l.logger)
    has_trace_id(l::ScopePayloadLogger) = has_trace_id(l.logger)
    get_trace_id(l::ScopePayloadLogger) = get_trace_id(l.logger)
    set_trace_id!(l::ScopePayloadLogger, t::AbstractString) = set_trace_id!(l.logger, t)
    has_database_name(l::ScopePayloadLogger) = has_database_name(l.logger)
    get_database_name(l::ScopePayloadLogger) = get_database_name(l.logger)
    has_database_id(l::ScopePayloadLogger) = has_database_id(l.logger)
    get_database_id(l::ScopePayloadLogger) = get_database_id(l.logger)
    has_account_name(l::ScopePayloadLogger) = has_account_name(l.logger)
    get_account_name(l::ScopePayloadLogger) = get_account_name(l.logger)
    has_engine_name(l::ScopePayloadLogger) = has_engine_name(l.logger)
    get_engine_name(l::ScopePayloadLogger) = get_engine_name(l.logger)
    set_database_name!(l::ScopePayloadLogger, db::AbstractString) = set_database_name!(l.logger, db)
    set_database_id!(l::ScopePayloadLogger, id::AbstractString) = set_database_id!(l.logger, id)
    set_database_name_and_id!(
        l::ScopePayloadLogger,
        name::AbstractString,
        id::AbstractString
    ) = set_database_name_and_id!(l.logger, name, id)

    has_request_id(l::ScopePayloadLogger) = has_request_id(l.logger)
    get_request_id(l::ScopePayloadLogger) = get_request_id(l.logger)
    get_span_id(l::ScopePayloadLogger) = get_span_id(l.logger)
end

# Overloads for Julia's ConsoleLogger
# ========================================================================================

update_last_logged_state(::AbstractLogger, id, duration) = nothing
has_transaction_id(::AbstractLogger) = false
get_transaction_id(::AbstractLogger) = ""
has_commit(::AbstractLogger) = false
get_commit(::AbstractLogger) = ""
has_build_timestamp(::AbstractLogger) = false
get_build_timestamp(::AbstractLogger) = ""
has_trace_id(::AbstractLogger) = false
get_trace_id(::AbstractLogger) = ""
set_trace_id!(::AbstractLogger, ::AbstractString) = nothing
has_database_name(::AbstractLogger) = false
get_database_name(::AbstractLogger) = ""
has_database_id(::AbstractLogger) = false
get_database_id(::AbstractLogger) = ""
has_account_name(::AbstractLogger) = false
get_account_name(::AbstractLogger) = ""
has_engine_name(::AbstractLogger) = false
get_engine_name(::AbstractLogger) = ""
set_database_name!(::AbstractLogger, ::AbstractString) = nothing
set_database_id!(::AbstractLogger, ::AbstractString) = nothing
set_database_name_and_id!(::AbstractLogger, ::AbstractString, ::AbstractString) = nothing
has_request_id(::AbstractLogger) = false
get_request_id(::AbstractLogger) = ""
get_span_id(::AbstractLogger) = UInt64(0)
