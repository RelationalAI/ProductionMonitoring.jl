# DebugLevels

The DebugLevels package provides fine-grained mechanisms for controlling logging and tracing verbosity. The intention is to allow instrumenting the code with highly detailed logs that can be off by default but can be turned on in specific situations (e.g. when debugging or profiling or when diagnosing production issues).

Both logging and tracing debug levels can be set independently and we provide mechanisms for setting server-wide default as well as per-module overrides that can be used to fine-tune what kind of debug information will be emitted.

## Usage

Debug levels can currently be configured either at server startup via command-line flags, or via API calls which is suitable for local development. We are planning to support interface to change this on a running server and eventually would like to allow configuring this on a per-request/transaction basis.

### How to annotate logs

When emitting logs, we can use the built-in `@info`, `@warn`, `@error` and `@debug` macros. Additionally, we can use new macros `@info_with_verbosity`, `@warn_with_verbosity`, `@error_with_verbosity` and `@debug_with_verbosity` that annotate the log message with a numeric verbosity level.

```julia
@info "This is standard info log with default verbosity=0"
@warn_with_verbosity 2 "This is warning with verbosity=2"
```

In the standard case we can expect logs with verbosity 0 to be always emitted unless verbosity is set to a higher value, in this case logs with higher verbosity will be off by default.

In production, verbosity is set to 1, which is higher than the default for local logging.

Please note that debug levels for logging only works with our custom loggers (`JSONLogger` and `LocalLogger`).

Note that, as with the Logging levels (`@debug`, `@info`, `@warn`, etc), log expressions that are disabled due to their verbosity are _entirely_ disabled. This means that it is better performance to compute expensive strings inside the log expression. That is, you should prefer to write this:
```julia
@info_with_verbosity 2 "expensive string $(message()) to $(compute())"
```
rather than this:
```julia
msg = "expensive string $(message())"
msg *= " to $(compute())"
@info_with_verbosity 2 msg
```

If building the entire log message is still expensive to compute, (think printing large trees or other potentially substantial output), one can use `@should_emit_log` as a check instead of calling the logging macros. For example:
```julia
if @should_emit_log(Logging.Info, 2)
    message = "expensive to compute message"
    if expensive_check()
        message *= "more stuff"
    end
    @info message
end
```

### How to annotate traces

When creating tracing `@span`, `@sub_span` or adding span attributes with `@span_attribute` macro, we can annotate these structures with numeric verbosity as well. As with logs, in the standard situation we can expect spans and attributes with verbosity 0 to be always emitted, unless tracing is set to a higher value, in this case spans and attributes with higher verbosities will be off by default. When you use tracing macros without setting verbosity, they will be unaffected by Debug Level configuration and they will always be emitted.

```julia
@span "default-span" begin
    println("This is wrapped in a span with default verbosity 0.")
    @span "verbose-span" 2 begin
        println("This is wrapped in a span with verbosity 2.")
        @span_attribute "k1" "v1" 1  # optionally attaches span attribute k1
        @sub_span "optional-sub-span" 1 begin
            println("Wrapped in optional sub-span with verbosity 1.")
        end
    end
end
```

Be aware that debug level settings will **affect the structure of emitted traces** because verbose spans, sub-spans can be omitted.

In the example above, if the tracing verbosity is set to 1, `k1` span attribute will be attached to `default-span` (because `verbose-span` is not created). If verbosity is set to 2, `k1` will be attached to `verbose-span` instead.

## Per-module overrides

To allow for fine-grained control over what is emitted, debug levels use combination of server-wide defaults and per-module overrides. Logging and tracing overrides are independent from one another so you can easily set tracing overrides for specific module without affecting logging at all.

The overrides can be set for a fully qualified module name (e.g. `MyApp.ModuleA.ModuleB`) or for a path-component of a module name (e.g. `MyApp` or `ModuleA`). Module names and path-components are case-sensitive.

To find the fully qualified module name, one can use `@__DIR__` macro within the module itself:

```julia
@__DIR__
"..../src/ModuleA/ModuleB"
```

Fully qualified module name for this should then be `MyApp.ModuleA.ModuleB`

### Evaluation order of overrides

Finding if there's an override for a log statement or trace macro called from within a module (e.g. `Foo.Bar.Baz`), we look up overrides (of a specific type, e.g. log or tracing) in the following order:

1. If override exists for the fully qualified module name, it will be used (e.g. override for `Foo.Bar.Baz` exists)
2. Fully qualified module name will be broken down into path components and we look if there's override for any of the path-component going right-to-left (e.g. we look for overrides for `Baz`, then `Bar` and finally `Foo`)
3. If no overrides are found for either fully qualified module name or any of the path components, server wide defaults are used.

Note that for logging, we can control `log` severity and `verbosity` independently. Per-module overrides can leave either field unset in which case, server-wide defaults will be applied to that field. To demonstrate this, consider the following setup:
```julia
set_log_level_defaults(LogConfig(log=Logging.Info, verbosity=1))
set_log_level_override("Foo.Bar", LogConfig(verbosity=2))
set_log_level_override("Foo.Baz", LogConfig(log=Logging.Debug))
set_log_level_override("Foo", LogConfig(verbosity=3, log=Logging.Warn))
```
Note that this will result in the following behavior:
- Module `Foo.Bar` will use `LogConfig(verbosity=2, log=Logging.Info)`, where `verbosity` is inherited from override and `log` from server-wide default.
- Module `Foo.Baz` will use `LogConfig(verbosity=1, log=Logging.Debug)`, where `log` is inherited from override and `verbosity` from server-wide default.
- Module `Foo.Splash` will use `LogConfig(verbosity=3, log=Logging.Warn)`, where both `log` and `verbosity` is inherited from override for path-component `Foo`
- Module `Other.Thing` will use `LogConfig(verbosity=1, log=Logging.Info)` where both `log` and `verbosity` are server-wide defaults.

## Configuration

Unless otherwise specified, the default server-wide debug levels are `LogConfig(log=Logging.Info, verbosity=0)` for logging and `TracingConfig(0)`. This means that logs up to the `@info` severity and without verbosity annotations will be emitted and spans, sub-spans and attributes without verbosity annotations will be emitted.

This module supports several mechanisms for setting the debug levels suitable for different scenarios.

### Command line flags

This is suitable when running a binary either locally or in prod and when we only care about setting default server-wide settings. This doesn't support setting per-module overrides.

Example:
```
julia my-app.jl -- --default-log-severity Logging.Debug --default-log-verbosity 1 --default-tracing-verbosity 2
```

### Changing state on a running server

To change the debug levels on a running server, or to set per-module overrides since it can't be set using command line flags, one can use the HTTP endpoints:
```
- set_log_defaults?log=Logging.Info&verbosity=1: to set the log default setting.
- set_log_overrides?log=Logging.Info&verbosity=1&module_name=API: to set log overrides values. Expects passing a module name.
- set_tracing_defaults?tracing=1: to set tracing default level.
- set_tracing_overrides?tracing=1&module_name=API: to set tracing overrides levels. Expects passing a module name.
```

### Local development (API methods)

When running locally in REPL, we can use `DebugLevel` API methods to control the settings.

To set debug levels for logging, you can use the following:
```julia
set_log_level_defaults(LogConfig(log = Logging.Info, verbosity=1))
set_log_level_override("ModuleA", LogConfig(log=Logging.Warn))  # Mute Info logs for ModuleA
set_log_level_override("MyApp.Server", LogConfig(verbosity=5))  # Bump up verbosity for MyApp.Server

# remove log level overrides for ModuleA package (if exists)
remove_log_level_override("ModuleA")
```

To set debug levels for tracing, you can use the following:
```julia
set_tracing_level_defaults(TracingConfig(2))
set_tracing_level_override("MyApp", TracingConfig(5))  # bump up tracing verbosity for MyApp package
set_tracing_level_override("MyApp.Server", TracingConfig(0)) # mute tracing for MyApp.Server

# remove tracing level overrides for MyApp.Server package (if exists)
remove_tracing_level_override("MyApp.Server")
```

### Starting server locally (via Configuration)

If manually launching a server, you can use `log_setting_defaults` and `tracing_level_defaults` command line options as follows:
```julia
launch_server(;
    Configuration(
        log_level_defaults = LogConfig(log = Logging.Info, verbosity = 5),
        tracing_level_defaults = TracingConfig(1),
    ),
)
```

## Enabling Debug logging
Debug is disabled by default, when calling @debug or @debug_with_level nothing will be emitted. To enable debug, make sure to do the following:
1. Set the logger's min_value to Logging.Debug by setting the server command line option:
    ```julia
    launch_server(;log_min_level = Logging.Debug)
    ```
    Instead of setting this command line option, you can set the `JULIA_DEBUG` environment variable, however, this is not recommended.

2. Since the default value when not setting debug levels is Logging.Info, make sure to set the value to Logging.Debug, along with the verbosity needed.
