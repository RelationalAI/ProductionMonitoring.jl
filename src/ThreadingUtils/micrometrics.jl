# Lightweight metrics for performance tuning and analysis
#
# Basic use:
# const my_metric = Micrometric(:my_metric)
#
# For measuring an operation that takes a certain amount of time, and you want to
# be able to report how many of those operations are "in flight" at a given time:
# @metric my_metric do_the_thing()
#
# If you want something like @metric but reporting a specific quantity (e.g. number
# of bytes being written to disk), use metric_enter(metric, qty) and
# metric_exit(metric, qty).
#
# For a metric that should be updated instantaneously e.g. a hard page fault,
# use metric_add(metric, qty).
using Printf
using Dates
using CPUTime

mutable struct Micrometric
    name::Symbol
    count_in::Threads.Atomic{Int}
    count_out::Threads.Atomic{Int}

    # For reporting purposes
    lock::ReentrantLock
    prev_t::Float64
    prev_count_in::Int
    prev_count_out::Int
    registered::Bool
end

mutable struct MicrometricManager
    lock::ReentrantLock
    metrics::Vector{Micrometric}
end

function MicrometricManager()
    mm = MicrometricManager(ReentrantLock(), Micrometric[])
    # The theory was that this commented-out line would ensure that metrics are reported
    # every two seconds, but I could never get it to work properly.
    # @spawn_sticky_periodic_task "ThreadingUtils.MicrometricManager" Dates.Second(2) mm_thread()
    return mm
end

function Micrometric(name::Symbol)
    return Micrometric(
        name,
        Threads.Atomic{Int}(0),
        Threads.Atomic{Int}(0),
        ReentrantLock(),
        time(),
        0,
        0,
        false
    )
end

# Standard metrics
const m_cpu_usertime_ns = Micrometric(:m_cpu_usertime_ns)
const m_gctime_ns = Micrometric(:m_gctime_ns)

# Reporting mechanism. Every call to metric_exit() does a quick check of whether
# we should dump a report. Currently this defaults to once every two seconds.
const report_tick = Threads.Atomic{Int}(0)
const last_report_time = Threads.Atomic{Float64}(time())
const metric_reporting_enabled = Threads.Atomic{Bool}(false)

function _quick_maybe_report_metrics()
    pc = Threads.atomic_add!(report_tick, 1)
    if mod(pc, 1024) != 0
        return nothing
    end
    _maybe_report_metrics()
    return nothing
end

function _maybe_report_metrics()
    global metric_manager
    t = time()
    prev_t = last_report_time[]

    # Report metrics every two seconds
    if t - prev_t > 2.0
        old_val = Threads.atomic_cas!(last_report_time, prev_t, t)
        if old_val == prev_t
            (!metric_reporting_enabled[]) && return nothing
            report_metrics()
        end
    end
    return nothing
end

function report_metrics()
    @lock metric_manager[].lock begin
        # Update cpu user time
        usertime_ns = 1000*Int(CPUTime.CPUtime_us())
        m_cpu_usertime_ns.count_in[] = usertime_ns
        m_cpu_usertime_ns.count_out[] = usertime_ns

        # Update garbage collection time
        gctime_ns = Base.gc_num().total_time
        m_gctime_ns.count_in[] = gctime_ns
        m_gctime_ns.count_out[] = gctime_ns

        timestamp = time()
        io = IOBuffer()
        if length(metric_manager[].metrics) > 0
            println(io, "")
        end
        println(io, "MicrometricManager@$(repr(objectid(metric_manager[]))) reporting $(length(metric_manager[].metrics)) metrics")
        for metric in metric_manager[].metrics
            report(io, timestamp, metric)
        end
        report(io, timestamp, m_cpu_usertime_ns)
        report(io, timestamp, m_gctime_ns)
        @info String(take!(io))
    end
    return nothing
end

# If false, we won't report metrics that haven't changed
const always_report = true

function report(io::IOBuffer, timestamp::Float64, m::Micrometric)
    @lock m.lock begin
        count_in = m.count_in[]
        count_out = m.count_out[]
        if always_report || count_in != m.prev_count_in || count_out != m.prev_count_out
            t = time()
            delta_t = t - m.prev_t
            stamp = @sprintf "%.9lf" timestamp
            label = @sprintf "%40s" m.name
            in_flight = @sprintf "%12d" (count_in-count_out)
            entry_rate = @sprintf "%13.1f/s" (count_in-m.prev_count_in)/delta_t
            exit_rate = @sprintf "%13.1f/s" (count_out-m.prev_count_out)/delta_t
            println(io, "#@ $(stamp) $(label): $(in_flight) ✈    $(entry_rate) ↑     $(exit_rate) ↓     Σ $(count_out)")
            m.prev_count_in = count_in
            m.prev_count_out = count_out
            m.prev_t = t
        end
    end
end

function _maybe_register(metric::Micrometric)
    if !metric.registered
        metric.registered = true
        @lock metric_manager[].lock begin
            push!(metric_manager[].metrics, metric)
        end
    end
end

function metric_enter(metric::Micrometric, qty=1)
    _maybe_register(metric)
    Threads.atomic_add!(metric.count_in, qty)
end

function metric_exit(metric::Micrometric, qty=1)
    _maybe_register(metric)
    Threads.atomic_add!(metric.count_out, qty)
    _quick_maybe_report_metrics()
    nothing
end

function metric_add(metric::Micrometric, qty)
    _maybe_register(metric)
    Threads.atomic_add!(metric.count_in, qty)
    Threads.atomic_add!(metric.count_out, qty)
    _quick_maybe_report_metrics()
    nothing
end

macro metric(m, expr)
    quote
        temp = $(esc(m))
        metric_enter(temp)
        try
            $(esc(expr))
        finally
            metric_exit(temp)
        end
    end
end

const metric_manager = Ref{Union{Nothing,MicrometricManager}}(nothing)
