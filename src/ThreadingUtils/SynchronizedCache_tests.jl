@testitem "SynchronizedCache" begin
    using ProductionMonitoring.ThreadingUtils
    cache = SynchronizedCache{Symbol,Int}()

    count = Ref{Int}(0)
    x = cache_get!(cache, :x) do
        count[] += 1
        return 1
    end
    @test x == 1
    x2 = cache_get!(cache, :x) do
        count[] += 1
        return 1
    end
    @test x2 == 1
    @test count[] == 1

    count[] = 0
    future = ThreadingUtils.Future{Int}() do
        return cache_get!(cache, :y) do
            count[] += 1
            sleep(2)
            return 2
        end
    end
    sleep(1)
    y2 = cache_get!(cache, :y) do
        count[] += 1
        return 3
    end
    @test y2 == 2
    @test count[] == 1

    cache_replace!(cache, :y, 10)
    @test cache_get!(()->11, cache, :y) == 10

    cache_delete!(cache, :y)

    @test cache_get!(()->15, cache, :y) == 15
end
