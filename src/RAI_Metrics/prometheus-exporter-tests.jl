@testitem "Simple counter" begin
    using ProductionMonitoring.RAI_Metrics
    using ProductionMonitoring.RAI_Metrics: register!, clear_registry!
    clear_registry!(get_default_registry())
    c = register!(Counter(), "my_counter")
    inc!(c, 2.0)

    resp = handle_metrics(nothing)
    @test String(resp.body) == """
    # TYPE my_counter counter
    my_counter 2.0

    """

    inc!(c, 3.0)
    resp = handle_metrics(nothing)
    @test String(resp.body) == """
    # TYPE my_counter counter
    my_counter 5.0

    """
end

@testitem "Simple gauge" begin
    using ProductionMonitoring.RAI_Metrics
    using ProductionMonitoring.RAI_Metrics: register!, clear_registry!
    clear_registry!(get_default_registry())
    g = register!(Gauge(1.5), "my_gauge")
    resp = handle_metrics(nothing)

    @test String(resp.body) == """
    # TYPE my_gauge gauge
    my_gauge 1.5

    """
end

@testitem "Counter with labels" begin
    using ProductionMonitoring.RAI_Metrics
    using ProductionMonitoring.RAI_Metrics: register!, clear_registry!
    clear_registry!(get_default_registry())
    c = register!(Counter(;labels=[:action, :response_code]), "requests")
    inc!(c; action="get", response_code=404)
    inc!(c; action="put", response_code=500)  # What a bad day for prod :-(
    resp = handle_metrics(nothing)

    @test String(resp.body) == """
    # TYPE requests counter
    requests{action="get",response_code="404"} 1.0
    requests{action="put",response_code="500"} 1.0

    """
end

@testitem "Gauge with labels" begin
    using ProductionMonitoring.RAI_Metrics
    using ProductionMonitoring.RAI_Metrics: register!, clear_registry!
    clear_registry!(get_default_registry())
    temp = register!(Gauge(;labels=[:location, :hour]), "temperature")
    set!(temp, 36.0; location="outside", hour=6)
    set!(temp, 40.0; location="outside", hour=8)
    set!(temp, 60.0; location="inside", hour=8)
    resp = handle_metrics(nothing)

    @test String(resp.body) == """
    # TYPE temperature gauge
    temperature{hour="6",location="outside"} 36.0
    temperature{hour="8",location="inside"} 60.0
    temperature{hour="8",location="outside"} 40.0

    """
end

@testitem "Exported metrics are sorted" begin
    using ProductionMonitoring.RAI_Metrics
    using ProductionMonitoring.RAI_Metrics: register!, clear_registry!
    clear_registry!(get_default_registry())
    bbb = register!(Counter(), "bbb")
    zzz = register!(Gauge(0.2), "zzz")
    aaa = register!(Counter(), "aaa")
    resp = handle_metrics(nothing)

    @test String(resp.body) == """
    # TYPE aaa counter
    aaa 0.0

    # TYPE bbb counter
    bbb 0.0

    # TYPE zzz gauge
    zzz 0.2

    """
end
