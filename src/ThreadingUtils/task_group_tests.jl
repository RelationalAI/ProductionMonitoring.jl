@testitem "TaskGroup and TaskTreeJoin" begin
    using ProductionMonitoring.ThreadingUtils
    counter = Threads.Atomic{Int}(0)
    tg = TaskGroup("Test")
    ttj = TaskTreeJoin()
    submit_task!(tg, ttj) do
        submit_task!(tg, ttj) do
            sleep(0.3)
            Threads.atomic_add!(counter, 1)
        end
        sleep(0.1)
        Threads.atomic_add!(counter, 1)
    end
    wait(ttj)
    @test counter[] == 2
end

# To implement snapshotting for scoped values, we are touching the internal of the package,
# as snapshotting is not yet implemented in the package. See the discussion here:
# https://github.com/vchuravy/ScopedValues.jl/issues/14
# If this starts failing, it might be a signal to start using the package's API.
@testitem "TaskGroups with ScopedValues" begin
    using ProductionMonitoring.ThreadingUtils
    using ScopedValues
    const S = ScopedValue(1)
    counter = Threads.Atomic{Int}(0)
    tg = TaskGroup("Test")
    ttj = TaskTreeJoin()

    # test multiple levels of nesting while changing the scope variable
    submit_task!(tg, ttj) do
        @test S[] == 1
        with() do
            submit_task!(tg, ttj) do
                @test S[] == 1
                with(S => 10) do
                    submit_task!(tg, ttj) do
                        @test S[] == 10
                        with(S => 100) do
                            submit_task!(tg, ttj) do
                                @test S[] == 100
                                with(S => 1000) do
                                    submit_task!(tg, ttj) do
                                        @test S[] == 1000
                                        sleep(0.1)
                                        Threads.atomic_add!(counter, S[])
                                    end
                                end
                                with(S => 10000) do
                                    submit_task!(tg, ttj) do
                                        @test S[] == 10000
                                        sleep(0.1)
                                        Threads.atomic_add!(counter, S[])
                                    end
                                end
                                with(S => 100000) do
                                    submit_task!(tg, ttj) do
                                        @test S[] == 100000
                                        sleep(0.1)
                                        Threads.atomic_add!(counter, S[])
                                    end
                                end
                                sleep(0.1)
                                Threads.atomic_add!(counter, S[])
                            end
                        end
                        sleep(0.1)
                        Threads.atomic_add!(counter, S[])
                    end
                end
                sleep(0.1)
                Threads.atomic_add!(counter, S[])
            end
        end
        sleep(0.1)
        Threads.atomic_add!(counter, S[])
    end

    wait(ttj)
    @test counter[] == (1 + 1 + 10 + 100 + 1000 + 10000 + 100000)
end
