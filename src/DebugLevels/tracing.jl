const TRACING_DEFAULT = 0

"""Struct that holds tracing configuration"""
Base.@kwdef struct TracingConfig <: AbstractDebugConfig
    # Verbosity level for tracing
    tracing::Int64 = TRACING_DEFAULT
end

function Base.show(io::IO, tracing_config::TracingConfig)
    print(io, "TracingConfig(")
    print(io, "tracing=$(tracing_config.tracing)")
    print(io, ")")
end

"""Sets the server-wide debug level defaults for tracing."""
set_tracing_level_defaults(cfg::TracingConfig) = _add_defaults(cfg)

"""Adds per-module override for tracing."""
set_tracing_level_override(module_name::String, cfg::TracingConfig) = _add_override(module_name, cfg)

"""Removes tracing debug level overrides for `module_name`."""
function remove_tracing_level_override(module_name::String)
    delete!(get_debug_levels_dict(TracingConfig), module_name)
    return nothing
end

"""Removes all per-module overrides for tracing debug levels."""
function remove_all_tracing_level_overrides()
    empty!(get_debug_levels_dict(TracingConfig))
    return nothing
end

"""Returns true if the passed tracing level is less than or equal to the tracing level returned by get_tracing_level function, false otherwise"""
function should_emit_tracing(tracing_level::Option{Int64}, caller_module::Option{String})
    return tracing_level === nothing || caller_module === nothing || tracing_level <= lookup_debug_levels_for(TracingConfig, caller_module).tracing
end

function query_extract_tracing(query_params)
    tracing = TRACING_DEFAULT
    haskey(query_params, "tracing") ? tracing = parse(Int64, query_params["tracing"]) : ()
    return TracingConfig(tracing)
end

"""Handles HTTP request to /set_tracing_defaults"""
function http_set_tracing_level_defaults(request::HTTP.Request)
    query_params = HTTP.queryparams(request.url)
    isempty(query_params) && return true

    try
        cfg = query_extract_tracing(query_params)
        set_tracing_level_defaults(cfg)

        response = IOBuffer("$(cfg)")
        return HTTP.Response(200, String(take!(response)))
    catch e
        return HTTP.Response(404, "Error: $e")
    end
end

"""Handles HTTP request to /set_tracing_overrides"""
function http_set_tracing_level_override(request::HTTP.Request)
    query_params = HTTP.queryparams(request.url)
    isempty(query_params) && return true

    if haskey(query_params, "module_name")
        try
            cfg = query_extract_tracing(query_params)
            set_tracing_level_override(query_params["module_name"], cfg)

            response = IOBuffer("$(cfg)")
            return HTTP.Response(200, String(take!(response)))
        catch e
            return HTTP.Response(404, "Error: $e")
        end
    else
        return HTTP.Response(400, "Module name not passed")
    end
end

"""Handles HTTP GET request to /tracing_levels"""
function expose_tracing_levels(request::HTTP.Request)
    response = IOBuffer()

    write(response, "defaults => $(get_debug_levels_defaults_dict(TracingConfig)))\n")

    for (module_name, cfg) in get_debug_levels_dict(TracingConfig)
        write(response, "$module_name => $cfg\n")
    end

    return HTTP.Response(200, String(take!(response)))
end
