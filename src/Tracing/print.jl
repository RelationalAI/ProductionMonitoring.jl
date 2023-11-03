## Implementation/override for the TracingBackend interface
## representing the PrintBackend

import Logging
import Printf: @sprintf

struct PrintBackend <: TracingBackend end
backend_mapping["PRINT"] = PrintBackend

## Helper function for padding
function print_prefix(span::Span)
    "│ "^span.nesting
end

## Hook Interface override: `span_start`
function span_start(::Type{PrintBackend}, span::Span, ctx::ActiveCtx)
    println(
        print_prefix(span),
        "┌─ $(span.name)",#(trace=$(span.span_context.traceid), span=$(span.id))",
    )
end

## Hook Interface override: `span_end`
function span_end(::Type{PrintBackend}, span::Span, ctx::ActiveCtx)
    prefix = print_prefix(span)
    duration = (span.end_time - span.start_time) / 1000000000
    span_aggs = _get_span_aggs(span)
    span_mtrcs = _get_span_metrics(span)
    if span.parent_span.id == 0

        if length(keys(span_aggs)) > 0
            println(prefix, "│ Aggregate span duration (s):")
        end

        # printout durations
        for (k, v) in span_aggs
            p = split(k, '.')
            pf = "    "^(length(p) - 2)
            print(prefix, "│   ", lpad(@sprintf("%.5f", v), 10, ' '), " = ")
            print(
                lpad(@sprintf("%.1f", (v / duration) * 100.0), 4, ' '),
                "% = $pf ",
                last(p),
            )
            println()
        end

        # printout metrics
        if length(keys(span_mtrcs)) > 0
            println(prefix, "│ Aggregate Metrics :")
        end

        for (k, v) in span_mtrcs
            print(prefix, "│   ", lpad(string(k), 10, ' '), " , ")
            print(lpad(@sprintf("%.5f", v), 4, ' '))
            println()
        end

    else
        parent_span = span.parent_span
        k = string(parent_span.name, ".", span.name)
        span_merge_aggs!(parent_span, k, duration)
        # bubble up durations
        for (k, v) in span_aggs
            nk = string(parent_span.name, ".", k)
            span_merge_aggs!(span.parent_span, nk, v)
        end
        # bubble up metrics
        for (k, v) in span_mtrcs
            span_merge_metrics!(span.parent_span, k, v)
        end
    end

    println(print_prefix(span), "└─ $(span.name) duration: ", @sprintf("%.5f", duration))
end

## Hook Interface override: `span_attribute`
function span_attribute(
    ::Type{PrintBackend},
    key::String,
    value::AttributeValue,
    span::Span,
    ctx::ActiveCtx,
)
    prefix = print_prefix(span)
    str = attribute_to_string(value)
    println(prefix, "│ $key=$(replace(str, "\n" => "\n$(prefix)│ " ))")
end
