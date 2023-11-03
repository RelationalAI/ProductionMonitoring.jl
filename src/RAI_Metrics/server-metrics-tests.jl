@testitem "server metrics" begin

import Logging
using ProductionMonitoring.RAI_Metrics

using Sockets
using Dates
using ProductionMonitoring.RAI_Metrics: AbstractMetric, NumericMetric, MetricGroup
using ProductionMonitoring.RAI_Metrics: register!, unregister!, clear_registry!
using ProductionMonitoring.RAI_Metrics: get_metric, set_counter!
using ProductionMonitoring.RAI_Metrics: get_cells
using DataStructures: SortedDict
using ProductionMonitoring.DebugLevels

get_cell_values(m) = Dict(cell.labels => cell.value[] for cell in get_cells(m))
metric_values(m::NumericMetric) = m.value[]
metric_values(m::MetricGroup) = Dict(k => v.value[] for (k, v) in m.cells)
metric_values(m::AbstractMetric) = metric_values(m.content)
is_dummy(x) = isa(x, RAI_Metrics.DummyCell)

@testset "get_cell! with invalid labels" begin
    cnt::Counter = Counter(;labels=[:action, :code])
    @test is_dummy(RAI_Metrics.get_cell!(cnt; action="get"))
    @test is_dummy(RAI_Metrics.get_cell!(cnt; action="get", code=200, unknown="foo"))
end

@testset "get_cell_if_exists does not create new cells" begin
    cnt::Counter = Counter(;labels=[:day])
    @test RAI_Metrics.get_cell_if_exists(cnt; day="Monday") == nothing
    @test metric_values(cnt) == Dict()

    @test RAI_Metrics.get_cell!(cnt; day="Monday") isa NumericMetric
    @test RAI_Metrics.get_cell_if_exists(cnt; day="Monday") isa NumericMetric
    @test metric_values(cnt) == Dict(Dict(:day => "Monday") => 0.0)
end

@testset "Invalid access is ignored" begin
    cnt::Counter = Counter(;labels=[:action])
    inc!(cnt; action="get")
    inc!(cnt; unknown=nothing) # This is invalid
    inc!(cnt; action="put", mystery=1) # This is invalid
    inc!(cnt) # This is also invalid (missing action label)
    @test metric_values(cnt) == Dict(
        Dict(:action => "get") => 1.0
    )
end

@testset "get_cell! for singular counter" begin
    cnt::Counter = Counter()
    @test is_dummy(RAI_Metrics.get_cell!(cnt; label=10))
    @test RAI_Metrics.get_cell_if_exists(cnt; label=10) == nothing
    @test RAI_Metrics.get_cell_if_exists(cnt) == cnt.content
    @test RAI_Metrics.get_cell!(cnt) == cnt.content
end

@testset "get_cell with Counter" begin
    cnt::Counter = Counter(;labels=[:action, :code])
    @test metric_values(cnt) == Dict()

    @test RAI_Metrics.get_cell!(cnt; action="get", code=200) isa NumericMetric
    @test metric_values(cnt) == Dict(
        Dict(:action => "get", :code => "200") => 0.0,
    )

    RAI_Metrics.get_cell!(cnt; action="get", code=500)
    RAI_Metrics.get_cell!(cnt; action="put", code=200)
    @test metric_values(cnt) == Dict(
        Dict(:action => "get", :code => "200") => 0.0,
        Dict(:action => "get", :code => "500") => 0.0,
        Dict(:action => "put", :code => "200") => 0.0,
    )
end

@testset "Counter with labels " begin
    c::Counter = Counter(;labels=[:action, :response_code])
    inc!(c; action="get", response_code=404)
    inc!(c; action="put", response_code=200)
    inc!(c, 2.0; action="get", response_code=404)

    @test metric_values(c) == Dict(
        Dict(:action => "get", :response_code => "404") => 3.0,
        Dict(:action => "put", :response_code => "200") => 1.0,
    )
end

@testset "Gauge with labels" begin
    g::Gauge = Gauge(;labels=[:resource])
    set!(g, 20.0; resource="disk")
    inc!(g; resource="disk")
    dec!(g, 5.0; resource="water_level")
    inc!(g, 2.0; resource="water_level")
    @test metric_values(g) == Dict(
        Dict(:resource => "disk") => 21.0,
        Dict(:resource => "water_level") => -3.0,
    )
end

@testset "Counter with no labels has one cell" begin
    c::Counter = Counter()
    @test length(get_cells(c)) == 1
    inc!(c, 2.5)
    @test metric_values(c) == 2.5
end

@testset "Simple counter manipulations" begin
    c = RAI_Metrics.Counter()
    @test metric_values(c) == 0.0
    inc!(c)
    @test metric_values(c) == 1.0
    inc!(c, 2)
    @test metric_values(c) == 3.0

    # Incrementing by negative value is logged and ignored
    inc!(c, -1.0)
    @test metric_values(c) == 3.0
end


@testset "Manual set counter" begin
    c = RAI_Metrics.Counter()
    @test metric_values(c) == 0.0
    inc!(c)
    @test metric_values(c) == 1.0
    set_counter!(c, 5.0)
    @test metric_values(c) == 5.0
    inc!(c)
    @test metric_values(c) == 6.0
end

@testset "Gauge constructors" begin
    g1 = RAI_Metrics.Gauge()
    @test metric_values(g1) == 0.0

    g2 = RAI_Metrics.Gauge(10.0)
    @test metric_values(g2) == 10.0
end

@testset "Simple gauge manipulations" begin
    g = RAI_Metrics.Gauge()
    @test metric_values(g) == 0.0
    inc!(g)
    @test metric_values(g) == 1.0
    inc!(g, 2)
    @test metric_values(g) == 3.0

    inc!(g, -1.0)
    @test metric_values(g) == 3.0

    dec!(g, -1.0)
    @test metric_values(g) == 3.0
    # TODO(janrous): Perhaps we might consider chg!(g, v) which will
    # inc! or dec! based on the sign?
end

@testset "Registry enforces unique names" begin
    r = RAI_Metrics.MetricRegistry()
    c1 = RAI_Metrics.Counter()
    register!(r, c1, "first_name")
    c2 = RAI_Metrics.Counter()
    register!(r, c2, "second_name")
    @test RAI_Metrics.name(c1) == "first_name"
    @test RAI_Metrics.name(c2) == "second_name"
    c3 = RAI_Metrics.Counter()
    @test_throws KeyError register!(r, c3, "first_name")
    @test RAI_Metrics.name(c3) == nothing
end

@testset "Once registered, name remains fixed" begin
    r = RAI_Metrics.MetricRegistry()
    c = RAI_Metrics.Counter()
    @test RAI_Metrics.name(c) === nothing
    register!(r, c, "my_name")
    @test RAI_Metrics.name(c) == "my_name"
    unregister!(r, "my_name")
    @test RAI_Metrics.name(c) == "my_name"
end

@testset "overwriting existing metrics" begin
    r = RAI_Metrics.MetricRegistry()
    c1 = RAI_Metrics.Counter()
    c2 = RAI_Metrics.Counter()
    c3 = RAI_Metrics.Counter()
    register!(r, c1, "first_name")
    @test_throws KeyError register!(r, c2, "first_name")
    @test get_metric(r, "first_name") == c1
    # (Doesn't log anything because the verbosity level is too low)
    @test_logs register!(r, c2, "first_name"; overwrite=true)
    @test get_metric(r, "first_name") == c2

    # If we enable higher verbosity logging, register! now warns about overwritten metrics
    verbosity2 = LogConfig(log = Logging.Info, verbosity = 2)
    set_log_level_defaults(verbosity2)
    @test_logs (:warn,) register!(r, c3, "first_name"; overwrite=true)
    @test get_metric(r, "first_name") == c3
end

# Returns sorted Array of metric names registered within given registry.
list_metrics(r::RAI_Metrics.MetricRegistry) = sort(collect(keys(r.metrics)))


# Uniqueness of metric name is enforced within a single registry. Two registries
# can have metric with the same name.
@testset "Metrics unique within registry" begin
    r1 = RAI_Metrics.MetricRegistry()
    r2 = RAI_Metrics.MetricRegistry()
    g1 = RAI_Metrics.Gauge(1.0)
    g2 = RAI_Metrics.Gauge(3.0)
    register!(r1, g1, "unique")
    register!(r2, g2, "unique")
    @test list_metrics(r1) == ["unique"]
    @test list_metrics(r2) == ["unique"]
    @test metric_values(get_metric(r1, "unique")) == 1.0
    @test metric_values(get_metric(r2, "unique")) == 3.0
end

# Single metric can only be registered once.
@testset "Name constraints on metrics are enforced" begin
    r1 = RAI_Metrics.MetricRegistry()
    r2 = RAI_Metrics.MetricRegistry()
    c = RAI_Metrics.Counter()
    register!(r1, c, "my_counter")

    # Registering under the same name twice is okay
    @test_logs register!(r2, c, "my_counter")

    # Registering under different name is not okay
    @test_throws AssertionError register!(r2, c, "my_counter_2")
end

@testset "Multiple registration with same name okay" begin
    r1 = RAI_Metrics.MetricRegistry()
    r2 = RAI_Metrics.MetricRegistry()
    c = RAI_Metrics.Counter()
    register!(r1, c, "my_counter")
    @test_logs register!(r2, c, "my_counter")
end


# Metric could be registered sequentially in two registries if it's unregistered from one.
@testset "Sequential multiple registration" begin
    r1 = RAI_Metrics.MetricRegistry()
    r2 = RAI_Metrics.MetricRegistry()
    c = RAI_Metrics.Counter()
    register!(r1, c, "my_counter")
    unregister!(r1, "my_counter")
    register!(r2, c, "my_counter")
    @test list_metrics(r1) == []
    @test list_metrics(r2) == ["my_counter"]
end

@testset "Metric name length enforced" begin
    @test_throws ArgumentError register!(
        MetricRegistry(),
        RAI_Metrics.Counter(),
        "c"^201
    )
end

@testset "Metric name validation" begin
    r = MetricRegistry()
    c = RAI_Metrics.Counter()
    @test_throws ArgumentError register!(r, c, "hyphens-not-permitted")
    @test_throws ArgumentError register!(r, c, ".tralala")
    @test_throws ArgumentError register!(r, c, "2tralala")
    @test_throws ArgumentError register!(r, c, "tra\\lala")
    @test_throws ArgumentError register!(r, c, "t,r()a22ala")
    @test_throws ArgumentError register!(r, c, "prometheus.dislikes.this")
end

# Turn Dict keys into Return sorted array of keys from Dict
key_set(d::SortedDict) = Set([first(kv) for kv in d])

Base.@kwdef struct ThreeMetrics <: AbstractMetricCollection
    a::Counter = Counter()
    b::Counter = Counter()
    c::Gauge = Gauge(5.0)
end

Base.@kwdef struct CounterAndTwoGauges <: AbstractMetricCollection
    c::Counter = Counter()
    g1::Gauge = Gauge()
    g2::Gauge = Gauge()
end

Base.@kwdef struct CounterAndGauge <: AbstractMetricCollection
    c::Counter = Counter()
    g::Gauge = Gauge()
end

@testset "Int64 counter manipulations" begin
    c::Counter = Counter()
    inc!(c, 2)
    @test metric_values(c) == 2.0
end

@testset "Int64 gauge manipulations" begin
    g::Gauge = Gauge(0)

    inc!(g, 1)
    @test metric_values(g) == 1.0

    dec!(g, 2)
    @test metric_values(g) == -1.0

    set!(g, 5)
    @test metric_values(g) == 5.0
end

@testset "Unregister from registry" begin
    r = MetricRegistry()
    @test list_metrics(r) == []
    register!(r, Counter(), "aaa")
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["aaa", "bbb"]
    @test_throws KeyError unregister!(r, "nonexistent")
    unregister!(r, "aaa")
    @test list_metrics(r) == ["bbb"]
    unregister!(r, "bbb")
    @test list_metrics(r) == []
end

@testset "Clear registry" begin
    r = MetricRegistry()
    @test list_metrics(r) == []
    clear_registry!(r)
    @test list_metrics(r) == []
    register!(r, Counter(), "aaa")
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["aaa", "bbb"]
    clear_registry!(r)
    @test list_metrics(r) == []
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["bbb"]
end

Base.@kwdef struct MixedMetrics <: AbstractMetricCollection
    my_counter::Counter = Counter()
    my_gauge::Gauge = Gauge()

    other_stuff::String = "default_value"
    anything::Any = nothing
end

@testset "Collection with nonmetric fields" begin
    r = MetricRegistry(MixedMetrics())
    @test list_metrics(r) == ["my_counter", "my_gauge"]
end

Base.@kwdef struct ArbitraryStruct
    my_counter_1::Counter = Counter()
    name::String = "String thingy"
end

@testset "Collection of any type" begin
    r = MetricRegistry(ArbitraryStruct())
    @test list_metrics(r) == ["my_counter_1"]
end

Base.@kwdef struct FirstGroup <: AbstractMetricCollection
    first_counter::Counter = Counter()
    first_gauge::Gauge = Gauge()
end

Base.@kwdef struct SecondGroup <: AbstractMetricCollection
    second_counter::Counter = Counter()
    second_gauge::Gauge = Gauge()
end

@testset "Register non-overlapping collections" begin
    first_group = FirstGroup()
    second_group = SecondGroup()
    r = MetricRegistry()

    @test list_metrics(r) == []

    register_collection!(r, first_group)
    @test list_metrics(r) == ["first_counter", "first_gauge"]

    register_collection!(r, second_group)
    @test list_metrics(r) == ["first_counter", "first_gauge", "second_counter", "second_gauge"]
end

@testset "MAX_CELLS_PER_METRIC triggers" begin
    cnt::Counter = Counter(;labels=[:order])
    for i in 1:205
        inc!(cnt, i; order=i)
    end
    # only the last 200 cells should be present. Timestmaps may not change fast enough
    # to ensure that LRU will behave in a stable manner.
    @test length(metric_values(cnt)) == 200
end

@testset "Zero all metrics" begin
    r = MetricRegistry()
    c = register!(r, RAI_Metrics.Counter(;labels=[:my_label]), "my_counter")
    g = register!(r, RAI_Metrics.Gauge(), "my_gauge")
    c_free = RAI_Metrics.Counter()

    inc!(c, 2.0; my_label="green")
    set!(g, 5.0)
    inc!(c_free)

    @test RAI_Metrics.value_of(r, "my_counter"; my_label="green") == 2.0
    @test metric_values(g) == 5.0
    @test metric_values(c_free) == 1.0

    RAI_Metrics.zero_all_metrics(r)

    @test RAI_Metrics.value_of(r, "my_counter"; my_label="green") == 0.0
    @test metric_values(g) == 0.0
    @test metric_values(c_free) == 1.0
end

@testset "value_of for simple metrics" begin
    r = MetricRegistry()
    c = register!(r, RAI_Metrics.Counter(), "my_counter")
    g = register!(r, RAI_Metrics.Gauge(), "my_gauge")
    inc!(c)
    set!(g, 50)
    @test RAI_Metrics.value_of(r, "my_counter") == 1.0
    @test RAI_Metrics.value_of(r, "my_gauge") == 50.0
    @test RAI_Metrics.value_of(r, "unknown") == nothing
end

@testset "value_of for labelled metrics" begin
    r = MetricRegistry()
    c = register!(r, RAI_Metrics.Counter(;labels=[:response_code, :action]), "my_counter")
    inc!(c; action="GET", response_code=200)
    inc!(c; action="PUT")  # This inc! is invalid due to bad labels and should be silently ignored.

    # The following doesn't work because all labels are missing.
    @test RAI_Metrics.value_of(r, "my_counter") == nothing

    # The following doesn't work because unknown "badlabel" is present.
    @test RAI_Metrics.value_of(r, "my_counter"; action="GET", response_code=200, badlabel=1) == nothing

    # The following doesn't work because "response_code" label is missing.
    @test RAI_Metrics.value_of(r, "my_counter"; action="PUT") == nothing

    # The following works and refers to the cell created above.
    @test RAI_Metrics.value_of(r, "my_counter"; action="GET", response_code=200) == 1.0
end

end # testitem
