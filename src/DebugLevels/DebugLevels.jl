module DebugLevels

using JSON3
using HTTP

const Option{T} = Union{Nothing,T}
abstract type AbstractDebugConfig end

include("logging.jl")
include("tracing.jl")

"""Dictionary for module-overrides debug levels"""
const __DEBUG_LEVELS__ = Dict{Type,Dict{String,AbstractDebugConfig}}()

"""Dictionary for default debug levels"""
const __DEBUG_LEVELS_DEFAULTS__ = Dict{Type,AbstractDebugConfig}()

"""Dictionary for HTTP handlers"""
const DEBUG_LEVELS_HTTP_HANDLERS = Dict(
    ("GET", "/log_levels") => expose_log_levels,
    ("GET", "/tracing_levels") => expose_tracing_levels,
    ("GET", "/set_log_defaults") => http_set_log_level_defaults,
    ("GET", "/set_log_overrides") => http_set_log_level_override,
    ("GET", "/set_tracing_defaults") => http_set_tracing_level_defaults,
    ("GET", "/set_tracing_overrides") => http_set_tracing_level_override,
)

function get_debug_levels_dict(typ::Type{T}) where {T<:AbstractDebugConfig}
    return get!(()->Dict{String,typ}(), __DEBUG_LEVELS__, typ)
end

function get_debug_levels_defaults_dict(typ::Type{T}) where {T<:AbstractDebugConfig}
    return get!(()->typ(), __DEBUG_LEVELS_DEFAULTS__, typ)
end

function put_debug_levels_defaults_dict(cfg::AbstractDebugConfig)
    __DEBUG_LEVELS_DEFAULTS__[typeof(cfg)] = cfg
    return nothing
end

"""
Looks up debug level configuration of type `typ` that should be applied to `module_name`.
This method will do recursive look up for full-path match as well as for path-component overrides. If no override is found, fixed default values will be returned.
"""
function lookup_debug_levels_for(typ::Type{T}, module_name::String)::T where {T<:AbstractDebugConfig}
    overrides = get_debug_levels_dict(typ)
    defaults = get_debug_levels_defaults_dict(typ)

    # Fist, look for fully qualified module_name override
    res = get(overrides, module_name, nothing)
    if res !== nothing
        return res
    end

    # Next, process the module name path components from right to left
    last_index = first_index = lastindex(module_name)
    while first_index >= 0
        if first_index == 0 || module_name[first_index] == '.'
            module_trimmed = SubString(module_name, first_index + 1, last_index)
            res = get(overrides, module_trimmed, nothing)
            if res !== nothing
                return res
            end
            last_index = first_index - 1
        end
        first_index = first_index - 1
    end

    # Return server-wide default or default instance of the config.
    return defaults
end

"""Adds `cfg` as a debug level override for `module_name`."""
function _add_override(module_name::String, cfg::AbstractDebugConfig)
    get_debug_levels_dict(typeof(cfg))[module_name] = cfg
    return nothing
end

"""Adds `cfg` as a debug level default for `module_name`."""
function _add_defaults(cfg::AbstractDebugConfig)
    put_debug_levels_defaults_dict(cfg)
    return nothing
end

"""Resets all debug levels to the default state."""
function reset_debug_levels!()
    empty!(__DEBUG_LEVELS__)
    empty!(__DEBUG_LEVELS_DEFAULTS__)
    return nothing
end

"""Prints the elements of __DEBUG_LEVELS__ dictionary"""
function show_debug_levels()
    for (typ, defaults) in __DEBUG_LEVELS_DEFAULTS__
        println("defaults => $defaults")
    end

    for (typ, overrides) in __DEBUG_LEVELS__
        for (module_name, cfg) in overrides
            println("$module_name => $cfg")
        end
    end
    return nothing
end

export LOG_DEFAULT, TRACING_DEFAULT, VERBOSITY_DEFAULT
export LogConfig, TracingConfig
export set_log_level_defaults, set_log_level_override
export set_tracing_level_defaults, set_tracing_level_override
export should_emit_tracing, should_emit_log
export remove_log_level_override, remove_all_log_level_overrides
export remove_tracing_level_override, remove_all_tracing_level_overrides
export reset_debug_levels!
export show_debug_levels
export parse_logging_type
export DEBUG_LEVELS_HTTP_HANDLERS
export http_set_log_level_defaults, http_set_log_level_override, http_set_tracing_level_defaults, http_set_tracing_level_override
export @debug_with_verbosity, @info_with_verbosity, @warn_with_verbosity, @error_with_verbosity
export @should_emit_log

end # module
