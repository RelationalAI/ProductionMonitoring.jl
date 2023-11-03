@testitem "Default instances have the right values" begin
    using ProductionMonitoring.DebugLevels
    @test TracingConfig() == TracingConfig(TRACING_DEFAULT)
    @test LogConfig() == LogConfig(log = LOG_DEFAULT, verbosity = VERBOSITY_DEFAULT)
end

@testitem "Logging: Module override matching: path-component" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using Logging
    reset_debug_levels!()

    foo = LogConfig(log = Logging.Info, verbosity = 1)
    bar = LogConfig(log = Logging.Warn, verbosity = 2)
    baz = LogConfig(log = Logging.Error, verbosity = 3)

    set_log_level_override("Foo", foo)
    set_log_level_override("Bar", bar)
    set_log_level_override("Baz", baz)

    @test lookup_debug_levels_for(LogConfig, "Foo.Bar.Baz") == baz
    @test lookup_debug_levels_for(LogConfig, "Foo.Bar") == bar
    @test lookup_debug_levels_for(LogConfig, "Foo.Bar.Quack") == bar
    @test lookup_debug_levels_for(LogConfig, "Bar.Foo") == foo
    @test lookup_debug_levels_for(LogConfig, "FooFoo") == LogConfig()
end

@testitem "Tracing: Module override matching: path-component" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()

    foo = TracingConfig(1)
    bar = TracingConfig(2)
    baz = TracingConfig(3)

    set_tracing_level_override("Foo", foo)
    set_tracing_level_override("Bar", bar)
    set_tracing_level_override("Baz", baz)

    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar.Baz") == baz
    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar") == bar
    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar.Quack") == bar
    @test lookup_debug_levels_for(TracingConfig, "Bar.Foo") == foo
    @test lookup_debug_levels_for(TracingConfig, "FooFoo") == TracingConfig()
end

@testitem "Logging: Module override matching: full-path" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using Logging
    reset_debug_levels!()

    foo_bar = LogConfig(log = Logging.Warn, verbosity = 1)
    set_log_level_override("Foo.Bar", foo_bar)

    # This is the only one that matches
    @test lookup_debug_levels_for(LogConfig, "Foo.Bar") == foo_bar
    # Others should not
    @test lookup_debug_levels_for(LogConfig, "Foo.Bar.Baz") == LogConfig()
    @test lookup_debug_levels_for(LogConfig, "Foo") == LogConfig()
    @test lookup_debug_levels_for(LogConfig, "Prefix.Foo.Bar") == LogConfig()
end

@testitem "Tracing: Module override matching: full-path" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()

    foo_bar = TracingConfig(1)
    set_tracing_level_override("Foo.Bar", foo_bar)

    # This is the only one that matches
    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar") == foo_bar
    # Others should not
    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar.Baz") == TracingConfig()
    @test lookup_debug_levels_for(TracingConfig, "Foo") == TracingConfig()
    @test lookup_debug_levels_for(TracingConfig, "Prefix.Foo.Bar") == TracingConfig()
end

@testitem "Logging: Module override matching: order logic" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using Logging
    reset_debug_levels!()

    server = LogConfig(log=Logging.Info, verbosity =1)
    foo_bar_baz = LogConfig(log = Logging.Warn)
    foo = LogConfig(log = Logging.Error, verbosity = 2)

    set_log_level_defaults(server)
    set_log_level_override("Foo.Bar.Baz", foo_bar_baz)
    set_log_level_override("Foo", foo)

    # Verbosity defaults to the static default
    @test lookup_debug_levels_for(LogConfig, "Foo.Bar.Baz") == foo_bar_baz
    @test lookup_debug_levels_for(LogConfig, "Foo.Fum") == foo
    @test lookup_debug_levels_for(LogConfig, "Other.Module") == server
end

@testitem "Tracing: Module override matching: order logic" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()

    server = TracingConfig(1)
    foo_bar_baz = TracingConfig(2)
    foo = TracingConfig(3)

    set_tracing_level_defaults(server)
    set_tracing_level_override("Foo.Bar.Baz", foo_bar_baz)
    set_tracing_level_override("Foo", foo)

    # Verbosity defaults to the static default
    @test lookup_debug_levels_for(TracingConfig, "Foo.Bar.Baz") == foo_bar_baz
    @test lookup_debug_levels_for(TracingConfig, "Foo.Fum") == foo
    @test lookup_debug_levels_for(TracingConfig, "Other.Module") == server
end

@testitem "Default debug levels returned" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()
    @test lookup_debug_levels_for(TracingConfig, "RAICode") == TracingConfig()
    @test lookup_debug_levels_for(LogConfig, "RAICode") == LogConfig()
end

@testitem "Empty debug levels" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()
    @test lookup_debug_levels_for(TracingConfig, "RAICode") == TracingConfig(TRACING_DEFAULT)
    @test lookup_debug_levels_for(LogConfig, "RAICode") == LogConfig(log = LOG_DEFAULT, verbosity = VERBOSITY_DEFAULT)
end

@testitem "Logging: Module disabled" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using Logging
    reset_debug_levels!()
    server = LogConfig(log=Logging.Info, verbosity =1)
    foo = LogConfig(log = Logging.Error, verbosity = 2)

    set_log_level_defaults(server)
    set_log_level_override("Foo", foo)

    # Foo is set
    @test lookup_debug_levels_for(LogConfig, "Foo") == foo

    remove_log_level_override("Foo")

    # Foo is reset, log gets inherited from the sever level
    @test lookup_debug_levels_for(LogConfig, "foo") == server
end

@testitem "Tracing: Module disabled" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    reset_debug_levels!()
    server = TracingConfig(1)
    foo = TracingConfig(2)

    set_tracing_level_defaults(server)
    set_tracing_level_override("Foo", foo)

    # Foo is set
    @test lookup_debug_levels_for(TracingConfig, "Foo") == foo

    remove_tracing_level_override("Foo")

    # Foo is reset, tracing gets inherited from the sever level
    @test lookup_debug_levels_for(TracingConfig, "Foo") == server
end

@testitem "Logging: HTTP /set_log_defaults" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    using Logging
    reset_debug_levels!()

    foo = LogConfig(log = Logging.Debug, verbosity = 1)

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_log_defaults",
            query=Dict(
                "log" => "$(foo.log)",
                "verbosity" => "$(foo.verbosity)",
            ),
        ),
    )

    response = http_set_log_level_defaults(request)

    @test lookup_debug_levels_for(LogConfig, "") == foo
    @test response.status == 200
end

@testitem "Logging: HTTP /set_log_overrides" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    using Logging
    reset_debug_levels!()

    foo = LogConfig(log = Logging.Debug, verbosity = 1)
    module_name = "foo"

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_log_overrides",
            query=Dict(
                "log" => "$(foo.log)",
                "verbosity" => "$(foo.verbosity)",
                "module_name" => "$(module_name)"
            ),
        ),
    )

    response = http_set_log_level_override(request)

    @test lookup_debug_levels_for(LogConfig, module_name) == foo
    @test response.status == 200
end

@testitem "Logging: HTTP /set_log_overrides, missing module name" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    using Logging
    reset_debug_levels!()

    foo = LogConfig(log = Logging.Debug, verbosity = 1)
    module_name = "foo"

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_log_overrides",
            query=Dict(
                "log" => "$(foo.log)",
                "verbosity" => "$(foo.verbosity)",
            ),
        ),
    )

    response = http_set_log_level_override(request)

    # Module name was not passed in the request, so the log configuration won't be set, and it should return the default values
    @test lookup_debug_levels_for(LogConfig, module_name) == LogConfig()
    @test response.status == 400
end

@testitem "Tracing: HTTP /set_tracing_defaults" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    reset_debug_levels!()

    foo = TracingConfig(1)

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_tracing_defaults",
            query="tracing=$(foo.tracing)",
        ),
    )

    response = http_set_tracing_level_defaults(request)

    @test lookup_debug_levels_for(TracingConfig, "") == foo
    @test response.status == 200
end

@testitem "Tracing: HTTP /set_tracing_overrides" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    reset_debug_levels!()

    foo = TracingConfig(1)
    module_name = "foo"

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_tracing_overrides",
            query=Dict(
                "tracing" => "$(foo.tracing)",
                "module_name" => "$(module_name)"
            ),
        ),
    )

    response = http_set_tracing_level_override(request)

    @test lookup_debug_levels_for(TracingConfig, module_name) == foo
    @test response.status == 200
end

@testitem "Tracing: HTTP /set_tracing_overrides, missing module name" begin
    using ProductionMonitoring.DebugLevels
    using ProductionMonitoring.DebugLevels: lookup_debug_levels_for
    using HTTP
    reset_debug_levels!()

    foo = TracingConfig(1)
    module_name = "foo"

    request = HTTP.Request("GET", "";
        url = HTTP.URI(;
            path="/set_tracing_overrides",
            query=Dict(
                "tracing" => "$(foo.tracing)",
            ),
        ),
    )

    response = http_set_tracing_level_override(request)

    # Module name was not passed in the request, so the tracing configuration won't be set, and it should return the default values
    @test lookup_debug_levels_for(TracingConfig, module_name) == TracingConfig()
    @test response.status == 400
end

@testitem "verbosity levels" begin
    using ProductionMonitoring.DebugLevels
    using Logging
    reset_debug_levels!()

    verbosity1 = LogConfig(log = Logging.Info, verbosity = 1)
    set_log_level_defaults(verbosity1)

    count = 0
    track_call() = global count += 1
    @info_with_verbosity 2 "This shouldn't be logged -- $(track_call())"
    @test count == 0

    @info_with_verbosity 1 "This *should* be logged -- $(track_call())"
    @test count == 1
end


@testitem "should_emit_log - no allocs" begin
    Base.Experimental.@optlevel 2  # perf test

    using ProductionMonitoring.DebugLevels
    using Logging
    function should_log_1()
        return @should_emit_log(Logging.Info, 1)
    end
    should_log_1()  # warmup
    @test @allocated(should_log_1()) === 0
end
