"""
    WeakRefCache{K,V}()

Create a cache of weak references to values of type V. Internally, `WeakRefCache{K,V}`
uses a `Dict{K,WeakRef}` to store the weak references to objects of type V.

Use `Base.setindex!(cache, v, k)` to add or update a cache entry `(k => v)`.
When GC collects the object v, it will replace the WeakRef to v with `WeakRef(nothing)`.

Use `Base.get(cache, key, default)` to retrieve entries from the cache. If the key
is undefined or is a `WeakRef(nothing)`, default is returned.

When `Base.setindex!(...)` is called, `WeakRefCache{K,V}` also checks one additional entry
in the cache; if it is a `WeakRef(Nothing)`, then that entry is removed. In this way
values that have been garbage collected are gradually removed from the cache.
"""
struct WeakRefCache{K,V}
    dict::Dict{K,WeakRef}

    function WeakRefCache{K,V}() where {K,V}
        new{K,V}(Dict{K,WeakRef}())
    end
end

const _zeroed_weakref = WeakRef(nothing)

# To distinguish between a WeakRef nothing and a user-supplied nothing from
# setindex!(cache, nothing, k), we replace user nothing with _nothing
struct _Nothing end
const _nothing = _Nothing()

function Base.get(cache::WeakRefCache{K,V}, k::K, default) where {K,V}
    #TODO: verify type inference
    value = get(cache.dict, k, _zeroed_weakref).value
    if value === nothing
        return default
    elseif (Nothing <: V) && value === _nothing
        return nothing
    else
        return value::V
    end
end

function Base.setindex!(cache::WeakRefCache{K,V}, v::V, k::K) where {K,V}
    # Gradual purging of WeakRef(nothing) entries, where the pointed-to object has
    # been garbage collected
    if 10*length(cache.dict) >= length(cache.dict.keys)
        # If the first entry at or after where k will be stored is a WeakRef(nothing),
        # delete it. This is so we gradually clear out WeakRefs to objects that have
        # been garbage collected.
        index = _hashindex(k, length(cache.dict.keys))
        i = Base.skip_deleted(cache.dict, index)
        if i !== 0
            if cache.dict.vals[i].value === nothing
                Base._delete!(cache.dict, i)
            end
        end
    end

    # Replace user value 'nothing' with our _nothing, so we can distinguish
    # WeakRef(nothing) (indicating a value that was garbage collected) from a
    # cache[key]=nothing stored by the user.
    v_put = v
    if (Nothing <: V) && v_put === nothing
        v_put = _nothing
    end
    setindex!(cache.dict, WeakRef(v_put), k)
    return v
end

export WeakRefCache
