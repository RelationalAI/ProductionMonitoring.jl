using Base.Threads


# Dictionary synchronized by a SpinLock. This is used as a building block by
# ParallelDict.
struct _SyncDict{Dict}
    lock::Base.Threads.SpinLock
    dict::Dict

    function _SyncDict{Dict}() where {Dict}
        new{Dict}(Base.Threads.SpinLock(), Dict())
    end
end

Base.get(sd::_SyncDict, k, default) = @lock sd.lock Base.get(sd.dict, k, default)
Base.setindex!(sd::_SyncDict, v, k) = @lock sd.lock Base.setindex!(sd.dict, v, k)
Base.delete!(sd::_SyncDict, k) = @lock sd.lock Base.delete!(sd.dict, k)

struct _Missing end
const _missing = _Missing()

function memoize!(sd::_SyncDict{Dict}, k, v) where {Dict}
    @lock sd.lock begin
        tmp = Base.get(sd.dict, k, _missing)
        !isa(tmp, _Missing) && return tmp
        sd.dict[k] = v
        return v
    end
end

# If every thread simultaneously accesses a ParallelDict, this gives about
# about 1/8th of them blocking. In practice you're never hitting dictionaries
# this hard, so this NUM_DICTS will make contention very rare.
const NUM_DICTS = 4*Threads.nthreads()

"""
    ParallelDict{K,V,Dict}()

A threadsafe, low-contention dictionary implemented by underlying type `Dict`.
The parallel dictionary is implemented by `4*Threads.nthreads()` individual dictionaries.
To find the dictionary responsible for key `k`, we use `Base.hash(k)` modulo the number
of dictionaries. Each dictionary is guarded by a `Base.Threads.SpinLock`.

Use `Base.setindex!(dict, v, k)`, `Base.get(dict, k, default)`, and `Base.delete!(dict, k)`
to set, get, and delete entries.

For convenience, the method `memoize!(dict, k, v)` returns the previous entry for `k`
if one exists; otherwise it stores `(k => v)` and returns v. This is done atomically.

ParallelDict is a heavyweight dictionary that allocates many objects. It's not
recommended for situations where you need millions of tiny dictionaries.
"""
struct ParallelDict{K,V,Dict}
    dicts::Vector{_SyncDict{Dict}}

    function ParallelDict{K,V,Dict}() where {K,V,Dict}
        dicts = [_SyncDict{Dict}() for i in 1:NUM_DICTS]
        new{K,V,Dict}(dicts)
    end
end

# Copied from (an old commit) from Base, here:
# https://github.com/JuliaLang/julia/pull/44513/files#diff-e65e6dda266d399ce8ce1e680ce619ee7532bb931bd789f8f684bcbcae376bb5L169
_hashindex(key, sz) = (((hash(key)::UInt % Int) & (sz-1)) + 1)::Int

function _dict_for(pdict::ParallelDict{K,V,D}, k) where {K,V,D}
    i = _hashindex(k, NUM_DICTS)
    return @inbounds pdict.dicts[i]
end

Base.get(pdict::ParallelDict, k, default) = Base.get(_dict_for(pdict, k), k, default)
Base.setindex!(pdict::ParallelDict, v, k) = Base.setindex!(_dict_for(pdict, k), v, k)
Base.delete!(pdict::ParallelDict, k) = Base.delete!(_dict_for(pdict, k), k)
memoize!(pdict::ParallelDict, k, v) = memoize!(_dict_for(pdict, k), k, v)

export ParallelDict, memoize!
