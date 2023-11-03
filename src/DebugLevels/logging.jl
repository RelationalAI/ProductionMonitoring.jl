using Logging
using Match: @match

const LOG_DEFAULT = Logging.Info
const VERBOSITY_DEFAULT = 0

"""Struct that holds log and verbosity configuration"""
Base.@kwdef struct LogConfig <: AbstractDebugConfig
    # Severity level for logs (e.g. @debug, @info, @warn, @error)
    log::LogLevel = LOG_DEFAULT

    # Verbosity level (used for @debug_with_verbosity, @info_with_verbosity,
    # @warn_with_verbosity, @error_with_verbosity)
    verbosity::Int64 = VERBOSITY_DEFAULT
end

function Base.show(io::IO, log_config::LogConfig)
    print(io, "LogConfig(")
    print(io, "log=$(log_config.log), ")
    print(io, "verbosity=$(log_config.verbosity)")
    print(io, ")")
end

"""Sets the server-wide debug level defaults for logging."""
set_log_level_defaults(cfg::LogConfig) = _add_defaults(cfg)

"""Adds per-module override for log debug levels."""
set_log_level_override(module_name::String, cfg::LogConfig) = _add_override(module_name, cfg)

"""Removes log debug level overrides for `module_name`."""
function remove_log_level_override(module_name::String)
    delete!(get_debug_levels_dict(LogConfig), module_name)
    return nothing
end

"""Removes all per-module log level overrides."""
function remove_all_log_level_overrides()
    empty!(get_debug_levels_dict(LogConfig))
    return nothing
end

"""
    should_emit_log(level, verbosity, caller_module)

Returns true if the passed log level is more than or equal to the log level returned by
`get_log_setting`` function, false otherwise.

In addition to comparing the log level, and when called for logging with verbosity functions,
`should_emit_log` also consideres the verbosity level and returns true if the verbosity
passed is less than or equal to the one returned when calling `get_log_setting`

For example:
    If called for logging functions (like @debug) and get_log_setting returns Info,
`should_emit_log` returns true for @info, @warn, and @error, and returns false for @debug

    If called for logging with verbosity functions (like @debug_with_verbosity) and
get_log_setting returns (Info, 4), should_emit_log returns true for @info_with_verbosity,
@warn_with_verbosity, and @error_with_verbosity only if the verbosity passed is less than or
equal to 4, and returns false for @debug_with_verbosity regardless of its verbosity level
"""
function should_emit_log(level::LogLevel, verbosity::Int64, caller_module::String)
    cfg = lookup_debug_levels_for(LogConfig, caller_module)
    return level >= cfg.log && verbosity <= cfg.verbosity
end

"""Returns configured debug level verbosity for the passed module."""
function get_module_verbosity(caller_module::String)
    cfg = lookup_debug_levels_for(LogConfig, caller_module)
    return cfg.verbosity
end

"""Parses type_str into log severity type, falls back to `default` if the string can't be parsed"""
function parse_logging_type(type_str::String, default::Logging.LogLevel)
    log = @match type_str begin
        "Logging.Debug" || "Debug" => Logging.Debug
        "Logging.Info" || "Info" => Logging.Info
        "Logging.Warn" || "Warn" => Logging.Warn
        "Logging.Error" || "Error" => Logging.Error
        _ => begin
            @warn """[DEBUGLEVELS] Got unsupported argument value: '$(type_str)'; falling back to '$(default)'"""
            default
        end
    end

    return log
end

function query_extract_log(query_params)
    log = LOG_DEFAULT
    verbosity = VERBOSITY_DEFAULT

    haskey(query_params, "log") ? log = parse_logging_type(query_params["log"], LOG_DEFAULT) : ()
    haskey(query_params, "verbosity") ? verbosity = parse(Int64, query_params["verbosity"]) : ()

    return LogConfig(log = log, verbosity = verbosity)
end

"""Handles HTTP request to /set_log_defaults"""
function http_set_log_level_defaults(request::HTTP.Request)
    query_params = HTTP.queryparams(request.url)
    isempty(query_params) && return true

    try
        cfg = query_extract_log(query_params)
        set_log_level_defaults(cfg)

        response = IOBuffer("$(cfg)")
        return HTTP.Response(200, String(take!(response)))
    catch e
        return HTTP.Response(404, "Error: $e")
    end
end

"""Handles HTTP request to /set_log_overrides"""
function http_set_log_level_override(request::HTTP.Request)
    query_params = HTTP.queryparams(request.url)
    isempty(query_params) && return true

    if haskey(query_params, "module_name")
        try
            cfg = query_extract_log(query_params)
            set_log_level_override(query_params["module_name"], cfg)

            response = IOBuffer("$(cfg)")
            return HTTP.Response(200, String(take!(response)))
        catch e
            return HTTP.Response(404, "Error: $e")
        end
    else
        return HTTP.Response(400, "Module name not passed")
    end
end

"""Handles HTTP request to /log_levels"""
function expose_log_levels(request::HTTP.Request)
    response = IOBuffer()

    write(response, "defaults => $(get_debug_levels_defaults_dict(LogConfig)))\n")

    for (module_name, cfg) in get_debug_levels_dict(LogConfig)
        write(response, "$module_name => $cfg\n")
    end

    return HTTP.Response(200, String(take!(response)))
end

"""
Calls @debug with the passed level, checks are made when calling should_emit_log from the
loggers handle_message function
"""
macro debug_with_verbosity(verbosity::Int64, msg, exs...)
    return esc(quote
        if $DebugLevels.@should_emit_log($Logging.Info, $verbosity)
            $Base.@debug $msg verbosity=$verbosity $(exs...)
        end
    end)
end

"""
Calls @info with the passed level, checks are made when calling should_emit_log from the
loggers handle_message function
"""
macro info_with_verbosity(verbosity::Int64, msg, exs...)
    return esc(quote
        if $DebugLevels.@should_emit_log($Logging.Info, $verbosity)
            $Base.@info $msg verbosity=$verbosity $(exs...)
        end
    end)
end

"""
Calls @warn with the passed level, checks are made when calling should_emit_log from the
loggers handle_message function
"""
macro warn_with_verbosity(verbosity::Int64, msg, exs...)
    return esc(quote
        if $DebugLevels.@should_emit_log($Logging.Info, $verbosity)
            $Base.@warn $msg verbosity=$verbosity $(exs...)
        end
    end)
end

"""
Calls @error with the passed level, checks are made when calling should_emit_log from the
loggers handle_message function
"""
macro error_with_verbosity(verbosity::Int64, msg, exs...)
    return esc(quote
        if $DebugLevels.@should_emit_log($Logging.Info, $verbosity)
            $Base.@error $msg verbosity=$verbosity $(exs...)
        end
    end)
end

"""
Calls should_emit_log function, used for expensive debug messages as a check instead of
directly calling macros defined for logging
"""
macro should_emit_log(level_expr, verbosity)
    return :(should_emit_log($level_expr, $verbosity, $(string(__module__))))
end

"""Returns configured debug level verbosity for the current caller module."""
macro get_module_verbosity()
    return :(get_module_verbosity($(string(__module__))))
end
