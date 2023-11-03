using Base.Threads: Atomic

"""
    struct NumericMetric

Simple container that holds thread-safe numeric value and information about the time of the
last change as well as some metadata about the associated metric.
"""
mutable struct NumericMetric <: MetricValueContainer
    # Current value of the metric. Thread-safe.
    value::Atomic{Float64}

    # Timestamp of last change to `value`.
    # This is not guaranteed to be updated atomically with the value itself for efficiency
    # reasons. This is only used to determine which metrics have been changed recently when
    # optimizing statsd style export and monitoring systems need to work with some degree
    # of time uncertainty anyways.
    #
    # This holds the seconds since epoch, fetched by `Base.time()`. Note that this is in
    # UTC, i.e., different from `Dates.datetime2unix(now())` which appears to be in the
    # local TZ. `Base.time()` is backed by the C function `gettimeofday(..)`, see
    # https://github.com/JuliaLang/julia/blob/master/src/support/timefuncs.c which is UTC,
    # see https://pubs.opengroup.org/onlinepubs/7908799/xsh/gettimeofday.html.
    last_changed::Atomic{Float64}


    # Once the metric is associated with registry, this holds the name associated with this
    # metric.
    name::OptionalStringRef

    # Metrics can have zero or more key=value label assignments stored here.
    # For metrics that are part of the same group (collection of metrics with the
    # same name and fixed set of labels that need to be set), these should
    # uniquely identify the cell that this NumericMetric represents.
    labels::MetricLabels

    # TODO(janrous): for efficiency reasons we may precompute prometheus and statsd
    # string representation of labels.

    # TODO(janrous): we should also ensure immutability of labels, perhaps by using
    # Tuple{Pair{Symbol,Any}} instead of dict.
    function NumericMetric(v::Float64)
        return new(
            Atomic{Float64}(v),
            Atomic{Float64}(time()),
            OptionalStringRef(nothing),
            MetricLabels()
        )
    end
end

"""
    inc!(m::NumericMetric, v::Float64)

Increments the current value of numeric metric `m` by `v`.
"""
function inc!(m::NumericMetric, v::Float64)
    if v < 0
        @warn "$(m.name[]): Attempted to inc! metric by negative value"
        # Important to have a type-stable return value, even in the error case.
        return m.value[]
    end
    old_v = Base.Threads.atomic_add!(m.value, v)
    m.last_changed[] = time()
    return old_v
end

"""
    dec!(m::NumericMetric, v::Number)

Decrements the current value of numeric metric `m` by `v`.
"""
function dec!(m::NumericMetric, v::Float64)
    if v < 0
        @warn "$(m.name[]): Attempted to dec! metric by negative value"
        # Important to have a type-stable return value, even in the error case.
        return m.value[]
    end
    old_v = Base.Threads.atomic_sub!(m.value, v)
    m.last_changed[] = time()
    return old_v
end

"""
    set!(m::NumericMetric, v::Float64)

Sets the current value of numeric metric `m` to `v`.
"""
function set!(m::NumericMetric, v::Float64)
    old_v = Base.Threads.atomic_xchg!(m.value, v)
    m.last_changed[] = time()
    return old_v
end

"""
    set_max!(m::NumericMetric, v::Float64)

Sets the current value of NumericMetric `m` to `v` but only if the new value is greater
than the current value. This enforces counter monotonicity but allows for exposing things
that are already "tracked as a counter" internally and for which we do not have direct
access to increments (e.g. gc allocation counts).
"""
function set_max!(m::NumericMetric, v::Float64)
    old_v = Base.Threads.atomic_max!(m.value, v)
    if old_v < v
        m.last_changed[] = time()
    end
    return old_v
end

zero_metric!(m::NumericMetric) = m.value[] = 0.0

function get_cell!(m::NumericMetric; labels...)
    if length(labels) > 0
        return DummyCell(m, labels)
    end
    return m
end

get_cell_if_exists(m::NumericMetric; labels...) = isempty(labels) ? m : nothing

# This represents invalid cell and is passed to inc!, dec!, set! functions to trigger
# errors to be logged instead of exceptions being thrown.
struct DummyCell <: MetricValueContainer
    associated_with::MetricValueContainer
    label_assignments::Dict{Symbol,Any}
end

function log_invalid_metric_usage(m::DummyCell, fn::String)
    # TODO(janrous): this should throw an exception in test environment and use @error
    # logging in production. A more detailed reason why the access is invalid (e.g.
    # type error, unknown labels or missing labels) could be emitted here to make debugging
    # A problem with each label can be either: 1. wrong type, 2. unknown label, 3. missing
    assigned_labels = Set(keys(m.label_assignments))
    unknown_labels = setdiff(assigned_labels, m.associated_with.labels)
    missing_labels = setdiff(m.associated_with.labels, assigned_labels)
    @error "$fn($(m.associated_with.name[]); invalid labels. Missing: $missing_labels, Uknown: $unknown_labels."
end

inc!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "inc!")
dec!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "dec!")
set!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "set!")
set_counter!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "set_counter!")

