
# TODO(RAI-11630): Move this logic into ContextVariablesX.jl and ScopedValues.jl.
# See: https://github.com/tkf/ContextVariablesX.jl/issues/19.
# Once implemented, we could switch to the macro version of `@with`

@static if hasfield(Task, :logstate) # ScopedValues.jl only piggybacks on the logstate before Julia 1.11
    function scoped_values_set_context(pair::Pair{<:ScopedValue}, rest::Pair{<:ScopedValue}...)
        logger = Logging.current_logger()

        scope = logger isa ScopedValues.ScopePayloadLogger ? logger.scope : nothing
        scope = ScopedValues.Scope(scope, pair...)
        for pair in rest
            scope = Scope(scope, pair...)
        end

        scopedlogger = ScopedValues.ScopePayloadLogger(logger, scope)

        ct = Base.current_task()
        original_logstate = ct.logstate
        ct.logstate = Base.CoreLogging.LogState(scopedlogger)

        return original_logstate
    end

    function scoped_values_reset_context(old)
        ct = current_task()
        ct.logstate = old
        return nothing
    end
else
    function scoped_values_set_context(pair::Pair{<:ScopedValue}, rest::Pair{<:ScopedValue}...)
        ct = Base.current_task()
        original_scope = ct.scope::Union{Nothing, ScopedValues.Scope}
        ct.scope = ScopedValues.Scope(original_scope, pair, rest...)
        return original_scope
    end

    function scoped_values_reset_context(old)
        ct = current_task()
        ct.scope = old
        return nothing
    end
end
