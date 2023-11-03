# Tracing

This package enables capturing and reporting traces to various backends with performance and
breakdown information about "spans" of code.

## Introduction
The Tracing sub-package enables capturing & reporting traces. A trace consists of a tree
of nested spans which represent execution calls.
The span is the building block of distributed tracing, representing a unit of work. You
can enclose any computational functionality within a `span` and tag it with desired labels
or metrics (`PrintBackend`) for further debugging, tracing, and observability in general.

To enable tracing, you can call the `enable_tracing` function with the required
*backend*. By default, the `PrintBackend` is set and it will print the traces
during execution. Alternatively, to disable tracing, you can call the `disable_tracing` function.

A span can be added to your code, by using the `@span` macro, e.g.:

```julia
@span "my-span" myfunction()
```

This will make *my-span* show up in the trace, and duration will be recorded.
Extra information about the *enclosing* span can be added in the form of attributes
 (key/value String pairs):

```julia
@span "outer span" begin
    # tagging outer span
    @span_attribute "k1" "v1"
    @span "inner span" begin # nested span
      # tagging inner span
      @span_attribute "k2" "v2"
      myfunction()
    end
end
```
If needed, you can push key-value pairs to children spans using the span's context bag, e.g.,
```julia
@span "outer span" begin
    # adding (k,v) to the context bag
    span_bag("k", "v")
    @span "inner span" begin # nested span
      # get from context
      v = get_span_bag("k")
      ...
    end
end
```
Note that these will _not_ be attached as attributes to the span when it is
emitted. They are only available internally. This matches the [open telemetry
standard](https://opentelemetry.io/docs/concepts/signals/baggage/#baggage-is-not-the-same-as-span-attributes).
Please be cautious with the usage of span_bags; the bag is copied to all
children spans, which if overused may cause noticeable overhead.

For much more lightweight profiling of methods that are potentially called many times, one
can use the `@sub_span` macro. It accumulates the time spent in the named "sub-span"
without immediately reporting it. Only when the surrounding span finishes all sub-spans are
collected and the total accumulated time is reported / printed.

```julia
enable_tracing()
@span "outer" begin
    @sub_span "inner 1" inxpensive_function(0)
    for i in 1:10000
        @sub_span "inner 2" inxpensive_function(i)
    end
end
```

This results in the output:
```
┌─ outer
│ ┌─ inner 1
│ └─ inner 1 duration: 0.00001
│ ┌─ inner 2
│ └─ inner 2 duration: 0.00071
│ Aggregate span duration (s):
│      0.00001 =  0.0% =  inner 1
│      0.00071 =  2.2% =  inner 2
└─ outer duration: 0.03242
```
Notice that "inner 2" is only reported as one Span even though `inxpensive_function(..)` is
called 10K times.



One could also add `metrics` `(k,v::Float)` to corresponding spans. In, the `PrintBackend` , these
metrics are reduced/aggregated by key `k` and reported at the root span. e.g.,
```julia
enable_tracing()
@span "outer span" begin
    @span "inner span-1" begin #
      @span "inner inner span" begin
        span_metric("metric1",1.0)
      end
    end
    @span "inner span-2" begin # nested span
      span_metric("metric1",1.0)
      span_metric("metric2",1.0)
    end
end
```

This results in the output:
```
┌─ outer span
│ ┌─ inner span-1
│ │ ┌─ inner inner span
│ │ └─ inner inner span duration: 0.00763
│ └─ inner span-1 duration: 0.03337
│ ┌─ inner span-2
│ └─ inner span-2 duration: 0.00912
│ Aggregate span duration (s):
│      0.03337 =  6.7% =  inner span-1
│      0.00763 =  1.5% =      inner inner span
│      0.00912 =  1.8% =  inner span-2
│ Aggregate Metrics :
│      metric2 , 1.00000
│      metric1 , 2.00000
└─ outer span duration: 0.49807
```
Notice how the metrics are reduced by key `k`, no matter the call structure.


## Tracing Interface
- `@span(name, ex::Expr)`: Macro that defines an enclosing `span` with functionality `Expr`.
- `@span(name, tracing_level::Int64, ex::Expr)`: Macro that defines an enclosing `span` with functionality `Expr` with the ability to set the tracing level.
- `@span_no_threshold(name, ex::Expr)`: Macro that defines an enclosing `span` with functionality `Expr` and adds an attribute that supersedes any duration threshold for emitting the span.
- `@sub_span(name, ex::Expr)`: Macro that defines an enclosing `subspan` within a `span`.
  *Note:* `subspans` are not thread safe for performance reasons, i.e, make sure that a `subspan` operates in the same task/thread as the enclosing span.
- `@sub_span(name, tracing_level::Int64, ex::Expr)`: Macro that defines an enclosing `subspan` within a `span` with the ability to set the tracing level.
- `@span_attribute(k,v)`: Macro that tags the enclosing `span` with the `(k,v)` pair as attributes.
- `@span_attribute(k,v,tracing_level::Int64)`: Macro that tags the enclosing `span` with the `(k,v)` pair as attributes with the ability to set the tracing level.
- `span_bag(k,v)`: This function adds the `(k,v)` pair to the enclosing `span's` context, i.e., pushed down, shared with children nested spans.
- `get_span_bag(k)`: This function gets the value `v` associated to key `k` from the enclosing `span's` context bag.
- `span_metric(k,v)`: Only used for the `PrintBackend`. This function tags the enclosing `span` with the `(k,v)` pair where `v` is a metric (float).
  All metrics will be aggregated/reduced (by key `k`) and reported at the top most root.


## Tracing Backends
There are a couple of backends to hook the tracers to. ```enable_tracing(::TracingBackend)```
- `PrintBackend`: This is the default backend hook. Used mostly for local tracing and performance breakdowns.
- [ZipkinBackend](https://zipkin.io): Zipkin Backend hook. Used mostly for local tracing with visualizations/Flamegraph.  Setup:
  - Install [Docker](https://www.docker.com).
  - Run the zipkin agent from another terminal: `sudo docker run -d -p 9411:9411 openzipkin/zipkin`.
  - From the Julia REPL, enable tracing `Tracing.enable_tracing(Tracing.ZipkinBackend)`, and run your computations normally. Or if manually launching a server, use `launch_server(;config=Configuration(tracing=:zipkin))`
  - Open the web browser at the following url `127.0.0.1:9411/zipkin` and query for your traces.
- [DataDogBackend](https://www.datadoghq.com): Datadog Backend hook. Used mostly for production tracing.
  - The setup should be configured for you on RaiCloud by default. The user should not worry about any setup, other than running queries.
- `xray`: Not tested yet.


See test/Util/tracing.jl for more examples of using/applying tracing.


## Minimum Span Threshold

A minimum span threshold value can be specified to limit the number of spans produced. Only spans with duration that exceeds the threshold will be emitted.
To enable minimum span threshold, you can call the `Tracing.enable_span_threshold_sec` function with the threshold value. Or if manually launching a server, you can use `launch_server(;Configuration(tracing=$tracingMode, span_threshold_sec=$value))`. To disable it, you can call the `Tracing.disable_span_threshold_sec`.
This option has no effect on the PrintBackend tracing mode, and it is measured in seconds.


## Tracing Level

A tracing level can be set optionally when using @span, @sub_span, and @span_attribute macro functions. The tracing level is used to determine whether a span information should be emitted or not by comparing it to the level set in DebugLevels package. All span information with tracing less than or equal the value set at the server or module level are emitted. The default value when the tracing level is not set is 0. See [DebugLevels/README.md](https://github.com/RelationalAI/raicode/blob/master/packages/DebugLevels/README.md) for information on how to set the debug level at the server or module level.
The tracing level can be used as follows:

```julia
set_tracing_level_defaults(TracingConfig(2)) # Setting the tracing level to 2 at the server level
@span "main-span" 1 begin
  @span_attribute "k" "v"
  @sub_span "sub-span" 4 begin
      #myfunction()
    end
end
```

This results in the output:
```
┌─ main-span
│ k=v
└─ main-span duration: 0.06056
```
The main span is emitted but the sub_span isn't because the sub_span has tracing level of 4 which is higher than the value set at the server level (2). Notice that here the tracing level for span_attribute is not set, which means it defaults to 0.

Tags can be disabled while the spans are emitted as follows:

```julia
@span "main-span" 1 begin
    @span_attribute "k1" "v1" 3
    @span "inner-span" 1 begin
        @span_attribute "k2" "v2" 1
        #myfunction()
    end
end
```

This results in the output:
```
┌─ main-span
│ ┌─ inner-span
│ │ k2=v2
│ └─ inner-span duration: 0.01156
│ Aggregate span duration (s):
│      0.01156 = 18.5% =  inner-span
└─ main-span duration: 0.06248
```
