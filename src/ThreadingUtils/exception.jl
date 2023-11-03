import ExceptionUnwrapping

"""
    FastCapturedException(exc::Any, catch_backtrace())

Instances of `FastCapturedException` carry an arbitrary object (not necessarily
one that is an instance of the `Exception` type since users can throw arbitrary
objects) and a raw backtrace. Both the carried object thrown as an exception and
the backtrace are processed at the time when the instance of
`FastCapturedException` is printed onto some stream (e.g., via
`Base.showerror`).

Always prefer using an `FastCapturedException` over a `CapturedException` one
except for the cases in which the captured exception has to be sent over the
wire to another process (e.g., using distributed RPC calls).
"""
struct FastCapturedException <: Exception
    ex::Any
    bt::Vector
end
ExceptionUnwrapping.unwrap_exception(ce::FastCapturedException) = ce.ex

# NOTE: I considered adding a helper constructor, FastCapturedException(e), which
# automatically captures the catch_backtrace(), but it seems like it's better to keep that
# explicit at the callsite, so you can be sure you're capturing the right backtrace.

function Base.showerror(io::IO, ce::FastCapturedException)
    # showerror will process the backtrace, if needed.
    showerror(io, ce.ex, ce.bt; backtrace=true)
end
