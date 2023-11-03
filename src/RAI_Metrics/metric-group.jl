const MAX_CELLS_PER_METRIC = 200

const LabelArguments = Base.Pairs

# TODO(janrous): MetricGroup{T} currently supports arbitrary symbols for label
# names and arbitrary types for label values. We might want to enforce some
# stricter rules for MetricGroup{T} that will be registered and exported.

# TODO(janrous): we often want to have Union{AbstractMetric,MetricGroup} which
# could be achieved by having SingularMetric <: AbstractMetric

# Collection of NumericMetrics, organized by label names.
struct MetricGroup <: MetricValueContainer
    # Synchronizes access to cells
    lock::ReentrantLock

    # cells contain individual NumericMetricCells, keys are Dict(:label => String(value)).
    cells::Dict{MetricLabels,NumericMetric}

    # Set of all label names associated with this metric.
    labels::Set{Symbol}

    # A cache of mappings from labels pairs to actual MetricLabels, to avoid excessive calls to
    # make_cell_key.
    keys::Dict{LabelArguments,MetricLabels}

    # Lock on the key cache.
    keys_lock::ReentrantLock

    # This holds name of the metric once registered.
    name::OptionalStringRef

    default_value::Float64

    function MetricGroup(;
        default_value::Float64 = 0.0,
        labels::AbstractVector{Symbol}=Vector{Symbol}()
    )
        # Label name correctness is asserted at registration time and not here.
        return new(
            ReentrantLock(),
            Dict(),
            Set{Symbol}(labels),
            Dict(),
            ReentrantLock(),
            nothing,
            default_value,
        )
    end
end

dimension(mg::MetricGroup) = length(mg.labels)

# Returns true if labels assign value of correct type to all known labels of `mg`.
"""labels_are_valid returns True iff labels exactly match those expected by `mg`."""
labels_are_valid(mg::MetricGroup, labels) = issetequal(Set(keys(labels)), mg.labels)
make_cell_key(labels) = MetricLabels(k => string(v) for (k, v) in labels)
make_cell_key(;labels...) = make_cell_key(labels)

# This function ensures that MetricGroup has no more than MAX_CELLS_PER_METRIC at all
# times by removing the least recently used cell (skipping the req_cell to ensure safe return).
function _maintain_cell_limits(mg::MetricGroup, req_cell::MetricValueContainer)
    if length(mg.cells) <= MAX_CELLS_PER_METRIC
        return nothing
    end
    # Finding LRU cell is O(MAX_CELLS_PER_METRICS). If this ever becomes performance
    # bottleneck, we might consider semi-random strategy. However, we should not be
    # really hitting this limit anyways if we use metrics in a reasonable manner.
    @warn "Metric $(mg.name[]) has too many cells. Discarding oldest cell."
    local lru_timestamp = nothing
    local lru_cell_key = nothing
    local lru_cell_label = nothing
    Base.@lock mg.keys_lock begin
        for (cell_label, cell_key) in mg.keys
            cell = mg.cells[cell_key]
            cell == req_cell && continue  # Do not discard the newly created/requested cell.
            if lru_timestamp === nothing || lru_timestamp > cell.last_changed[]
                lru_timestamp = cell.last_changed[]
                lru_cell_key = cell_key
                lru_cell_label = cell_label
            end
        end
        if lru_cell_key !== nothing
            delete!(mg.cells, lru_cell_key)
            delete!(mg.keys, lru_cell_label)
        end
    end
end

function _get_cell_key(
    mg::MetricGroup,
    key::Union{MetricLabels,Nothing},
    labels::LabelArguments,
)
    key != nothing && return key
    Base.@lock mg.keys_lock begin
        get!(
            () -> begin
                if !labels_are_valid(mg, labels)
                    throw(KeyError("invalid labels for group cell"))
                end
                make_cell_key(labels)
            end,
            mg.keys,
            labels,
        )
    end
end

function get_cell!(mg::MetricGroup; key=nothing, labels...)
    cell_key = try
        _get_cell_key(mg, key, labels)
    catch e
        return DummyCell(mg, labels)
    end
    Base.@lock mg.lock begin
        # Retrieve cell or construct new one if this doesn't exist.
        return_cell = get!(mg.cells, cell_key) do
            # TODO(janrous): simplify by having value, name, labels constructor for NumericMetric
            new_cell = NumericMetric(mg.default_value)
            new_cell.name = mg.name[]
            new_cell.labels = cell_key
            mg.cells[cell_key] = new_cell
            return new_cell
        end
        _maintain_cell_limits(mg, return_cell)
        return return_cell
    end
end

function get_cell_if_exists(mg::MetricGroup; key=nothing, labels...)
    cell_key = try
        _get_cell_key(mg, key, labels)
    catch e
        return nothing
    end

    Base.@lock mg.lock begin
        return get(mg.cells, cell_key, nothing)
    end
end

_get_cells(content::MetricGroup) = collect(values(content.cells))

# inc!, dec! and set! on MetricGroup dispatch the call to the right cell
inc!(mg::MetricGroup, v::Float64; labels...) = inc!(get_cell!(mg; labels...), v)
dec!(mg::MetricGroup, v::Float64; labels...) = dec!(get_cell!(mg; labels...), v)
set!(mg::MetricGroup, v::Float64; labels...) = set!(get_cell!(mg; labels...), v)
set_counter!(mg::MetricGroup, v::Float64; lbl...) = set_counter!(get_cell!(mg; lbl...), v)
set_max!(mg::MetricGroup, v::Float64; lbl...) = set_max!(get_cell!(mg; lbl...), v)

"""
    validate_metric_labels(m::AbstractMetric)

Verifies that all metric label names meet prometheus and statsd requirements.
This effectively calls `validate_metric_name` on all label names and throws exceptions if
the requirements are not met.
"""
function validate_metric_labels(mg::MetricGroup)
    for label_name in mg.labels
        validate_metric_name(String(label_name))
    end
    return nothing
end

zero_metric!(mg::MetricGroup) = foreach(m -> zero_metric!(m), values(mg.cells))
