
"""
    AbstractCircuitGate

Abstract unitary quantum circuit gate.
"""
abstract type AbstractCircuitGate end


"""
    CircuitGate{M,G} <: AbstractCircuitGate

Unitary quantum circuit gate. `M` is the number of wires affected by the CircuitGate, and `G` is the basic gate used to construct the CircuitGate.
"""
struct CircuitGate{M,G} <: AbstractCircuitGate
    "ordered wire indices which this gate acts on"
    iwire::NTuple{M,Int64}
    "actual gate"
    gate::G

    @doc """
        CircuitGate{M,G}(iwire::NTuple{M,<:Integer}, gate::G) where {M,G}

    Creates a `CircuitGate{M,G}` object. `M` is the number of wires affected by the CircuitGate, and `G` is the basic gate used to construct the CircuitGate.
    """
    function CircuitGate{M,G}(iwire::NTuple{M,<:Integer}, gate::G) where {M,G <: AbstractGate}
        M == num_wires(gate) || error("$G affects $(num_wires(gate)) wires but $M wires, $iwire, were passed.")
        M ≥ 1 || error("Need at least one wire to act on.")
        length(unique(iwire)) == M || error("Wire indices must be unique.")
        minimum(iwire) ≥ 1 || error("Wire index cannot be smaller than 1.")

        new{M,G}(iwire, gate)
    end
end

"""
    CircuitGate(iwire::NTuple{M,<:Integer}, gate::G)

Create a `CircuitGate{M,G}`.
"""
function CircuitGate(iwire::NTuple{M,<:Integer}, gate::G) where {M,G <: AbstractGate}
    CircuitGate{M,G}(iwire, gate)
end

"""
    req_wires(cg::CircuitGate{M,G})

Minimum number of required qubit wires in a circuit to host the circuit gate `cg`.
```jldoctest
julia> cg = circuit_gate(3, X, (1,2,5));
julia> req_wires(cg)
5
```
"""
req_wires(cg::CircuitGate{M,G}) where {M,G} = maximum(cg.iwire)


"""
    Base.isapprox(cg1::CircuitGate{M,G}, cg2::CircuitGate{M,G})

Compares two circuit gates of basic type `G`.
"""
function Base.isapprox(cg1::CircuitGate{M,G}, cg2::CircuitGate{M,G}) where {M,G}
# for parametric gates, return true only if parameters are approximately equal
    if cg1.iwire != cg2.iwire
        return false
    end
    return cg1.gate ≈ cg2.gate
end

Base.isapprox(cg1::CircuitGate{M,G}, cg2::CircuitGate{M,H}) where {M,G,H} = false

LinearAlgebra.ishermitian(cg::CircuitGate) = LinearAlgebra.ishermitian(cg.gate)


"""
    sparse_matrix(cg::CircuitGate{M,G}, N::Integer=0) where {M,G <: AbstractGate}

returns matrix representation of a [CircuitGate](@ref) object that can applied to a state vector of `N` qubits. `N` can be

# Examples

```jldoctest
julia> cg = circuit_gate(2, Y, 1);
julia> sparse_matrix(cg)
4×4 SparseArrays.SparseMatrixCSC{Complex{Float64},Int64} with 4 stored entries:
  [1, 1]  =  1.0+0.0im
  [4, 2]  =  0.0+1.0im
  [3, 3]  =  1.0+0.0im
  [2, 4]  =  0.0-1.0im
```
"""
function sparse_matrix(cg::CircuitGate{M,G}, N::Integer=0) where {M,G <: AbstractGate}
    # convert to array
    iwire = collect(cg.iwire)

    if N == 0
        N = req_wires(cg)
    else
        N >= maximum(iwire) || error("Circuit size `$N` too small for CircuitGate applied to wires `$iwire`.")
    end

    # TODO: handle sparse matrices efficiently
    gmat = sparse_matrix(cg.gate)
    
    distribute_to_wires(gmat, iwire, N, M)
end

"""
    sparse_matrix(cgs::Vector{<:CircuitGate}, N::Integer=0)

returns matrix representation of a `Vector{<:CircuitGate}` object that can applied to a state vector of `N` qubits.

# Examples

```jldoctest
julia> cgs = CircuitGate[
                circuit_gate(2, Y, 1),
                circuit_gate(2, Z),
                circuit_gate(1, HadamardGate())
                ];
julia> sparse_matrix(cgs)
4×4 SparseArrays.SparseMatrixCSC{Complex{Float64},Int64} with 8 stored entries:
  [1, 1]  =  0.707107+0.0im
  [2, 1]  =  0.707107+0.0im
  [3, 2]  =  0.0-0.707107im
  [4, 2]  =  0.0+0.707107im
  [3, 3]  =  -0.707107+0.0im
  [4, 3]  =  -0.707107+0.0im
  [1, 4]  =  0.0-0.707107im
  [2, 4]  =  0.0+0.707107im
```
"""
function sparse_matrix(cgs::Vector{<:CircuitGate}, N::Integer=0)
    Nmin = maximum(req_wires.(cgs))
    if N == 0
        N = Nmin
    else
        N >= Nmin || error("Circuit size `$N` too small; vector of CircuitGate requires $Nmin wires.")
    end

    gmat = sparse(one(ComplexF64)*I, 2^N, 2^N)
    for cg in cgs
        iwire = collect(cg.iwire)
        gmat = distribute_to_wires(sparse_matrix(cg.gate), iwire, N, num_wires(cg.gate)) * gmat
    end
    
    return gmat
end


function distribute_to_wires(gmat::SparseMatrixCSC{Complex{Float64},Int}, iwire::Vector{Int}, N::Int, M::Int)

    # complementary wires
    iwcompl = setdiff(1:N, iwire)
    @assert length(iwire) + length(iwcompl) == N
    @assert size(gmat) == (2^M, 2^M)

    # Note: following the ordering convention of `kron` here, i.e.,
    # last qubit corresponds to fastest varying index
    strides = Int[2^j for j in 0:N-1]
    wstrides = strides[iwire]
    cstrides = strides[iwcompl]
    b = BitArray{1}(undef, M)

    values = Vector{ComplexF64}(undef, length(gmat.nzval) * 2^(N - M))
    nnz = length(gmat.nzval)
    rowind = Vector{Int}(undef, length(values))
    colind = Vector{Int}(undef, length(values))

    for j in 1:length(gmat.colptr)-1
        index = gmat.colptr[j]:gmat.colptr[j + 1] - 1
        colvalue = dot(binary_digits!(b, j - 1), wstrides) + 1
        for i in index
            @inbounds rowind[i] = dot(binary_digits!(b, gmat.rowval[i] - 1), wstrides) + 1
            @inbounds colind[i] = colvalue
        end
    end

    r = Base.view(rowind, 1:nnz)
    c = Base.view(colind, 1:nnz)
    @inbounds values[1:nnz] = gmat.nzval

    b = BitArray(undef, N - M)
    for k in 2:2^(N - M)
        koffset = dot(binary_digits!(b, k - 1), cstrides)
        @inbounds rowind[nnz*(k-1)+1:nnz*k] = r .+ koffset
        @inbounds colind[nnz*(k-1)+1:nnz*k] = c .+ koffset
        @inbounds values[nnz*(k-1)+1:nnz*k] = gmat.nzval
    end

    return sparse(rowind, colind, values, 2^N, 2^N)
end


"""
Base.adjoint(cg::CircuitGate{M,G})

Construct a `CircuitGate{M,H}` object where `H` is the adjoint of `AbstractGate` `G`
"""
function Base.adjoint(cg::CircuitGate{M,G}) where {M,G}
    adj_gate = Base.adjoint(cg.gate)
    CircuitGate{M,typeof(adj_gate)}(cg.iwire, adj_gate)
end

function Base.adjoint(cg::Vector{<:CircuitGate})
    reverse(adjoint.(cg))
end


"""
    circuit_gate

helper function to construct a [`CircuitGate`](@ref) object from basic gate types.

```jldoctest
julia> circuit_gate(1, X)
CircuitGate{1,XGate}((1,), XGate())

julia> circuit_gate(1, X, 2)
CircuitGate{2,ControlledGate{XGate}}((1, 2), ControlledGate{XGate}(XGate(), 1))

julia> circuit_gate((1,2), SwapGate(), (3,4))
CircuitGate{4,ControlledGate{SwapGate}}((1, 2, 3, 4), ControlledGate{SwapGate}(SwapGate(), 2))
```
"""
function circuit_gate(iwire::Integer, gate::AbstractGate, control::Integer...)
    circuit_gate(iwire, gate, control)
end

function circuit_gate(iwire1::Integer, iwire2::Integer, gate::AbstractGate, control::NTuple{M,Integer}=NTuple{0,Integer}()) where {M}
    if isempty(control)
        return CircuitGate((iwire1, iwire2), gate)
    end
    C = length(control)
    return CircuitGate((iwire1, iwire2, control...), ControlledGate(gate, M))
end

function circuit_gate(iwire1::NTuple{L,Integer}, gate::AbstractGate, control::NTuple{M,Integer}=NTuple{0,Integer}()) where {L,M}
    if isempty(control)
        return CircuitGate(iwire1, gate)
    end
    return CircuitGate((iwire1..., control...), ControlledGate(gate, M))
end

function circuit_gate(iwire1::NTuple{M,Integer}, gate::AbstractGate, control::Integer...) where {M}
    circuit_gate(iwire1, gate, control)
end

"""
single_qubit_circuit_gate(iwire::Integer, gate::AbstractGate{1}, N::Integer)

Construct a `CircuitGate{1,G}` object of basic gate type `gate` affecting wire `iwire`.
"""
single_qubit_circuit_gate(iwire::Integer, gate::AbstractGate) =
CircuitGate((iwire,), gate)

function circuit_gate(iwire::Integer, gate::AbstractGate, control::NTuple{M,Integer}=NTuple{0,Integer}()) where {M}
    if isempty(control)
        return CircuitGate((iwire,), gate)
    end
    return CircuitGate((iwire, control...), ControlledGate(gate, M))
end

"""
    two_qubit_circuit_gate(iwire1, iwire2, gate)

Construct a `CircuitGate{2,G}` object of basic gate type `gate` affecting wires `iwire1` and `iwire2`.
"""
two_qubit_circuit_gate(iwire1::Integer, iwire2::Integer, gate::AbstractGate) = CircuitGate((iwire1, iwire2), gate)


circuit_gate(iwire1::Integer, iwire2::Integer, gate::AbstractGate, control::Integer...) = circuit_gate(iwire1, iwire2, gate, control)

# single control and target wire
"""
controlled_circuit_gate(itarget::Integer, icntrl::Union{Integer, Expr}, U::AbstractGate{1}, N::Integer)

Construct a `CircuitGate{2,N,G}` object of basic gate type `U` controlled by wire or Expr `icntrl` and affecting wire `itarget`.
"""
controlled_circuit_gate(itarget::Integer, icntrl::Integer, U::AbstractGate) = controlled_circuit_gate((itarget,), (icntrl,), U)

# single control wire
"""
controlled_circuit_gate(itarget::NTuple{M,<:Integer}, icntrl::Integer, U::AbstractGate{M}, N::Integer) where {M}

Construct a `CircuitGate{M+1,N,G}` object of basic gate type `U` controlled by wire or Expr `icntrl` and affecting wires in tuple `itarget`.
"""
controlled_circuit_gate(itarget::NTuple{M,<:Integer}, icntrl::Integer, U::AbstractGate) where {M} = controlled_circuit_gate(itarget, (icntrl,), U)

# single target wire
"""
controlled_circuit_gate(itarget::Integer, icntrl::NTuple{K, Union{Int, Expr}}, U::AbstractGate{1}, N::Integer)  where {K}

Construct a `CircuitGate{K+1,N,G}` object of basic gate type `U` controlled by wires or Expr in tuple `icntrl` and affecting wire `itarget`.
"""
controlled_circuit_gate(itarget::Integer, icntrl::NTuple{K,Integer}, U::AbstractGate)  where {K} = controlled_circuit_gate((itarget,), icntrl, U)

"""
controlled_circuit_gate(itarget::NTuple{M, <:Integer}, icntrl::NTuple{K, <:Union{Integer, Expr}}, U::AbstractGate{M}, N::Integer) where {K,M}

Construct a `CircuitGate{M+K,N,G}` object of basic gate type `U` controlled by wires in tuple `icntrl` and affecting wires in tuple `itarget`.
"""
function controlled_circuit_gate(itarget::NTuple{M,<:Integer}, icntrl::NTuple{K,Integer}, U::AbstractGate) where {K,M}
    # # consistency checks
    C = length(icntrl)
    # C + M ≤ N || error("Number of control and target wires must be smaller than overall number of wires.")
    # length(intersect(itarget, icntrl)) == 0 || error("Control and target wires must be disjoint.")
    CircuitGate((itarget..., icntrl...), ControlledGate(U, C))
end