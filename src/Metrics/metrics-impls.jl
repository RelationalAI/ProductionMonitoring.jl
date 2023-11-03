using DataStructures: SortedDict

abstract type AbstractMetricCollection end
abstract type AbstractMetric end
abstract type MetricValueContainer end

const MetricLabels = SortedDict{Symbol,String}

# Useful shorthands for the metric modification methods.
# By default we want to increment or decrement by one.
inc!(m::AbstractMetric; labels...) = inc!(m, 1.0; labels...)
dec!(m::AbstractMetric; labels...) = dec!(m, 1.0; labels...)

# We want to be able to use arbitrary numbers that will be converted to floats here.
inc!(m::AbstractMetric, v::Number; labels...) = inc!(m, convert(Float64, v); labels...)

"""
    get_cells(m::AbstractMetric)

Returns list of NumericMetric for each cell associated with this metric.
"""
get_cells(m::AbstractMetric) = _get_cells(m.content)
_get_cells(x) = [x]
get_cell_if_exists(m::AbstractMetric; labels...) = get_cell_if_exists(m.content; labels...)
get_cell!(mg::AbstractMetric; labels...) = get_cell!(mg.content; labels...)

"""
    struct Counter <: AbstractMetric

Counter is a metric with monotonically increasing value that never decreases.

Value of a counter may be reset to zero upon server restarts.
"""
struct Counter <: AbstractMetric
    content::MetricValueContainer
    # Contains last emitted value for each cell.
    # This is expected to be only manipulated by statsd-exporter and as such doesn't need
    # to be thread-safe.
    last_emitted_values::Dict{Any, Float64}

    function Counter(;labels::AbstractVector{Symbol}=Vector{Symbol}())
        if length(labels) > 0
            return new(MetricGroup(labels=labels), Dict())
        else
            return new(NumericMetric(0.0), Dict())
        end
    end
end

inc!(m::Counter, v::Float64; labels...) = inc!(m.content, v; labels...)
set_counter!(m::Counter, v::Number; lbl...) = set!(m.content, convert(Float64, v); lbl...)

"""
    struct Gauge <: AbstractMetric
Gauge is a metric that holds an arbitrary value that can be incremented, decremented or set
to arbitrary value.
"""
struct Gauge <: AbstractMetric
    content::MetricValueContainer
    function Gauge(value::Float64; labels::AbstractVector{Symbol}=Vector{Symbol}())
        if length(labels) > 0
            return new(MetricGroup(default_value=value, labels=labels))
        else
            return new(NumericMetric(value))
        end
    end
end
Gauge(v::Number; kwargs...) = Gauge(convert(Float64, v); kwargs...)
Gauge(;kwargs...) = Gauge(0.0; kwargs...)

inc!(m::Gauge, v::Float64; labels...) = inc!(m.content, v; labels...)
dec!(m::Gauge, v::Float64; labels...) = dec!(m.content, v; labels...)
set!(m::Gauge, v::Float64; labels...) = set!(m.content, v; labels...)
set_max!(m::Gauge, v::Float64; labels...) = set_max!(m.content, v; labels...)

# We want to be able to use arbitrary numbers that will be converted to floats here.
dec!(m::Gauge, v::Number; labels...) = dec!(m, convert(Float64, v); labels...)
set!(m::Gauge, v::Number; labels...) = set!(m, convert(Float64, v); labels...)
set_max!(m::Gauge, v::Number; labels...) = set_max!(m, convert(Float64, v); labels...)
