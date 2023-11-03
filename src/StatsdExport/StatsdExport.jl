module StatsdExport

import Dates
using Dates: now, Period, Millisecond, Second
using ProductionMonitoring.Metrics
using ProductionMonitoring.Metrics: NumericMetric
using Sockets
using ProductionMonitoring.ThreadingUtils: PeriodicTask, @spawn_interactive_periodic_task, stop_periodic_task!

# Environment variable names for configuring dogstatsd backend.
const ENV_DD_DOGSTATSD_HOST = "DD_DOGSTATSD_HOST"
const ENV_DD_DOGSTATSD_PORT = "DD_DOGSTATSD_PORT"
const ENV_DD_DOGSTATSD_URL = "DD_DOGSTATSD_URL"
const DEFAULT_DOGSTATSD_HOST = "127.0.0.1"
const DEFAULT_DOGSTATSD_PORT = "8125"

abstract type AbstractServiceBackend end

struct UDPBackend <: AbstractServiceBackend
    server_address::IPAddr
    server_port::Int
    socket::UDPSocket
    UDPBackend(ip::IPAddr, port::Int) = new(ip, port, UDPSocket())
end
UDPBackend(ip::String,port::Int) = UDPBackend(getaddrinfo(ip), port)

function Base.show(io::IO, udp::UDPBackend)
    print(io, "udp://$(udp.server_address):$(udp.server_port)")
end

# Sockets.send may cause crash in multi-threaded environment if multiple threads are trying
# to use the same underlying socket.
# This method is not thread-safe and callers are responsible for ensuring proper
# synchronization.
send(be::UDPBackend, msg::String) = Sockets.send(be.socket, be.server_address, be.server_port, msg)

"""Return statsd backend based on the ENV configuration variables."""
function DefaultStatsdBackend()
    host = get(ENV, ENV_DD_DOGSTATSD_HOST, DEFAULT_DOGSTATSD_HOST)
    port = get(ENV, ENV_DD_DOGSTATSD_PORT, DEFAULT_DOGSTATSD_PORT)
    if haskey(ENV, ENV_DD_DOGSTATSD_URL)
        dd_url = ENV[ENV_DD_DOGSTATSD_URL]
        throw(ErrorException("$ENV_DD_DOGSTATSD_URL ENV variable not supported yet."))
        # TODO(janrous): implement support for this, ignore until now
        # assume form of udp://host:port.
    end
    addr = getaddrinfo(host)
    return UDPBackend(addr, parse(Int, port))
end

# Statsd exporter will emit metrics about its own operation.
Base.@kwdef struct StatsdMetrics <: AbstractMetricCollection
    statsd_exporter_packets_sent_total::Counter = Counter()
    statsd_exporter_emission_lag_ms_total::Counter = Counter()
    statsd_exporter_emission_duration_ms_total::Counter = Counter()
end

const metrics = StatsdMetrics()

function __init__()
    publish_metrics_from(metrics)
end

Base.@kwdef mutable struct StatsdExporter
    # How often we should be sending metric updates to statds backend.
    send_interval::Period = Second(60)

    # Emit metrics that have not seen update in the last send_older_than period.
    send_older_than::Period = Second(120)

    # Backend that should receive statds messages.
    statsd_backend::AbstractServiceBackend = DefaultStatsdBackend()

    # Set of registries to pull the metrics from.
    metric_registries::Set{MetricRegistry} = Set{MetricRegistry}([get_default_registry()])

    # Timestamp of the last emission in seconds since epoch UTC (as per `Base.time()`).
    last_emission_timestamp::Float64 = 0.0

    # PeriodicTask in charge of exporting metrics to statsd every `send_interval`
    periodic_task::Union{Nothing,PeriodicTask} = nothing
end

# Stops the background thread.
"""
    stop_statsd_exporter!(data::StatsdExporter)

Stops the currently running exporter thread (if it exists) and clears `data.exporter_thread`
"""
function stop_statsd_exporter!(data::StatsdExporter)
    if data.periodic_task !== nothing
        t = stop_periodic_task!(data.periodic_task)
        data.periodic_task = nothing
        return t
    else
        return nothing
    end
end

"""
    start_statsd_exporter!(data::StatsdExporter)

Starts background statsd exporter thread if `data.send_interval` is positive. This
background thread will be stored in `data.exporter_thread`.
"""
function start_statsd_exporter!(data::StatsdExporter)
    if Dates.value(data.send_interval) > 0
        data.periodic_task = @spawn_interactive_periodic_task(
            "StatsdExporter",
            data.send_interval,
            send_metric_updates(data),
            send_metric_updates(data)
        )
        @info "Started statsd exporter connected to $(data.statsd_backend)"
    else
        @warn "Metric emission interval set to 0. Emission thread not enabled."
    end
end

function make_label_string(m::NumericMetric)
    if isempty(m.labels)
        return ""
    else
        # TODO(janrous): How can we ensure that labels are exported in
        # a stable order (for the purpose of testing).
        tag_string = join(["$k:$v" for (k, v) in m.labels], ",")
        return "|#$tag_string"
    end
end

function value_change!(m::Counter, cell::NumericMetric)
    new_value = cell.value[]
    old_value = get(m.last_emitted_values, cell.labels, 0.0)
    m.last_emitted_values[cell.labels] = new_value
    return new_value - old_value
end

function make_statsd_message(m::Counter, cell::NumericMetric)
    return "$(Metrics.name(m)):$(value_change!(m, cell))|c$(make_label_string(cell))"
end

function make_statsd_message(m::Gauge, cell::NumericMetric)
    return "$(Metrics.name(m)):$(cell.value[])|g$(make_label_string(cell))"
end

"""
    send_metric_updates(data::StatsdExporter)

Calculates metric updates that should be sent to statsd backend and sends these to the
configured statsd backend via UDP. Counter will report value changes since the last export
and this "last value" will be updated to reflect the new exported value.
"""
function send_metric_updates(data::StatsdExporter)
    messages = Vector{String}()
    # Seconds since epoch in UTC.
    new_timestamp = time()::Float64
    # TODO(janrous): Should we support disabling send_older_than feature?

    # Returns true if c.last_changed[] is not within the two timestamps
    # [older_than, newer_than].
    should_emit_cell(c) = !(
        new_timestamp - Dates.value(convert(Second, data.send_older_than))
        < c.last_changed[]
        < data.last_emission_timestamp
    )
    emission_duration = Metrics.@time_ms begin
        for reg in data.metric_registries
            for metric in values(reg.metrics)
                for cell in filter(should_emit_cell, Metrics.get_cells(metric))
                    push!(messages, make_statsd_message(metric, cell))
                end
            end
        end
        if data.last_emission_timestamp > 0.0
            emission_lag_ms = Int64(round(
                ((new_timestamp - data.last_emission_timestamp) * 1000.0) -
                Dates.value(convert(Millisecond, data.send_interval))))
            if emission_lag_ms > 0
                inc!(metrics.statsd_exporter_emission_lag_ms_total, emission_lag_ms)
            end
        end
        for msg in messages
            send(data.statsd_backend, msg)
        end
        data.last_emission_timestamp = new_timestamp
    end
    inc!(metrics.statsd_exporter_packets_sent_total, length(messages))
    inc!(metrics.statsd_exporter_emission_duration_ms_total, emission_duration)
    # TODO(janrous): export emission_duration in a latency-tracking metric once available.
end

"""
    export_metrics_from_registry!(data::StatsdExporter, r::MetricRegistry)

Adds the metric registry `r` to the statsd exporter. This ensures that the metrics contained
within the registry will be shipped to statsd backend.
"""
function export_metrics_from_registry!(data::StatsdExporter, r::MetricRegistry)
    push!(data.metric_registries, r)
    return nothing
end

export StatsdExporter, start_statsd_exporter!, stop_statsd_exporter!
export ENV_DD_DOGSTATSD_HOST, ENV_DD_DOGSTATSD_PORT, ENV_DD_DOGSTATSD_URL
export DEFAULT_DOGSTATSD_HOST, DEFAULT_DOGSTATSD_PORT

end # module
