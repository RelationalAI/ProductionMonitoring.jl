@testitem "Future" begin
    using ProductionMonitoring.ThreadingUtils
    future = ThreadingUtils.Future{Int}(() -> 0)
    @test future[] == 0
    @test done(future)

    future = ThreadingUtils.Future() do
        return 10+1
    end
    @test future[] == 11

    future = ThreadingUtils.Future{Int}()
    @test !done(future)
    future[] = 11
    @test done(future)
    @test future[] == 11

    future = ThreadingUtils.Future{Int}() do
        throw(KeyError(3))
    end
    threw = begin
        try
            future[]
            false
        catch
            true
        end
    end
    @test threw
    @test done(future)

    future = ThreadingUtils.Future{Int}(3)
    @test future[] == 3
end
