macro error_with_current_exceptions(msg, exs...)
    return restore_callsite_source_position!(esc(:(
        $Base.@error string($msg, "\n", $TransactionLogging.current_exceptions_to_string($Base.current_exceptions())) $(exs...)
        )), __source__)
end

macro warn_with_current_exceptions(msg, exs...)
    return restore_callsite_source_position!(esc(:(
        $Base.@warn string($msg, "\n", $TransactionLogging.current_exceptions_to_string($Base.current_exceptions())) $(exs...)
        )), __source__)
end

macro error_every_n_seconds(sec, msg, exs...)
    return restore_callsite_source_position!(
        esc(:($Base.@error $msg log_every_n_seconds=$sec $(exs...))),
        __source__,
    )
end

macro warn_every_n_seconds(sec, msg, exs...)
    return restore_callsite_source_position!(
        esc(:($Base.@warn $msg log_every_n_seconds=$sec $(exs...))),
        __source__,
    )
end

macro info_every_n_seconds(sec, msg, exs...)
    return restore_callsite_source_position!(
        esc(:($Base.@info $msg log_every_n_seconds=$sec $(exs...))),
        __source__,
    )
end

macro warn_with_current_backtrace(msg, exs...)
    return restore_callsite_source_position!(esc(:(
        $Base.@warn string($msg, "\n", $TransactionLogging.current_stacktrace_to_string($Base.backtrace())) $(exs...)
        )), __source__)
end
