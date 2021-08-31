import Adapt: adapt, adapt_storage
using  LinearAlgebra: Cholesky
using Zygote: IdSet
import Functors: Functors, @functor, functor, fmap, isleaf

trainable(m) = functor(m)[1]

"""
    testmode!(m, mode = true)

Set a layer or model's test mode (see below).
Using `:auto` mode will treat any gradient computation as training.

_Note_: if you manually set a model into test mode, you need to manually place
it back into train mode during training phase.

Possible values include:
- `false` for training
- `true` for testing
- `:auto` or `nothing` for Flux to detect the mode automatically
"""
testmode!(m, mode = true) = (foreach(x -> testmode!(x, mode), trainable(m)); m)

"""
    trainmode!(m, mode = true)

Set a layer of model's train mode (see below).
Symmetric to [`testmode!`](@ref) (i.e. `trainmode!(m, mode) == testmode!(m, !mode)`).

_Note_: if you manually set a model into train mode, you need to manually place
it into test mode during testing phase.

Possible values include:
- `true` for training
- `false` for testing
- `:auto` or `nothing` for Flux to detect the mode automatically
"""
trainmode!(m, mode = true) = mode isa Bool ? testmode!(m, !mode) : testmode!(m, mode)

params!(p::Params, x::AbstractArray{<:Number}, seen = IdSet()) = push!(p, x)

function params!(p::Params, x, seen = IdSet())
  x in seen && return
  push!(seen, x)
  for child in trainable(x)
    params!(p, child, seen)
  end
end

function params(m...)
  ps = Params()
  params!(ps, m)
  return ps
end

function loadparams!(m, xs)
  for (p, x) in zip(params(m), xs)
    size(p) == size(x) ||
      error("Expected param size $(size(p)), got $(size(x))")
    copyto!(p, x)
  end
end

# CPU/GPU movement conveniences
"""
    cpu(m)

Moves `m` onto the CPU.

This utility uses [`@functor`](@ref) to properly move structures to the CPU.

```julia-repl
julia> m = Dense(1,2)
Dense(1, 2)

julia> m_gpu = gpu(m)
Dense(1, 2)

julia> typeof(m_gpu.W)
CuArray{Float32, 2}

julia> m_cpu = cpu(m_gpu)
Dense(1, 2)

julia> typeof(m_cpu.W)
Matrix{Float32}
```
"""
cpu(m) = fmap(_cpu_array, x; exclude = _isbitsarray)

_cpu_array(x::AbstractArray) = adapt(Array, x)

function Zygote.ChainRules.rrule(::typeof(_cpu_array), x::CUDA.CuArray)
    _cpu_array(x), dy -> (NoTangent(), _gpu_array(dy))
end
function Zygote.ChainRules.rrule(::typeof(_cpu_array), x::AbstractArray)
    # Trivial use: cpu(x::Array) shouldn't push its gradient to GPU
    _cpu_array(x), dy -> (NoTangent(), dy)
end

_isbitsarray(::AbstractArray{<:Number}) = true
_isbitsarray(::AbstractArray{T}) where T = isbitstype(T)
_isbitsarray(x) = false

"""
    gpu(x)

Moves `m` to the current GPU device, if available. It is a no-op otherwise.
See the [CUDA.jl docs](https://juliagpu.github.io/CUDA.jl/stable/usage/multigpu/) 
to help identify the current device.

This works for functions, and any struct marked with [`@functor`](@ref).

```julia-repl
julia> m = Dense(1,2)
Dense(1, 2)

julia> typeof(m.W)
Matrix{Float32}

julia> m_gpu = gpu(m)
Dense(1, 2)

julia> typeof(m_gpu.W) # notice the type of the array changed to a CuArray
CuArray{Float32, 2}
```
"""
gpu(x) = use_cuda[] ? fmap(_gpu_array, x; exclude = _isbitsarray) : x

_gpu_array(x::AbstractArray) = CUDA.cu(x)

# While `cu` moves Arrays to the GPU, we also want to move some structured arrays
# https://github.com/FluxML/Zygote.jl/issues/1005
_gpu_array(x::Zygote.FillArrays.AbstractFill) = CUDA.fill(first(x), size(x))  # gradient of sum
function _gpu_array(x::Zygote.OneElement)  # gradient of getindex
    y = CUDA.zeros(eltype(x), size(x))
    CUDA.@allowscalar y[x.ind...] = x.val
    y
end

function Zygote.ChainRules.rrule(::typeof(_gpu_array), x::AbstractArray)
    _gpu_array(x), dy -> (NoTangent(), _cpu_array(dy))
end
function Zygote.ChainRules.rrule(::typeof(_gpu_array), x::CuArray)
    _gpu_array(x), dy -> (NoTangent(), dy)
end

# Precision

adapt_storage(T::Type{<:Real}, xs::AbstractArray{<:Real}) = convert.(T, xs)

paramtype(T::Type{<:Real}, m) = fmap(x -> adapt(T, x), m)

"""
    f32(m)

Convert the `eltype` of model's parameters to `Float32`.
"""
f32(m) = paramtype(Float32, m)

"""
    f64(m)

Convert the `eltype` of model's parameters to `Float64`.
"""
f64(m) = paramtype(Float64, m)

# Functors for certain Julia data structures
@functor Cholesky
trainable(c::Cholesky) = ()
