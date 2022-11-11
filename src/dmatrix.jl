
"""
    DMatrix

Data structure for storing data which can be understood by an xgboost [`Booster`](@ref).
These can store both features and targets.  The `DMatrix` object itself is opaque
and once constructed data cannot be retrieved from it.  For this reason it does not possess
any kind of array interface, however it does have a knowable `size` (main data only).

Aside from a primary array, the `DMatrix` object can have various "info" fields associated with it.
Training target variables are stored as a special info field with the name `label`, see
[`setinfo!`](@ref) and [`setinfos!`](@ref).  Unlike the parimary data the info fields are retrievable,
see [`getinfo`](@ref) and [`getlabel`](@ref).

This object has special efficient constructors for `SparseMatrixCSC` objects (the default sparse
matrix type from the `SparseArrays` stdlib).

The `DMatrix` can interpret `missing` data, its argument can be an `AbstractMatrix{Union{<:Real,Missing}}`.
By default, any `NaN` value will also be interpreted as `missing`.

Note that the xgboost library internally uses `Float32` to represent all data, so input data is
automatically copied unless provided in this format.  Unfortunately because of the different
representations used by C and Julia, any non `Transpose` matrix will also be copied.

## Constructors
```julia
DMatrix(X::AbstractMatrix; kw...)
DMatrix(X::AbstractMatrix, y::AbstractVector; kw...)
DMatrix((X, y); kw...)
DMatrix(tbl; kw...)
DMatrix(tbl, y; kw...)
DMatrix(tbl, yname::Symbol; kw...)
```

## Arguments
- `X`: A matrix that is the primary data wrapped by the `DMatrix`.  Elements can be `missing`.
    Matrices with `Float32` eleemnts do not need to be copied.
- `y`: Data to assign to the `label` info field.  This is the target variable used in training.
    Can also be set with the `label` keyword.
- `tbl`: The input matrix in tabular form.  `tbl` must satisfy the Tables.jl interface.
    If data is passed in tabular form feature names will be set automatically but can
    be overriden with the keyword argument.
- `yname`: If passed a tabular argument `tbl`, `yname` is the name of the column which holds the
    label data.  It will automatically be omitted from the features.

### Keyword Arguments
- `missing_value`: The `Float32` value of elements of input data to be interpreted as `missing`,
    defaults to `NaN32`.
- `label`: Training target data, this is the same as the `y` argument above, i.e.
    `DMatrix(X,y)` and `DMatrix(X, label=y)` are equivalent.
- `weight`: An `AbstractVector` of weights for each data point.  This array must have lenght
    equal to the number of rows of the main data matrix.
- `base_margin`: Sets the global bias for a boosted model trained on this dataset, see
    https://xgboost.readthedocs.io/en/stable/prediction.html#base-margin

## Examples
```julia
(X, y) = (randn(10,3), randn(10))

# the following are all equivalent
DMatrix(X, y)
DMatrix((X, y))
DMatrix(X, label=y)

DMatrix(X, y, feature_names=["a", "b", "c"])  # explicitly set feature names

df = DataFrame(A=randn(10), B=randn(10))
DMatrix(df)  # has feature names ["A", "B"] but no label
```
"""
mutable struct DMatrix <: AbstractMatrix{Float32}
    handle::DMatrixHandle
    
    # this is not allocated on initialization because it's not needed for any core functionality
    data::Union{Nothing,SparseMatrixCSR{0,Float32,UInt64}}

    function DMatrix(handle::Ptr{Nothing};
                     feature_names::AbstractVector{<:AbstractString}=String[],
                     kw...
                    )
        dm = new(handle, nothing)
        setinfos!(dm; kw...)
        isempty(feature_names) || setfeaturenames!(dm, feature_names)
        finalizer(x -> xgbcall(XGDMatrixFree, x.handle), dm)
    end
end

function _setinfo!(dm::DMatrix, name::AbstractString, info::AbstractVector{<:AbstractFloat})
    xgbcall(XGDMatrixSetFloatInfo, dm.handle, name, convert(Vector{Cfloat}, info), length(info))
    info
end

function _setinfo!(dm::DMatrix, name::AbstractString, info::AbstractVector{<:Integer})
    xgbcall(XGDMatrixSetUIntInfo, dm.handle, name, convert(Vector{Cuint}, info), length(info))
    info
end



"""
    setinfo!(dm::DMatrix, name, info)

Set `DMatrix` ancillary info, for example `:label` or `:weight`.  `name` can be a string or
a `Symbol`.  See [`DMatrix`](@ref).
"""
function setinfo!(dm::DMatrix, name::AbstractString, info::AbstractVector)
    if name ∈ ("label", "weight", "base_margin")
        info = convert(Vector{Float32}, info)
    elseif name ∈ ("group",)
        info = convert(Vector{Int32}, info)
    end
    _setinfo!(dm, name, info)
end
setinfo!(dm::DMatrix, name::Symbol, info) = setinfo!(dm, string(name), info)

"""
    setlabel!(dm::DMatrix, y)

Set the label data of `dm` to `y`.  Equivalent to `setinfo!(dm, "label", y)`.
"""
setlabel!(dm::DMatrix, info::AbstractVector) = setinfo!(dm, "label", info)

"""
    setinfos!(dm::DMatrix; kw...)

Make arbitrarily many calls to [`setinfo!`](@ref) via keyword arguments.  This function is called by all
`DMatrix` constructors, i.e. `DMatrix(X; kw...)` is equivalent to `setinfos!(DMatrix(X); kw...)`.
"""
setinfos!(dm::DMatrix; kw...) = foreach(kv -> setinfo!(dm, kv[1], kv[2]), kw)

_getinfo_call(::Type{<:AbstractFloat}) = XGDMatrixGetFloatInfo
_getinfo_call(::Type{<:Integer}) = XGDMatrixGetUIntInfo

"""
    getinfo(dm::DMatrix, T, name)

Get `DMatrix` info with name `name`.  Users must specify the underlying data type due to limitations of
the xgboost library.  One must have `T<:AbstractFloat` to get floating point data (e.g. `label`, `weight`),
or `T<:Integer` to get integer data.  The output will be converted to `Vector{T}` in all cases.
`name` can be either a string or `Symbol`.
"""
function getinfo(dm::DMatrix, ::Type{T}, name::AbstractString) where {T<:Real}
    olen = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Cfloat}}()
    xgbcall(_getinfo_call(T), dm.handle, name, olen, o)
    x = unsafe_wrap(Array, o[], olen[])
    convert(Vector{T}, x)
end
getinfo(dm::DMatrix, t::Type, name::Symbol) = getinfo(dm, t, string(name))

"""
    load(DMatrix, fname; silent=true, kw...)

Load a `DMatrix` from file with name `fname`.  The matrix must have been serialized with a call to
`save(::DMatrix, fname)`.  If `silent` the xgboost library will print logs to `stdout`.
Additional keyword arguments are passed to the `DMatrix` on construction.
"""
function load(::Type{DMatrix}, fname::AbstractString; silent::Bool=true, kw...)
    o = Ref{DMatrixHandle}()
    xgbcall(XGDMatrixCreateFromFile, fname, silent, o)
    DMatrix(o[], kw...)
end

function _dmatrix(x::AbstractMatrix{T}; missing_value::Float32=NaN32, kw...) where {T<:Real}
    o = Ref{DMatrixHandle}()
    sz = reverse(size(x))
    xp = convert(Matrix{Cfloat}, x)
    xgbcall(XGDMatrixCreateFromMat, xp, sz[1], sz[2], missing_value, o)
    DMatrix(o[]; kw...)
end

function DMatrix(x::AbstractMatrix{T}; kw...) where {T<:Real}
    # sadly, this copying is unavoidable
    _dmatrix(convert(Matrix{Float32}, transpose(x)); kw...)
end

# ideally these would be recursive but can't be bothered
DMatrix(x::Transpose{T}; kw...) where {T<:Real} = _dmatrix(parent(x); kw...)
DMatrix(x::Adjoint{T}; kw...) where {T<:Real} = _dmatrix(parent(x); kw...)

function DMatrix(x::AbstractMatrix{Union{Missing,T}}; kw...) where {T<:Real}
    # we try to make it so that we only have to copy once
    x′ = map(ξ -> ismissing(ξ) ? NaN32 : Float32(ξ), transpose(x))
    x′ = convert(Matrix{Cfloat}, x′)
    _dmatrix(x′; missing_value=NaN32, kw...)
end

function _sparse_csc_components(x::SparseMatrixCSC)
    colptr = convert(Vector{Csize_t}, x.colptr .- 1)
    rowval = convert(Vector{Cuint}, x.rowval .- 1)
    nzval = convert(Vector{Cfloat}, x.nzval)
    (colptr, rowval, nzval)
end

function DMatrix(x::SparseMatrixCSC{<:Real,<:Integer}; kw...)
    o = Ref{DMatrixHandle}()
    (colptr, rowval, nzval) = _sparse_csc_components(x)
    xgbcall(XGDMatrixCreateFromCSCEx, colptr, rowval, nzval,
            size(colptr,1), nnz(x), size(x,1),
            o,
           )
    DMatrix(o[]; kw...)
end

#TODO: transpose sparse method

"""
    slice(dm::DMatrix, idx; kw...)

Create a new `DMatrix` out of the subset of rows of `dm` given by indices `idx`.
Since `DMatrix` is opaque it's not possible to verify the result, so for most use cases
it is recommended to take slices before converting to `DMatrix`.  Additional keyword
arguments are passed to the newly constructed slice.

This can also be called via `Base.getindex`, for example, the following are equivalent
```julia
slice(dm, 1:4)
dm[1:4, :]  # second argument *must* be `:` as column slices are not supported.
```
"""
function slice(dm::DMatrix, idx::AbstractVector{<:Integer}; kw...)
    o = Ref{DMatrixHandle}()
    idx = convert(Vector{Cint}, idx .- 1)
    XGDMatrixSliceDMatrix(dm.handle, idx, length(idx), o)
    DMatrix(o[]; kw...)
end

# we require the colon for consistent array semantics
Base.getindex(dm::DMatrix, idx::AbstractVector{<:Integer}, ::Colon; kw...) = slice(dm, idx; kw...)

DMatrix(X::AbstractMatrix, y::AbstractVector; kw...) = DMatrix(X; label=y, kw...)

DMatrix(Xy::Tuple; kw...) = DMatrix(Xy[1], Xy[2]; kw...)

DMatrix(dm::DMatrix) = dm

function DMatrix(tbl;
                 feature_names::AbstractVector{<:AbstractString}=collect(string.(Tables.columnnames(tbl))),
                 kw...
                )
    if !Tables.istable(tbl)
        throw(ArgumentError("DMatrix requires either an AbstractMatrix or table satisfying the Tables.jl interface"))
    end
    DMatrix(Tables.matrix(tbl); feature_names, kw...)
end

DMatrix(tbl, y::AbstractVector; kw...) = DMatrix(tbl; label=y, kw...)

function DMatrix(tbl, ycol::Symbol; kw...)
    Xcols = [n for n ∈ Tables.columnnames(tbl) if n ≠ ycol]
    tbl′ = NamedTuple(n=>Tables.getcolumn(tbl, n) for n ∈ Xcols)
    DMatrix(tbl′, Tables.getcolumn(tbl, ycol); kw...)
end

"""
    nrows(dm::DMatrix)

Returns the number of rows of the `DMatrix`.
"""
function nrows(dm::DMatrix)
    o = Ref{Lib.bst_ulong}()
    xgbcall(XGDMatrixNumRow, dm.handle, o)
    convert(Int, o[])
end

"""
    ncols(dm::DMatrix)

Returns the number of columns of the `DMatrix`.  Note that this will only count columns of the main data
(the `X` argument to the constructor).  The value returned is independent of the presence of labels.
In particular `size(X,2) == ncols(DMatrix(X))`.
"""
function ncols(dm::DMatrix)
    o = Ref{Lib.bst_ulong}()
    xgbcall(XGDMatrixNumCol, dm.handle, o)
    convert(Int, o[])
end

"""
    size(dm::DMatrix, [dim])

Returns the `size` of the primary data of the `DMatrix`.  Note that this only accounts for the primary data
and is independent of whether labels or any other ancillary data are present.  In particular
`size(X) == size(DMatrix(X))`.
"""
Base.size(dm::DMatrix) = (nrows(dm), ncols(dm))
function Base.size(dm::DMatrix, ax::Integer)
    if ax == 1
        nrows(dm)
    elseif ax == 2
        ncols(dm)
    else
        throw(ArgumentError("size: DMatrix only has 2 indices"))
    end
end

"""
    getdata(dm::DMatrix)

Get the data in the `DMatrix` as a `SparseMatrixCSR`.  This involves allocating new buffers and is not
required for any core functionality and so should be avoided.
"""
function getdata(dm::DMatrix)
    (m, n) = size(dm)
    rowptr = Vector{UInt64}(undef, m+1)
    colval = Vector{UInt32}(undef, nnz(dm))
    data = Vector{Float32}(undef, nnz(dm))
    cfg = JSON3.write(Dict())
    xgbcall(XGDMatrixGetDataAsCSR, dm.handle, cfg, rowptr, colval, data)
    SparseMatrixCSR{0}(m, n, rowptr, UInt64.(colval), data)
end

"""
    getdata!(dm::DMatrix)

Allocate and store the underlying data using [`getdata`](@ref).  When `getdata!` is called the resulting
matrix is stored permanently as a field of `DMatrix`.
"""
getdata!(dm::DMatrix) = (dm.data = getdata(dm))

"""
    hasdata(dm::DMatrix)

Whether the data within the `DMatrix` has been allocated and stored as an `AbstractMatrix{Float32}` field
of the `DMatrix`.  If this returns `false` it means that additional allocations are required to index
the `DMatrix`.
"""
hasdata(dm::DMatrix) = !isnothing(dm.data)

@propagate_inbounds function Base.getindex(dm::DMatrix, idx...)
    hasdata(dm) || getdata!(dm)
    @inbounds getindex(dm.data, idx...)
end

"""
    getlabel(dm::DMatrix)

Retrieve the label (training target) data from the `DMatrix`.  Returns `Float32[]` if not set.
"""
getlabel(dm::DMatrix) = getinfo(dm, Float32, "label")

"""
    getweights(dm::DMatrix)

Get data training weights.  Returns `Float32[]` if not set.
"""
getweights(dm::DMatrix) = getinfo(dm, Float32, "weight")

"""
    save(dm::DMatrix, fname; silent=true)

Save the `DMatrix` to file `fname` in an opaque (xgboost-specific) serialization format.
Will print logs to `stdout` unless `silent`.
"""
function save(dm::DMatrix, fname::AbstractString; silent::Bool=true)
    xgbcall(XGDMatrixSaveBinary, dm.handle, fname, convert(Cint, silent))
    fname
end

"""
    setfeatureinfo!(dm::DMatrix, info_name, strs)

Sets feature metadata in `dm`.  Valid options for `info_name` are `"feature_name"` and `"feature_type"`.
`strs` must be a rank-1 array of strings.  See [`setfeaturenames!`](@ref).
"""
function setfeatureinfo!(dm::DMatrix, k::AbstractString, strs::AbstractVector{<:AbstractString})
    strs = convert(Vector{String}, strs)
    xgbcall(XGDMatrixSetStrFeatureInfo, dm.handle, k, strs, length(strs))
    strs
end

"""
    setfeaturenames!(dm::DMatrix, names)

Sets the names of the features in `dm`.  This can be used by [`Booster`](@ref) for reporting.
`names` must be a rank-1 array of strings with length equal to the number of features.
Note that this will be set automatically by `DMatrix` constructors from table objects.
"""
setfeaturenames!(dm::DMatrix, names::AbstractVector{<:AbstractString}) = setfeatureinfo!(dm, "feature_name", names)

"""
    getfeatureinfo(dm::DMatrix, info_name)

Get feature info that was set via [`setfeatureinfo!`](@ref).  Valid options for `info_name` are
`"feature_name"` and `"feature_type"`.  See [`getfeaturenames`](@ref).
"""
function getfeatureinfo(dm::DMatrix, k::AbstractString)
    olen = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Ptr{Cchar}}}()
    xgbcall(XGDMatrixGetStrFeatureInfo, dm.handle, k, olen, o)
    strs = unsafe_wrap(Array, o[], olen[])
    map(unsafe_string, strs)
end

"""
    getfeaturenames(dm::DMatrix)

Get the names of features in `dm`.
"""
getfeaturenames(dm::DMatrix) = getfeatureinfo(dm, "feature_name")

function getfeaturenames(dms::AbstractVector{DMatrix}; validate::Bool=false)
    isempty(dms) && return String[]
    fs = getfeaturenames(dms[1])
    if validate && any(≠(fs), getfeaturenames.(dms))
        throw(ArgumentError("got data with inconsistent feature names; use validate=false to ignore"))
    end
    fs
end


"""
    proxy(DMatrix)

Create a special "proxy" `DMatrix` object.  These are used internally for setting data incrementally during
iteration of datasets.
"""
function proxy(::Type{DMatrix})
    o = Ref{DMatrixHandle}()
    xgbcall(XGProxyDMatrixCreate, o)
    DMatrix(o[])
end

_numpy_json_typestr(::Type{<:AbstractFloat}) = "f"
_numpy_json_typestr(::Type{<:Integer}) = "i"
_numpy_json_typestr(::Type{Bool}) = "b"
_numpy_json_typestr(::Type{<:Complex{<:AbstractFloat}}) = "c"

numpy_json_typestr(::Type{T}) where {T<:Number} = string("<",_numpy_json_typestr(T),sizeof(T))

function numpy_json_info(x::AbstractMatrix; read_only::Bool=false)
    info = Dict("data"=>(convert(Csize_t, pointer(x)), read_only),
                "shape"=>reverse(size(x)),
                "typestr"=>numpy_json_typestr(eltype(x)),
                "version"=>3,
               )
    JSON3.write(info)
end

#TODO: still a little worried about ownership here
#TODO: sparse data for iterator and proper missings handling

"""
    setproxy!(dm::DMatrix, X::AbstractMatrix; kw...)

Set data in a "proxy" `DMatrix` like one created with `proxy(DMatrix)`.  Keyword arguments
are set to the passed matrix.
"""
function setproxy!(dm::DMatrix, x::AbstractMatrix; kw...)
    x = convert(Matrix, transpose(x))
    GC.@preserve x begin
        info = numpy_json_info(x)
        xgbcall(XGProxyDMatrixSetDataDense, dm.handle, info)
    end
    setinfos!(dm; kw...)
    dm
end
setproxy!(dm::DMatrix, X::AbstractMatrix, y::AbstractVector; kw...) = setproxy!(dm, X; label=y, kw...)


"""
    DataIterator

A data structure which wraps an iterator which iteratively provides data for a `DMatrix`.  This can be
used e.g. to aid with loading data into external memory into a `DMatrix` object that can be used by
`Booster`.

Users should not typically have to deal with `DataIterator` directly as it is essentially a wrapper
around a normal Julia iterator for the purpose of achieving compatiblity with the underlying xgboost
library calls.  See [`fromiterator`](@ref) for how to construct a `DMatrix` from an iterator.
"""
mutable struct DataIterator{T<:Stateful}
    iter::T
    proxy::DMatrix

    DataIterator(iter::Stateful) = new{typeof(iter)}(iter, proxy(DMatrix))
end

DataIterator(x) = DataIterator(Stateful(x))

# Julia 1.6 has a missing method for reset! so we use two argument method here
Iterators.reset!(itr::DataIterator) = reset!(itr.iter, itr.iter.itr)

Base.isempty(itr::DataIterator) = isempty(itr.iter)

function Base.popfirst!(itr::DataIterator)
    x = popfirst!(itr.iter)
    # TODO: make this a little more intelligent
    args = haskey(x, :y) ? (x.X, x.y) : (x.X,)
    kw = (;(k=>v for (k,v) ∈ pairs(x) if k ∉ (:X, :y))...)
    setproxy!(itr.proxy, args...; kw...)
    x
end

function _unsafe_dataiter_next(ptr::Ptr)
    itr = unsafe_pointer_to_objref(ptr)::DataIterator
    try
        if isempty(itr)
            Cint(0)
        else
            popfirst!(itr)
            Cint(1)
        end
    catch err
        @error("got error during C callback for next iteration state", exception=(err, catch_backtrace()))
        Cint(-1)
    end
end

function _unsafe_dataiter_reset(ptr::Ptr)
    itr = unsafe_pointer_to_objref(ptr)::DataIterator
    try
        reset!(itr)
    catch err
        @error("got error during C callback for resetting iterator", exception=(err, catch_backtrace()))
    end
    nothing
end

function _dmatrix_caching_config_json(;cache_prefix::AbstractString,
                                      nthreads::Union{Integer,Nothing},
                                      missing_value::Float32=NaN32,
                                     )
    d = Dict("missing"=>"__NAN_STR__",
             "cache_prefix"=>cache_prefix,
            )
    isnothing(nthreads) || (d["nthreads"] = nthreads)
    # this is to strip out the special Float32 values to representations it'll accept
    nanstr = if isnan(missing_value)
        "NaN"
    elseif !isfinite(missing_value)
        missing_value > 0 ? "Inf" : "-Inf"
    else
        repr(missing_value)
    end
    # xgboost allows nan and inf which JSON3 thinks is invalid
    replace(JSON3.write(d), "\"__NAN_STR__\""=>nanstr)
end

function DMatrix(itr::DataIterator;
                 missing_value::Float32=NaN32,
                 cache_prefix::AbstractString=joinpath(tempdir(),"xgb-cache"),
                 nthreads::Union{Integer,Nothing}=nothing,
                 kw...
                )
    o = Ref{DMatrixHandle}()

    ptr_rst = @cfunction(_unsafe_dataiter_reset, Cvoid, (Ptr{Cvoid},))
    ptr_next = @cfunction(_unsafe_dataiter_next, Cint, (Ptr{Cvoid},))

    xgbcall(XGDMatrixCreateFromCallback, pointer_from_objref(itr),
            itr.proxy.handle,
            ptr_rst, ptr_next,
            _dmatrix_caching_config_json(;cache_prefix, nthreads, missing_value),
            o,
           )

    DMatrix(o[]; kw...)
end

"""
    fromiterator(DMatrix, itr; cache_prefix=joinpath(tempdir(),"xgb-cache"), nthreads=nothing, kw...)

Create a [`DMatrix`](@ref) from an iterable object.  `itr` can be any object that implements Julia's `Base`
iteration protocol.  Objects returned by the iterator must be key-value collections with `Symbol` keys
with `X` as the main matrix and `y` as labels.  For example
```julia
(X=randn(10,2), y=randn(10))
```
Other keys will be interpreted as keyword arguments to `DMatrix`.

When this is called XGBoost will start caching data provided by the iterator on disk in a format that it
likes.  All cache files generated this way will have a the prefix `cache_prefix` which is in `/tmp`
by default.

What exactly xgboost does with `nthreads` is a bit mysterious, `nothing` gives the library's default.

Additional keyword arguments are passed to a `DMatrix` constructor.
"""
fromiterator(::Type{DMatrix}, itr; kw...) = DMatrix(DataIterator(itr); kw...)

"""
    nnz(dm::DMatrix)

Get the number of non-zero values in the `DMatrix`.  Note that this is guaranteed to give the same number
of non-zero values as in the `SparseMatrixCSR` constructed from the `DMatrix`.
"""
function SparseArrays.nnz(dm::DMatrix)
    o = Ref{Lib.bst_ulong}()
    xgbcall(XGDMatrixNumNonMissing, dm.handle, o)
    Int(o[])
end

