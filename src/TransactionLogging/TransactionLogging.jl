"""
Custom loggers which include additional Rel-related transaction context.
"""

module TransactionLogging

import Logging
import JSON
using Dates
using ProductionMonitoring.DebugLevels
using ExceptionUnwrapping
using Logging: AbstractLogger, ConsoleLogger, Info, Warn, LogLevel
using ScopedValues

include("scrub-secrets.jl")

export JSONLogger, LocalLogger
export @error_every_n_seconds, @info_every_n_seconds, @warn_every_n_seconds
export @error_with_current_exceptions, @warn_with_current_exceptions
export @warn_with_current_backtrace

include("shared.jl")

include("json_logger.jl")
include("local_logger.jl")

function should_log(logger::Union{JSONLogger,LocalLogger}, id)
    i = logger.inner_state
    Base.@lock i.lock begin
        return Dates.now() - get(i.last_logged, id, DateTime(0)) >
               Dates.Second(get(i.log_every_n_seconds, id, 0))
    end
end

function update_last_logged_state(logger::Union{JSONLogger,LocalLogger}, id, duration)
    Base.@lock logger.inner_state.lock begin
        logger.inner_state.log_every_n_seconds[id] = duration
        logger.inner_state.last_logged[id] = Dates.now()
    end
end

include("macros.jl")

include("set_get.jl")

include("colors.jl")

end # module TransactionLogging
