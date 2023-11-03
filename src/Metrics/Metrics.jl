module Metrics

using Dates
using Printf
using Sockets
import Dates

export MetricRegistry, get_default_registry
export AbstractMetricCollection, register_collection!, publish_metrics_from
export Counter, Gauge, inc!, dec!, set!
export handle_metrics

using Dates: DateTime, now
using ProductionMonitoring.DebugLevels: @warn_with_verbosity

# Cap the number of cells per metric at 200.
# If we don't do this, faulty code could exhaust all available memory, incur significant
# cost due to monitoring storage costs (datadog) and significantly slow down metric export
# code due to massive number of cells to work through.
const MAX_CELLS_PER_METRIC = 200

const OptionalStringRef = Ref{Union{Nothing,String}}

"""
    validate_metric_name(name::String)

Ensures that the metric meets datadog and prometheus naming requirements.

For more information, see:
- https://prometheus.io/docs/practices/naming/
- https://docs.datadoghq.com/developers/metrics/
- https://docs.datadoghq.com/developers/guide/what-best-practices-are-recommended-for-naming-metrics-and-tags/
"""
function validate_metric_name(name::String)
    if !isletter(name[1])
        throw(ArgumentError("Metric name must begin with a letter: $name"))
    end
    if !isascii(name)
        throw(ArgumentError("Metric name contains non-ASCII characters: $name"))
    end
    if length(name) > 200
        throw(
            ArgumentError(
                "Metric name is too long. Limit is 200 characters; provided name is $(length(name)) characters: $name",
            ),
        )
    end
    if !occursin(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$", name)
        throw(ArgumentError("Metric name does not meet prometheus naming restrictions: $name"))
    end
    return nothing
end

# TODO(janrous): Integrate this with latency-tracking metrics once they exist.
# See https://github.com/RelationalAI/raicode/issues/4372
macro time_ms(ex)
    quote
        local elapsedtime = time_ns()
        $(esc(ex))
        (time_ns() - elapsedtime) / 1000000.0
    end
end

include("metrics-impls.jl")
include("value-containers.jl")
include("metric-group.jl")
include("registry.jl")
include("prometheus-exporter.jl")

end  # module
