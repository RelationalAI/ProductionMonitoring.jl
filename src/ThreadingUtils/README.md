# ThreadingUtils
Contains helpers for working in multi-threaded environments

## `@spawn_with_error_log`
A couple of macros for spawning a background task whose result will never be
waited-on nor fetched-from but will still log exceptions.

Usage:
```julia
    @spawn_with_error_log expr
￼   @spawn_with_error_log "..error msg.." expr
```

## `@spawn_periodic_task(period, expr, name)`

This macro spawns task that will run given piece of code periodically and sleep in between.
This is useful for periodic upkeep tasks such as event/metric emissions or updating some
internal state. `PeriodicTask` structure is returned and this can be used to terminate
the underlying task.

Usage:
```julia
import Dates
disk_stuff = DiskStuff()
my_task = @spawn_periodic_task Dates.Seconds(30) dump_some_stuff_to_disk(disk_stuff) "DiskDumper"
...
stop_periodic_task!(my_task)  # Returns the underlying Task structure for inspection.
```

## `Future`

See docstring in `Future.jl`.

## `SynchronizedCache`

See docstring in `SynchronizedCache.jl`
