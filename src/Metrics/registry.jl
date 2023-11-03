
# TODO(janrous): MetricGroup{T} currently supports arbitrary symbols for label
# names and arbitrary types for label values. We might want to enforce some
# stricter rules for MetricGroup{T} that will be registered and exported.

"""
    struct MetricRegistry

MetricRegistry is a collection of named metrics. Contents of registry can then be exported
to variety of monitoring systems (currently supported are prometheus and datadog).

Individual metrics can be associated with registry using the `register!` method.

Collection of metrics (subclass of `AbstractMetricCollection`) can be associated with
registry using `register_collection!` method.

When a collection is registered, the field name of each metric within the collection struct becomes the name of the exported metric.

Example:
The following code will register two metrics named `my_counter` and `my_gauge` with registry
`reg`:

```julia
Base.@kwdef struct MyMetrics <: AbstractMetricCollection
    my_counter::Counter = Counter()
    my_gauge::Gauge = Gauge()
end
metrics = MyMetrics()
register_collection!(reg, metrics)
```

MetricRegistry enforces that metric names are unique within a registry and that metric names
adhere to the requirements of the supported monitoring backends.
"""
struct MetricRegistry
    lock::ReentrantLock
    metrics::SortedDict{String,AbstractMetric}

    MetricRegistry() = new(ReentrantLock(), Dict{String,AbstractMetric}())
end

# Shorthand constructor registers metric collection `col` with the new registry.
function MetricRegistry(col)
    r = MetricRegistry()
    register_collection!(r, col)
    return r
end

# Default registry is intended for standard production monitoring metrics.
# Contents of the default registry should be accessible at /metrics http
# endpoint and should be periodically exported to statsd backend.
#
# This global variable is a singleton that is instantiated once `get_default_registry`
# is called for the first time.
const __DEFAULT_REGISTRY__ = Ref{Union{Nothing,MetricRegistry}}(nothing)
const __DEFAULT_REGISTRY_LOCK__ = Base.ReentrantLock()

"""
    get_default_registry()

Returns (and optionally constructs) the default MetricRegistry instance. This method ensures
that there is only one (singleton) instance of the default registry used across all modules
that use server metrics instrumentation. This singleton instance is constructed on the first
call to this method.
"""
function get_default_registry()
    if __DEFAULT_REGISTRY__[] === nothing
        Base.@lock __DEFAULT_REGISTRY_LOCK__ begin
            if __DEFAULT_REGISTRY__[] === nothing
                __DEFAULT_REGISTRY__[] = MetricRegistry()
            end
        end
    end
    return __DEFAULT_REGISTRY__[]::MetricRegistry
end

function set_metric_name!(m::AbstractMetric, name::String)
    if m.content.name[] === nothing
        m.content.name[] = name
    elseif m.content.name[] != name
        throw(AssertionError(
            "$(m.content.name[]): Metric can't be registered with different names."
        ))
    end
    return nothing
end
name(m::AbstractMetric) = m.content.name[]
name(m::MetricValueContainer) = m.name[]

"""
    register!(r::MetricRegistry, m::AbstractMetric)

Registers metric `m` with the registry `r` assigning it given `name`.

`name` must meet the naming constrains for statsd and prometheus backends as specified in
`validate_metric_name`.
"""
function register!(r::MetricRegistry, m::AbstractMetric, name::String; overwrite::Bool=false)
    validate_metric_name(name)
    isa(m.content, MetricGroup) && validate_metric_labels(m.content)

    Base.@lock r.lock begin
        if haskey(r.metrics, name)
            if overwrite
                @warn_with_verbosity 2 "Metric $(name) registered multiple times, overwriting existing one."
            else
                throw(KeyError("Metric name $(name) already registered"))
            end
        end
        set_metric_name!(m, name)
        r.metrics[name] = m
    end
    return m
end
register!(m::AbstractMetric, name::String) = register!(get_default_registry(), m, name)

"""
    unregister!(r::MetricRegister, name::String)

unregisters (dissociates) metric of a given `name` from the registry `r`.
"""
function unregister!(r::MetricRegistry, name::String)
    Base.@lock r.lock begin
        if !haskey(r.metrics, name)
            throw(KeyError("Metric $name not found in the registry"))
        end
        m = r.metrics[name]
        delete!(r.metrics, name)
    end
end

"""
    clear_registry!(r::MetricRegistry)

Removes all metrics from registry `r`.
"""
function clear_registry!(r::MetricRegistry)
    Base.@lock r.lock begin
        empty!(r.metrics)
    end
end

"""
    register_collection!(r::MetricRegistry, c::AbstractMetricCollection)

Registers metric contained within structure `stuff` with the registry `r`. The names of the
fields within the struct will be used as metric names when registering.
registry.
"""
function register_collection!(r::MetricRegistry, stuff::Any; overwrite::Bool = false)
    for prop_name in fieldnames(typeof(stuff))
        metric = getproperty(stuff, prop_name)
        if metric isa AbstractMetric
            register!(r, metric, String(prop_name); overwrite=overwrite)
        end
    end
    return nothing
end

"""
    publish_metrics_from(c::AbstractMetricCollection)

Registers metrics contained within `c` with the default registry. This effectively results
in these metrics being published to the production monitoring systems.
"""
publish_metrics_from(c; kwargs...) = register_collection!(get_default_registry(), c; kwargs...)

"""
    get_metric(r::MetricRegistry, name::String)

Retrieves metric of a given `name` from registry `r`. Throws `KeyError` if metric of a given
`name` is not found in the registry.
"""
function get_metric(r::MetricRegistry, name::String)
    Base.@lock r.lock begin
        return r.metrics[name]
    end
end


"""
    value_of(r::MetricRegistry, name::String; labels...)

Retrieve the value of a metric registered in `r` under `name`. For metrics that use labels,
their values should be set in `labels...`. In case the metric doesn't exist or
the metric doesn't have the specified cell (either due to nonexistence or invalid
labels), this function will return `nothing`. Otherwise, a Float64 representing
the current value will be returned.
"""
function value_of(r::MetricRegistry, name::String; labels...)
    try
        cell = get_cell_if_exists(get_metric(r, name); labels...)
        return cell.value[]
    catch
        return nothing
    end
end
value_of(name::String; labels...) = value_of(get_default_registry(), name; labels...)

"""
    value_not_nothing(r::MetricRegistry, name::String; labels...)

Like value_of, but will return 0 if the cell doesn't exist.
"""
function value_not_nothing(r::MetricRegistry, name::String; labels...)
    try
        cell = get_cell_if_exists(get_metric(r, name); labels...)
        return cell.value[]
    catch
        return 0.0
    end
end

value_not_nothing(name::String; labels...) = value_not_nothing(get_default_registry(), name; labels...)

zero_all_metrics() = zero_all_metrics(get_default_registry())
zero_all_metrics(r::MetricRegistry) = foreach(m -> zero_metric!(m.content), values(r.metrics))
