# Metrics

The Metrics package contains:

  1. Server metrics infrastructure for collecting process-wide statistics.

## Server metrics

Server metrics allow engineers to instrument their code to expose useful information about
what is happening within the server (a program running on a single machine).

Metrics are primarily numeric representations of either current state (e.g. how much disk
are we using at the moment) or event counters (how many requests did we handle so far).

Currently, the two flavors of metrics are supported:

  1. `Gauge`s represent current state of some measure, such as "bytes stored on disk". The
     value can fluctuate and change over time.
  2. `Counter`s count events of interest or aggregations of values over time. The guarantee
     is that the value of a counter never decreases and what usually matters is not the value
     itself but rather how it changes over time.

### Basic operation

The library allows user to construct `Counter`s and `Gauge`s either individually
or (preferably) wrapped in `MetricCollection` structures. Metrics or collections can be
registered with either *default registry* or with custom registries. Upon registration,
metrics need to have unique names assigned to them.

Metric registries can be set up to publish the state of the registered metrics to a variety
of backends, specifically the library offers:

  1. StatsdExporter that will periodically send UDP messages to the statsd backend (cf. StatsdExport package)
  2. Prometheus compatible http request handler that can serve the state of registered
     metric on `/metrics` (or custom) http endpoint.

### Metric labels

Metrics can either be scalars (a single number) or they can have one or more labels. This
can be thought of as having sparse matrices where many related measures are tracked.

An example of this is http response tracking where we may want to break this down by
action (GET/PUT) and http response code. To do this, simply create `Gauge` or `Counter`
and list all the labels by adding keyword argument `labels::Vector{Symbol}` when constructing
new metrics.

Label values are always converted to strings using `string(value)` casting.

```julia
responses_total::Counter = Counter(; labels=[:action, :response_code])
```

To manipulate these metrics, you will need to pass label assignments:
```julia
inc!(responses_total; action="GET", response_code=500)
inc!(responses_total; action="PUT", response_code=200)
```

Label assignments are valid when all labels associated with the metric are set and no
extraneous labels are set. Examples of invalid labels for the `responses_total` metric
defined above:
```julia
# missing action label
inc!(responses_total; response_code=500)

# uri doesn't belong here, since it's not a label associated with the metric on construction
inc!(responses_total; action="GET", response_code=500, uri="/transaction")
```

Keep in mind the following rules:
  * If invalid labels are set when manipulating metrics, the library will log an error
    and drop the operation on the floor. This is to ensure that bugs in the
    instrumentation won't crash the service in production.
  * Each metric is limited to 200 distinct values (distinguished by unique label-value
    assignments). When this limit is reached, least recently used cell is deleted.
    This limit is in place to ensure that poorly written instrumentation code will not
    be able to leak memory, incur excessive datadog costs (we pay for each cell)
    or cause performance issues in the instrumentation code.

### Instrumenting your code

To instrument your module with server metrics you will first need to create a subclass of
`Metrics.AbstractMetricCollection` that will hold your metrics.

```julia
using Metrics

Base.@kwdef struct MyModuleMetrics <: AbstractMetricCollection
    lunches_consumed::Counter = Counter() # specify the type to ensure type stability
    hunger_level::Gauge = Gauge(5.0)  # Hunger starts at 5.0
end
```

If you want these metrics to be exposed to production monitoring systems by default, you will
want to create a global const instance of this structure and add it to the default metric registry at the module `__init__()` using the following:

```julia
const metrics = MyModuleMetrics()

function __init__()
  Metrics.publish_metrics_from(metrics)
end
```

And then you can instrument your code by manipulating metrics within the `metrics` instance:
```julia
function eat_lunch()
    inc!(metrics.lunches_consumed)
    dec!(metrics.hunger_level)
    # ... eat lunch here ...
end

function exercise_little()
    inc!(metrics.hunger_level)
    # ... do the exercises ...
end

function exercise_a_lot()
    inc!(metrics.hunger_level, 3.0)
    # ... do the exercises ...
end
```

### Naming conventions

See https://prometheus.io/docs/practices/naming/ as a starting point.

Important points:
- Units should be included as part of the metric name. For example, a gauge metric tracking
  memory might be called `memory_usage_bytes`.
- The first word should indicate what part of the system is exporting the metric. It may
  make sense to make these multi-tiered (e.g., `pager_memory_usage_bytes`,
  `julia_memory_usage_bytes`)
- You should never change the type of an existing metric, for backward compatibility
  reasons. (Imagine a rollout where multiple versions are running and exporting different
  types to the same metric; not a good look). It's better to create a metric with a new
  name to change types.

### Testing
#### Unit testing metrics
To ensure that your metrics are behaving the way you expect, you can inspect the values of metrics in unit tests.

Exmaple unit test setup:
```julia
# reset all metrics so the results are reproducible (note that multithreading will impact metrics testing!)
Metrics.zero_all_metrics()

# do work here that should cause metrics to change (or not!)

# check that your metrics have the expected value
@test Metrics.value_of("metadata_proto_migration_commit_count") == 1
```


#### Testing locally

You can use Prometheus and Grafana to test metrics locally.

Depending on platform (assuming linux), follow the default installation instructions for both:
- https://prometheus.io/docs/introduction/first_steps/
- https://grafana.com/grafana/download

Then configure prometheus to scrape the local instance by adding the following section into prometheus.yml:
```
  - job_name: 'rai-compute'
    scrape_interval: 1s
    static_configs:
      - targets: ['localhost:8010']
```
Upon starting grafana, you can connect it to prometheus data source which should give you access to all exported metrics.
