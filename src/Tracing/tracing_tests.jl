@testitem "tracing" begin

using ProductionMonitoring.ThreadingUtils
import ProductionMonitoring.Tracing
using ProductionMonitoring.DebugLevels
using ProductionMonitoring.Tracing
using ProductionMonitoring.Tracing: Carrier, extract
using ProductionMonitoring.Tracing: get_traces_from_cache, clear_traces_cache, DataDogFormat
using ProductionMonitoring.ThreadingUtils: PeriodicTask
import ProductionMonitoring.TransactionLogging, Logging
using Base.Threads: @sync, @async, @spawn, Atomic, atomic_add!

using Test: @test

function get_all_spans()
    result = []
    x = collect(get_traces_from_cache())
    for (k, vl) in x
        for v in vl
            push!(result, v)
        end
    end

    return result
end

function span_by_name(name::AbstractString)
    for span in get_all_spans()
        span.name == name && return span
    end
    error("Not found: $(name)")
end

function check_span_names(expected)
    found = []
    for span in get_all_spans()
        push!(found, span.name)
    end
    @test sort(expected) == sort(found)
end

function check_all_complete()
    for span in get_all_spans()
        span.id != 0 && @test span.end_time != 0
        span.id == 0 && @test span.end_time == 0
    end
end


function run_tracing_tests()
    enable_tracing(; restart_ok=true)
    enable_tracing_cache()
    clear_traces_cache()

    @testset "Trace Extraction" begin
        d = DataDogFormat
        headers = Dict(
            d.TraceIDHeader => "33",
            d.ParentIDHeader => "22",
            d.BaggageHeaderPrefix * "key1" => "v1",
            d.BaggageHeaderPrefix * "key2" => "v2",
        )
        carrier = Carrier(headers)
        sc = extract(d,carrier)
        @test sc.traceid == 33
        @test sc.spanid == 22
        @test haskey(sc.bag, "key1")
        @test haskey(sc.bag, "key2")
    end


    @testset "Span from extracted parent " begin
        d = DataDogFormat
        headers = Dict(
            d.TraceIDHeader => "33",
            d.ParentIDHeader => "22",
            d.BaggageHeaderPrefix * "key1" => "v1",
            d.BaggageHeaderPrefix * "key2" => "v2",
        )
        carrier = Carrier(headers)
        sc = extract(d,carrier)

        @span "extracted span" sc begin
            ctx = active_ctx()
            @test ctx.current_span.span_context.traceid == 33
        end

    end

    @testset "Tracing Tests" begin
        @testset "Start new trace" begin
            ctx = active_ctx()
            @test isa(ctx.current_span.span_context.traceid, UInt64)
            @test ctx.current_span.id == 0
            clear_traces_cache()
        end

        @testset "Span is hygienic" begin
            ctx = active_ctx()
            old_current_span = ctx.current_span
            @span "my-span" begin end

            @test ctx.current_span.id == 0
            @test ctx.current_span == old_current_span
            clear_traces_cache()
        end

        @testset "Single span, wrapped" begin

            @span "span1" begin
                sleep(0.001)
            end

            @test length(get_all_spans()) == 2
            check_span_names(["root", "span1"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Multiple spans, wrapped" begin

            @span "span1" begin
                sleep(0.001)
            end
            @span "span2" begin
                sleep(0.001)
            end

            @test length(get_all_spans()) == 4
            check_span_names(["root", "root", "span1", "span2"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Nested spans, wrapped" begin
            @span "parent-span" begin
                sleep(0.001)
                @span "child-span" begin
                    sleep(0.001)
                    @span "grand-child-span" begin
                        sleep(0.001)
                    end
                end
            end

            @test length(get_all_spans()) == 4
            check_span_names(["root", "parent-span", "child-span", "grand-child-span"])
            check_all_complete()
            for span in get_all_spans()
                if span.name in ["child-span", "grand-child-span"]
                    @test span.parent_span.id != UInt64(0)
                elseif span.name == "parent-span"
                    @test span.parent_span.id == UInt64(0)
                end
            end
            clear_traces_cache()
        end

        @testset "Nested spans, wrapped, verified structure" begin
            @span "parent-span" begin
                sleep(0.001)
                @span "child-span1" begin
                    sleep(0.001)
                    @span "grand-child-span" begin
                        sleep(0.001)
                    end
                end
                @span "child-span2" begin
                    sleep(0.001)
                end
            end

            @test length(get_all_spans()) == 5
            check_span_names(["root", "parent-span", "child-span1", "grand-child-span", "child-span2"])
            check_all_complete()
            parent = span_by_name("parent-span")
            child1 = span_by_name("child-span1")
            for span in get_all_spans()
                if span.name in ["child-span1", "child-span2"]
                    @test span.parent_span.id == parent.id
                elseif span.name == "grand-child-span"
                    @test span.parent_span.id == child1.id
                elseif span.name == "parent-span"
                    @test span.parent_span.id == UInt64(0)
                end
            end

            clear_traces_cache()
        end


        @testset "Spans across tasks, verified structure" begin
            chan = Channel{Bool}()
            @sync begin
                @span "span-task-outer" begin
                    outer_span_ctx = active_ctx()
                    @async begin
                        take!(chan)
                        task_ctx = active_ctx()
                        @test outer_span_ctx == task_ctx
                        @span "span-delayed-task-inner" begin
                            task_ctx = active_ctx()
                            @test outer_span_ctx !== task_ctx
                            sleep(0.1)
                        end
                    end
                end
                put!(chan, true)
            end

            @test length(get_all_spans()) == 3
            outer = span_by_name("span-task-outer")
            inner = span_by_name("span-delayed-task-inner")

            # verify that the inner span started after the outer span
            @test inner.start_time > outer.end_time
            # and that the inner span still has the outer parent
            @test inner.parent_span.id == outer.id

            clear_traces_cache()
        end

        @testset "Span in expression, wrapped" begin
            # need to wrap in a function, otherwise the `return` will exit the testset :)
            function test_func()
                v = @span "span" begin
                    1 + 1
                end
                @test v == 2

                v = @span "span" begin
                    return 1
                end
                @test v == 1
            end
            test_func()

            check_all_complete()
            clear_traces_cache()
        end

        @testset "Error in span" begin

            try
                @span "span1" begin
                    sleep(0.001)
                    error("ERROR, yikes!")
                end
            catch
            end

            @test length(get_all_spans()) == 2
            @test span_by_name("span1").error !== nothing
            check_span_names(["root", "span1"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Spans across tasks" begin

            @span "span-task-outer" begin
                outer_span_ctx = active_ctx()
                @sync @async begin
                    task_ctx = active_ctx()
                    @test outer_span_ctx == task_ctx
                    @span "span-task-inner" begin
                        task_ctx = active_ctx()
                        @test outer_span_ctx !== task_ctx
                        sleep(0.1)
                    end
                    @test length(get_all_spans()) == 3
                end
            end

            @test length(get_all_spans()) == 3

            # once a backend is available and spans get pushed,
            # this should add a test on the receiving side, to
            # make sure the received spans are complete.
            clear_traces_cache()
        end

        @testset "Function using macro" begin
            @span function test_it_now()
                sleep(0.001)
            end
            test_it_now()
            @test length(get_all_spans()) == 2
            check_span_names(["root", "test_it_now"])
            clear_traces_cache()
        end

        @testset "Block using macro without name" begin
            @span begin
                sleep(0.001)
            end
            @test length(get_all_spans()) == 2
            prefix = string(basename(@__FILE__), ":")
            names = [span.name for span in get_all_spans()]
            @test startswith(names[1], prefix) || startswith(names[2], prefix)
            clear_traces_cache()
        end

        @testset "Spans with generated names" begin

            toy_func(a::Int64, b::String) = a + length(b)

            @span toy_func(123, "123")
            @span 1 + 1

            # two traces have been created implicitly
            # hence 2 roots
            @test length(get_all_spans()) == 4
            check_span_names(["root", "root", "toy_func", "1 + 1"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Span with block to compute attribute" begin
            set = @span "span with block" begin
                @span_attribute "def" "def attribute"
                @span_attribute "body" () -> "body attribute"
                @span_attribute "foo" SubString("abc", 1, 2)
                Set{Int}([2, 3, 4])
            end
            clear_traces_cache()
        end

        # https://github.com/RelationalAI/raicode/issues/2188
        @testset "Span with early return" begin
            function test_it_now(fail)
                @span "span with block" begin
                    fail && return 0
                    return 2
                end
            end
            @test test_it_now(true) == 0
            @test test_it_now(false) == 2
            clear_traces_cache()
        end

        # https://github.com/RelationalAI/raicode/issues/2188
        @testset "Nested span with early return" begin
            function test_it_now(fail)
                @span "outer span" begin
                    (x, y) = @span "inner span" begin
                        fail && return 0
                        (1, 2)
                    end
                    return x
                end
            end
            @test test_it_now(true) == 0
            @test test_it_now(false) == 1
            clear_traces_cache()
        end

        # https://github.com/RelationalAI/raicode/pull/13135
        @testset "Span with early return inside function that continues" begin
            function test_it_now(fail)
                @span "span with block" begin
                    fail && return 0
                    return 2
                end

                # This should never be reached.  But before #13135, it was.
                return 3
            end
            @test test_it_now(true) == 0
            @test test_it_now(false) == 2
            clear_traces_cache()
        end

        # https://github.com/RelationalAI/raicode/pull/13135
        @testset "Nested span with early return inside function that continues" begin
            function test_it_now(fail)
                @span "outer span" begin
                    (x, y) = @span "inner span" begin
                        fail && return 0
                        (1, 2)
                    end
                    return x
                end
                # This should never be reached.  But before #13135, it was.
                return 3
            end
            @test test_it_now(true) == 0
            @test test_it_now(false) == 1
            clear_traces_cache()
        end

        # https://github.com/RelationalAI/raicode/pull/13135
        @testset "Spans evaluate to their expression" begin
            function test_it_now()
                v = @span "outer span" begin
                    @span "inner span" begin
                        1 + 1
                    end
                    2 + 2
                end
                return v
            end
            @test test_it_now() == 4
            clear_traces_cache()
        end

        @testset "Spans can throw" begin
            function test_it_now()
                v = @span "outer span" begin
                    throw(1)
                    return 2
                end
                return v
            end
            # x should be `1`, the thrown value, not `2`, the "returned" value.
            x = try
                test_it_now()
            catch e
                e
            end
            @test x == 1
            clear_traces_cache()
        end

        # **** Tests for `@sub_span`:
        @testset "Top-level sub-spans are ignored" begin

            @sub_span "sub1" begin
                sleep(0.001)
            end
            @sub_span "sub2" begin
                sleep(0.001)
                @sub_span "sub3" begin
                    sleep(0.001)
                end
            end

            # None of the spans above is actually added.
            @test length(get_all_spans()) == 0
            check_span_names([])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Multiple sub-spans, verified structure" begin
            clear_traces_cache()
            @span "span1" begin
                @sub_span "sub1" begin
                    sleep(0.001)
                end
            end
            @span "span2" begin
                @sub_span "sub2" begin
                    sleep(0.001)
                end
                @sub_span "sub3" begin
                    sleep(0.001)
                end
            end
            # Two traces issued, hence 2 roots
            @test length(get_all_spans()) == 7
            check_span_names(["root", "root", "span1", "span2", "sub1", "sub2", "sub3"])
            span1 = span_by_name("span1")
            sub1 = span_by_name("sub1")
            span2 = span_by_name("span2")
            sub2 = span_by_name("sub2")
            sub3 = span_by_name("sub3")
            @test sub1.parent_span.id == span1.id
            @test sub2.parent_span.id == span2.id
            @test sub3.parent_span.id == span2.id
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Sub-spans with generated names" begin
            toy_func(a::Int64, b::String) = a + length(b)

            @span "span" begin
                @sub_span toy_func(123, "123")
                @sub_span 1 + 1
            end

            @test length(get_all_spans()) == 4
            check_span_names(["root", "span", "toy_func", "1 + 1"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Nested spans with multiple sub-spans" begin
            @span "span1" begin
                @sub_span "sub1" begin
                    sleep(0.001)
                end
                @span "span2" begin
                    @sub_span "sub2" begin
                        sleep(0.001)
                    end
                    @sub_span "sub3" begin
                        sleep(0.001)
                        @sub_span "sub4" begin
                            sleep(0.001)
                        end
                    end
                end
            end

            @test length(get_all_spans()) == 7
            check_span_names(["root", "span1", "span2", "sub1", "sub2", "sub3", "sub4"],)
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Error in sub-span" begin
            try
                @span "span1" begin
                    @sub_span "span2" begin
                        sleep(0.001)
                        error("ERROR, yikes!")
                    end
                end
            catch
            end
            @test length(get_all_spans()) == 3
            @test span_by_name("span1").error !== nothing
            check_span_names(["root", "span1", "span2"])
            check_all_complete()
            clear_traces_cache()
        end

        @testset "sub-span with early return" begin
            function test_it_now(fail)
                @span "outer span" begin
                    (x, y) = @sub_span "inner span" begin
                        fail && return 0
                        (1, 2)
                    end
                    return x
                end
            end
            @test test_it_now(true) == 0
            @test test_it_now(false) == 1
            clear_traces_cache()
        end

        @testset "Example with more nesting" begin

            @span "outer" begin
                total = 0
                for i = 1:1000
                    @sub_span "sub-span 1" total += 1
                end
                @span "inner" begin
                    for i = 1:1000
                        @sub_span "sub-span 2" begin
                            total += 1
                        end
                        for j = 1:1000
                            @sub_span "sub-span 3" begin
                                @sub_span "sub-span 4" total += 1
                            end
                        end
                    end
                end
            end
            check_span_names([
                "root",
                "outer",
                "inner",
                "sub-span 1",
                "sub-span 2",
                "sub-span 3",
                "sub-span 4",
            ])
            clear_traces_cache()
        end

        @testset "Multi-threaded subspans with nesting" begin
            total = Atomic{Int64}(0)
            @span "outer" begin
                @sync begin
                    @async @span "inner" begin
                        Threads.@threads for i in 1:1000
                            @sub_span "sub-span 2" begin
                                atomic_add!(total, 1)
                            end
                            for j in 1:5000
                                @sub_span "sub-span 3" atomic_add!(total, 1)
                                @sub_span "sub-span 4" atomic_add!(total, 1)
                            end
                        end
                    end
                    @async begin
                        for i in 1:1000
                            @sub_span "sub-span 1" atomic_add!(total, 1)
                        end
                    end
                end
            end
            @test total[] == 10002000
            check_span_names([
                "root",
                "outer",
                "inner",
                "sub-span 1",
                "sub-span 2",
                "sub-span 3",
                "sub-span 4",
            ])
            clear_traces_cache()
        end

        @testset "Multitasking spans example with nesting (1) " begin
            @span "outer" begin
                total = 0
                @sync begin
                    @async @span "inner" begin
                        Threads.@threads for i = 1:100
                            @span "inner-span $i" begin
                                total += 1
                                Threads.@threads for j = 1:10
                                    @span "inner-inner-span %j" total += 1
                                end
                            end
                        end
                    end
                    for i = 1:1000
                        @sub_span "sub-span 1" total += 1
                    end
                end
            end
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Multitasking spans example with nesting (2) " begin
            @span "outer" begin
                total = 0
                @sync begin
                    @async @span "inner" begin
                        Threads.@threads for i = 1:100
                            @span "inner-span $i" begin
                                total += 1
                                Threads.@threads for j = 1:10
                                    @span "inner-inner-span $j" total += 1
                                end
                            end
                        end
                    end
                    for i = 1:1000
                        @sub_span "sub-span 1" total += 1
                    end
                end
            end
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Nested spans with bags (pushing context down)" begin
            @span "Request" begin
                span_bag("rqid", "54273")
                @span "Transaction" begin
                    @span "innermost span" begin
                        rqid = get_span_bag("rqid")
                        @test rqid == "54273"
                    end
                end
            end
            check_all_complete()
            clear_traces_cache()
        end

        @testset "Nested spans with aggs" begin
            @span "Request" begin
                @span "Transaction" begin
                    span_metric("metric-1", 1.0)
                    @span "innermost span" begin
                        span_metric("metric-1", 1.0)
                        span_metric("metric-2", 1.0)
                    end
                end
            end
            check_all_complete()
            clear_traces_cache()
        end
    end

    @testset "Single span_no_threshold, wrapped" begin

        @span_no_threshold "span1" begin
            sleep(0.001)
        end

        @test length(get_all_spans()) == 2
        check_span_names(["root", "span1"])
        check_all_complete()
        clear_traces_cache()
    end

    disable_tracing()
    disable_tracing_cache()
    yield()
end

@testset "Tracing with setting span threshold" begin
    @testset "Negative span threshold value" begin
        enable_tracing(Tracing.DataDogBackend; restart_ok=true)
        enable_span_threshold_sec(-1)
        @test is_span_threshold_set() == false
        disable_tracing()
    end

   @testset "Span threshold set with disabled tracing" begin
        enable_span_threshold_sec(1.1)
        @test is_span_threshold_set() == false
    end

    @testset "Span threshold set with PrintBackend tracing mode" begin
        enable_tracing(; restart_ok=true)
        enable_span_threshold_sec(1.1)
        @test is_span_threshold_set() == false
        disable_tracing()
    end

    @testset "Span threshold set with ZipkinBackend tracing mode" begin
        enable_tracing(Tracing.ZipkinBackend; restart_ok=true)
        enable_span_threshold_sec(1.1)
        @test is_span_threshold_set() == true
        disable_tracing()
    end

    @testset "Span threshold set with TestBackend tracing mode" begin
        enable_tracing(Tracing.TestBackend; restart_ok=true)
        enable_span_threshold_sec(1.1)
        @test is_span_threshold_set() == true
        @span "should_appear" begin
            sleep(2)
            1+1
        end
        @span "disappear" begin
            1+1
        end
        # wait long enough that the periodic task should run and send the spans to the
        # configured backend
        sleep(5)
        @test length(Tracing.test_sink) == 1
        @test Tracing.test_sink[1].name == "should_appear"
        disable_tracing()
        empty!(Tracing.test_sink)
    end


    @testset "Span percent threshold set with TestBackend tracing mode" begin
        enable_tracing(Tracing.TestBackend; restart_ok=true)
        enable_span_threshold_percent(0.25)
        @test is_span_threshold_set() == true
        @span "outside" begin
            sleep(5)
            @span "should_appear" begin
                sleep(2)
                1+1
            end
            @span "disappear" begin
                1+1
            end
        end
        # wait long enough that the periodic task should run and send the spans to the
        # configured backend
        sleep(5)
        @test length(Tracing.test_sink) == 2
        # Inner spans are recorded first
        span_names = ["should_appear", "outside"]
        @test Tracing.test_sink[1].name in span_names
        @test Tracing.test_sink[2].name in span_names
        @test Tracing.test_sink[1].name != Tracing.test_sink[2].name
        disable_tracing()
        empty!(Tracing.test_sink)
    end

end

@testset "Should emit tracing spans" begin
    SERVER_TRACING = 1
    RAI_TRACING = 2

    set_tracing_level_defaults(TracingConfig(SERVER_TRACING))
    set_tracing_level_override("RAICode", TracingConfig(RAI_TRACING))

    # RAI is set
    @test should_emit_tracing(RAI_TRACING, "RAICode")
    @test should_emit_tracing(RAI_TRACING - 1, "RAICode")
    @test !should_emit_tracing(RAI_TRACING + 1, "RAICode")

    # RAICode.QueryEvaluator is not set, tracing is inherited from RAI
    @test should_emit_tracing(RAI_TRACING, "RAICode.QueryEvaluator")
    @test should_emit_tracing(RAI_TRACING - 1, "RAICode.QueryEvaluator")
    @test !should_emit_tracing(RAI_TRACING + 1, "RAICode.QueryEvaluator")

    # Arroyo is not set, tracing is inherited from server level configuration
    @test should_emit_tracing(SERVER_TRACING, "Arroyo")
    @test should_emit_tracing(SERVER_TRACING - 1, "Arroyo")
    @test !should_emit_tracing(SERVER_TRACING + 1, "Arroyo")

    reset_debug_levels!()
end

@testset "Datadog exporter tests" begin
    @test Tracing.tracing_config.datadog_bg == nothing

    enable_tracing(Tracing.PrintBackend; restart_ok=true)
    @test Tracing.tracing_config.datadog_bg == nothing

    enable_tracing(Tracing.DataDogBackend; restart_ok=true)
    @test Tracing.tracing_config.datadog_bg isa PeriodicTask

    enable_tracing(Tracing.PrintBackend; restart_ok=true)
    @test Tracing.tracing_config.datadog_bg isa PeriodicTask

    disable_tracing()
    @test Tracing.tracing_config.datadog_bg == nothing
end

run_tracing_tests()

@testset "Test TracingLogger log forwarding" begin
    log_buffer = IOBuffer()
    Logging.with_logger(TransactionLogging.LocalLogger(stream=log_buffer, request_id="1", transaction_id="2")) do
        enable_tracing(; restart_ok=true)
        enable_span_threshold_sec(1.1)

        @span "span0" begin
            @info "Test log message"  # <- should be forwarded to the parent logger

            # Test that these log reflection functions are forwarded through properly:
            @test TransactionLogging.get_request_id() == "1"
            @test TransactionLogging.get_transaction_id() == "2"
        end

        disable_tracing()
        disable_tracing_cache()
    end

    generated_log_message = String(take!(log_buffer))
    @test occursin("Test log message", generated_log_message)
end

@testset "Account and engine name forwarded by TransactionLogging" begin
    l = TransactionLogging.LocalLogger(stream=IOBuffer(), account_name="acc_name", engine_name="eng_name")
    Logging.with_logger(l) do
        enable_tracing(; restart_ok=true)
        enable_span_threshold_sec(1.1)

        @span "span0" begin
            @info "Test log message"  # <- should be forwarded to the parent logger

            # Test that that account and engine names are forwarded through properly:
            @test TransactionLogging.get_account_name(l) == "acc_name"
            @test TransactionLogging.get_engine_name(l) == "eng_name"
        end

        disable_tracing()
        disable_tracing_cache()
    end
end

end # testitem
