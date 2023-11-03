# ProductionMonitoring.jl

[![Build Status](https://github.com/RelationalAI/ProductionMonitoring.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/RelationalAI/ProductionMonitoring.jl/actions/workflows/CI.yml?query=branch%3Amain)

This package is VERY MUCH WORK-IN-PROGRESS!

We have taken all of the packages that we've written internally for observability in production, and dumped them in here. The tests mostly pass, but I'm not sure if this actually works yet... We'll need some help cleaning this up I think.

This package consists of the following sub-packages / sub-directories:
- DebugLevels
- Metrics
- ThreadingUtils
- Tracing
- TransactionLogging

It's probably better to read all of their individual READMEs to see what they do, but basically this package provides:
- Logging
- Metrics collection and exporting
- Tracing / spans

all of which can target either a **text output backend** or can be configured to talk to **DataDog**, via a locally running DataDog agent.
At RelationalAI, we talk to DataDog via an agent running on the same host (in the same pod? I'm actually not sure..), where the datadog port is passed into our application at startup by kubernetes. We use datadog for logging, traces, metrics, and continuous profiling (via [ddprof](https://github.com/DataDog/ddprof), where we've recently helped them add support for Julia).
