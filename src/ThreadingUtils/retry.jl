# Try to evaluate fn(). If it throws or doesn't return within `timeout` seconds, we retry, up to
# `max_retries` times. If the max retries are exhausted, an ErrorException is thrown.
function do_with_retry(fn, ::Type{T}; timeout=240, max_retries=8, what="do_with_retry") where T
    ch = Channel{T}(Inf)
    done_flag = Ref{Bool}(false)

    @spawn_with_error_log begin
        t0 = time()
        for i in 1:max_retries
            done_flag[] && return nothing
            @spawn_with_error_log _try_once(fn, ch, done_flag, i == max_retries)
            sleep(timeout)
        end
        if !done_flag[]
            e = ErrorException("failed after $(time()-t0)s: $(what)")
            close(ch, e)
        end
    end

    try
        return take!(ch)
    finally
        done_flag[] = true
    end
end

function _try_once(fn, ch::Channel{T}, done_flag::Ref{Bool}, last_try::Bool) where T
    try
        r = fn()
        done_flag[] = true
        put!(ch, r)
    catch e
        if last_try && !done_flag[]
            close(ch, e)
        end
    end
    return nothing
end
