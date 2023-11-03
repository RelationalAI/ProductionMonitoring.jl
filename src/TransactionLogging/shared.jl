# Shared inner data
# ========================================================================================
"""
struct InnerLogState

## Fields
- `request_id::String`: HTTP X-Request-Id associated with the request
- `transaction_id::String`: user-facing transaction guid for the transaction
- `commit::String`: raicode commit
- `build_timestamp`: rai-server build timestamp
"""
Base.@kwdef mutable struct InnerLogState
    database_name::String = ""
    database_id::String = ""
    account_name::Union{String, Nothing} = nothing
    engine_name::Union{String, Nothing} = nothing
    request_id::String = ""
    transaction_id::String = ""
    trace_id::String = ""
    commit::String = ""
    build_timestamp::String = ""
    lock::ReentrantLock = ReentrantLock()
    log_every_n_seconds::Dict{Any,Int} = Dict{Any,Int}()
    last_logged::Dict{Any,DateTime} = Dict{Any,DateTime}()
end

# Internal helper functions
# ========================================================================================
function restore_callsite_source_position!(expr, src)
    # because the logging macros call functions in this package, the source file+line are
    # incorrectly attributed to the wrong location, so we explicitly override the source
    # with the original value
    expr.args[1].args[2] = src
    return expr
end

function handle_special_kwargs(
    logger,
    id;
    log_every_n_seconds::Union{Nothing,Int64}=nothing,
    verbosity::Int64=VERBOSITY_DEFAULT,
    kwargs...,
)
    if !isnothing(log_every_n_seconds)
        update_last_logged_state(logger, id, log_every_n_seconds)
    end
    return kwargs,verbosity
end

# - caps the max number of characters and bumps remaining attributes to the message body
# - truncates attributes that are too long and copies them in full into the message body
# - does some ugly stuff to support dicts
function manage_kwarg_length(max_attr_char_count, attr_char_limit, kwargs...)
    out_dict = Dict()
    out_str = ""
    total_chars = 0
    for (k, v) in kwargs
        out_dict, out_str, total_chars = process_kwarg(k, v, max_attr_char_count, attr_char_limit, out_dict, out_str, total_chars, false)
    end

    return out_dict, out_str
end

function process_kwarg(k, v, max_attr_char_count, attr_char_limit, out_dict, out_str, total_chars, is_nested)
    is_reject = false

    strk = string(k)
    strk_len = length(strk)
    strv = string(v)
    strv_len = length(strv)

    # if the attribute isn't too long, we preserve its type
    out_k = k
    out_v = v

    remaining_chars = max_attr_char_count - total_chars
    if min(strv_len, attr_char_limit) + min(strk_len, attr_char_limit) > remaining_chars
        is_reject = true
    else
        # otherwise we truncate its string representation
        if strk_len > attr_char_limit
            out_k, out_str, total_chars = truncate_attribute(k, strk, max_attr_char_count, attr_char_limit, out_str, total_chars)
            is_reject = true
        else
            total_chars += strk_len
        end
        if strv_len > attr_char_limit
            out_v, out_str, total_chars = truncate_attribute(v, strv, max_attr_char_count, attr_char_limit, out_str, total_chars)
            is_reject = true
        else
            total_chars += strv_len
        end
        if total_chars > max_attr_char_count
            is_reject = true
        else
            out_dict[out_k] = out_v
        end

    end
    # if we truncated or omitted it, dump it into the log message body.
    # but only do this at the outermost layer so we don't duplicate nested attributes.
    if is_reject && !is_nested
        out_str = string(out_str, "$k: $v\n")
    end

    return out_dict, out_str, total_chars
end

function truncate_attribute(attr, strattr, max_attr_char_count, attr_char_limit, out_str, total_chars)
    remaining_chars = max_attr_char_count - total_chars
    chars_to_keep = min(attr_char_limit, remaining_chars)
    out_v = SubString(strattr, 1, thisind(strattr, chars_to_keep))
    total_chars += chars_to_keep
    return out_v, out_str, total_chars
end
# for dicts, we recursively truncate their nested attributes
function truncate_attribute(d::Dict, strattr, max_attr_char_count, attr_char_limit, out_str, total_chars)
    new_out_dict = Dict()
    for (k, v) in d
        new_out_dict, out_str, total_chars = process_kwarg(k, v, max_attr_char_count, attr_char_limit, new_out_dict, out_str, total_chars, true)
    end
    return new_out_dict, out_str, total_chars
end
# for dicts, we recursively truncate their nested attributes
function truncate_attribute(nt::NamedTuple, strattr, max_attr_char_count, attr_char_limit, out_str, total_chars)
    new_out_dict = Dict()
    for (k, v) in zip(keys(nt), nt)
        new_out_dict, out_str, total_chars = process_kwarg(k, v, max_attr_char_count, attr_char_limit, new_out_dict, out_str, total_chars, true)
    end
    return new_out_dict, out_str, total_chars
end

