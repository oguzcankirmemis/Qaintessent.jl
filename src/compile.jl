using Memoize
using GenericSchur
using JLD
using RandomMatrices

"""
    compile!(m::Matrix{Complex64,2}) where {N}

compiles quantum circuit from given unitary matrix.
"""

function compile(m::AbstractMatrix{ComplexF64}, N, wires=nothing)
    isunitary(m) || error("Only unitary matrices can be compiled into a quantum circuit")
    s = size(m)
    s[1] == s[2] || error("Only square matrices can be compiled into a quantum circuit")

    if Diagonal(diag(m)) ≈ m
        return CircuitGateChain{N}(compilediag(diag(m), N, wires))
    end

    if size(m)[1] == 2
        return CircuitGateChain{N}(compile1qubit(m, N, wires)[1])
    end

    if size(m)[1] == 4
        return CircuitGateChain{N}(compile2qubit(m, N, wires))
    end

end

"""
    compile1qubit(m::AbstractMatrix{ComplexF64}, N, wires=nothing)

compiles a U(2) matrix into quantum gates
"""
function compile1qubit(m::AbstractMatrix{ComplexF64}, N, wires=nothing)
    phase = sqrt(m[1,1]*m[2,2]/norm(m[1,1]*m[2,2]))
    b = m / phase
    ϕ = real(acos(sqrt(b[1,1]*b[2,2]))*2)
    θ1 = imag(log(2im*b[2,1]*b[2,2]/sin(ϕ)))

    θ2 = imag(-log(2*im*b[1,1]*b[2,1]/sin(ϕ)))
    if isnothing(wires)
        wires = [1]
    end
    cg = AbstractCircuitGate{N}[]

    return append!(cg, single_qubit_circuit_gate.((wires[1],), [RzGate(θ2), RxGate(ϕ), RzGate(θ1)], (N,))), phase
end

"""
    decomposeSO4(m::AbstractMatrix{ComplexF64})

decomposes a SO(4) matrix into 2 SU(2) matrices, such that M∈SO(4), A,B ∈ SU(2)
M ≊ A ⊗ B under the magic basis homomorphism.
"""
function decomposeSO4(m::AbstractMatrix{ComplexF64})
    size(m)[1] == size(m)[2] || error("decomposeSO4 only works on square matrices")
    size(m)[1] == 4 || error("decomposeSO4 only works on 4x4 matrices")

    ap = (m[1,1] + m[2,2] + m[3,3] + m[4,4])/4
    bp = (m[2,1] - m[1,2] + m[4,3] - m[3,4])/4
    cp = (m[3,1] - m[4,2] - m[1,3] + m[2,4])/4
    dp = (m[4,1] + m[3,2] - m[2,3] - m[1,4])/4

    aq = (m[2,1] - m[1,2] - m[4,3] + m[3,4])/4
    ar = (m[3,1] + m[4,2] - m[1,3] - m[2,4])/4
    as = (m[4,1] - m[3,2] + m[2,3] - m[1,4])/4

    p = real(sqrt(ap^2 + bp^2 + cp^2 + dp^2))

    a = real(ap/p)
    b = real(bp/p)
    c = real(cp/p)
    d = real(dp/p)

    q = real(aq/a)
    r = real(ar/a)
    s = real(as/a)

    if (p^2 + q^2 + r^2 + s^2) ≈ 1
        A = [p+q*im s+r*im; -s+r*im p-q*im]
        B = [a+b*im -d+c*im; d+c*im a-b*im]
        return A, B
    end

    p = -p

    a = real(ap/p)
    b = real(bp/p)
    c = real(cp/p)
    d = real(dp/p)

    q = real(aq/a)
    r = real(ar/a)
    s = real(as/a)

    println(p^2 + q^2 + r^2 + s^2)
    @assert  (p^2 + q^2 + r^2 + s^2) ≈ 1

    A = [p+q*im s+r*im; -s+r*im p-q*im]
    B = [a+b*im -d+c*im; d+c*im a-b*im]

    return A, B
end

# Algorithm taken from https://arxiv.org/abs/quant-ph/0211002
"""
    compile2qubit(m::AbstractMatrix{ComplexF64}, N, wires=nothing)

compiles an arbitrary U(4) matrix into a quantum circuit
"""
function compile2qubit(m::AbstractMatrix{ComplexF64}, N, wires=nothing)
    cg = AbstractCircuitGate{N}[]
    E = 1/sqrt(2) .* [1 im 0 0; 0 0 im 1; 0 0 im -1; 1 -im 0 0]

    U = E'*m*E
    P2 = U*transpose(U)

    Diag, K_2 = eigen(P2)
    Diag[1] = Diag[1] / det(K_2)^2
    K_2[:,1] = K_2[:,1] * det(K_2)

    Diag = diagm(sqrt.(Diag))
    println(prod(diag(Diag)))
    Diag[1] = Diag[1] * det(U) / det(Diag)

    P = K_2*Diag*inv(K_2)
    K_1 = inv(P)*U

    C, D = decomposeSO4(inv(K_2)*K_1)
    # @assert kron(C,D) ≈ U_56

    append!(cg, compile1qubit(C, N, [2])[1])
    append!(cg, compile1qubit(D, N, [1])[1])

    append!(cg, [CircuitGate((2, 1), ControlledGate{1,2}(X), N),
                    CircuitGate((1,), HadamardGate(), N),
                    CircuitGate((2,), SdagGate(), N),
                    CircuitGate((1,), SdagGate(), N)])
    append!(cg, compilediag(diag(Diag), N))
    append!(cg, [CircuitGate((1,), SGate(), N),
                    CircuitGate((2,), SGate(), N),
                    CircuitGate((1,), HadamardGate(), N),
                    CircuitGate((2, 1), ControlledGate{1,2}(X), N)])

    A, B = decomposeSO4(K_2)
    # @assert kron(A,B) ≈ U_12
    append!(cg, compile1qubit(A, N, [2])[1])
    append!(cg, compile1qubit(B, N, [1])[1])

    return cg
end

"""
    η!(d::Vector{ComplexF64}, ψ::Vector{Float64}, l::Integer)

helper function. calculates η matrix used in compilediag.
"""
function η!(d::Vector{ComplexF64}, ψ::Vector{Float64}, l::Integer)
    for i in StepRange(1,1,l-1)
        ψ[i] = imag(log(d[2i-1]*d[2i+2]/(d[2i]*d[2i+1])))
    end
end

"""
    grayencode(n::Integer) = n ⊻ (n >> 1)

returns grey encoding of given integer
"""
grayencode(n::Integer) = n ⊻ (n >> 1)


"""
    ηcol(l::Integer, n::Integer)

helper function. calculates columns of η matrix used in compilediag.
"""
@memoize Dict function ηcol(l::Integer, n::Integer)
    vec = zeros(Integer, l)
    if n == 0
        vec[1] = -1
        return vec
    elseif n == l
        vec[l] = 1
        return vec
    end

    vec[n] = 1
    vec[n+1] = -1
    vec
end

"""
    flip_code(m::Integer, l::Integer)

helper function. calculates the flip code of a given input matrix
"""
@memoize Dict function flip_code(m::Integer, l::Integer)
    f = filter(x->count_ones(x&m)%2==1, 1:l-1)
    sum(ηcol.((l-1,), f))
end

"""
    svalue(i::Integer)

helper function. calculates the set of integers required for flip code
"""
function svalue(i::Integer)
    b = Int[]
    count = 1
    while i != 0
        if i & 1 == 1
            push!(b, count)
        end
        count += 1
        i = i >> 1
    end
    Tuple(b)
end

"""
    compile2qubit(m::AbstractMatrix{ComplexF64}, N, wires=nothing)

compiles an arbitrary diagonal U(N) matrix into a quantum circuit. Algorithm taken from https://arxiv.org/pdf/quant-ph/0303039.pdf
"""
function compilediag(d::Vector{ComplexF64}, N, cg=nothing, j=0)
    cgs = AbstractCircuitGate{N}[]
    if length(d) == 2
        logd = imag.(log.(d))
        β = (logd[1] - logd[2])
        if isnothing(cg)
            cg = AbstractCircuitGate{N}[]
        end
        push!(cg, CircuitGate((j+1,), RzGate(-β), N))
        return cg
    end
    l = 2^(N-j-1)
    ψ = zeros(Float64, l-1)
    α = zeros(Float64, l)

    η!(d, ψ, l)

    ηplus = zeros(Float64, (l-1, l-1))
    for i in StepRange(1,1,l-1)
        ηplus[:,i] = flip_code(grayencode(i), l)
    end

    ηplus = inv(ηplus)
    α[2:end] = -0.5 * ηplus * ψ

    gatewires = svalue(grayencode(1))
    oldwires = ()

    for i in StepRange(2, 1, l)
        rz = [exp(-im*α[i]/2), exp(im*α[i]/2)]
        for _ in 1:N-j-1
            rz = append!(rz, rz)
        end
        s = filter(x->count_ones(x&grayencode(i-1))%2==1, 1:l-1)
        s = append!(2 .* s .+ 1, 2 .* s .+ 2)

        for k in symdiff(gatewires, oldwires)
            push!(cgs, CircuitGate((j+1, k+1+j), ControlledGate{1,2}(X), N))
        end
        oldwires = gatewires
        gatewires = svalue(grayencode(i))
        push!(cgs, CircuitGate((j+1,), RzGate(α[i]), N))

        rz[s] .= 1 ./rz[s]
        d = d ./ rz
    end

    for k in reverse(oldwires)
        push!(cgs, CircuitGate((j+1, k+1+j), ControlledGate{1,2}(X), N))
    end

    if !(d[1] ≈ d[2])
        logd = imag.(log.(d))
        α[1] = logd[1] - logd[2]
        pushfirst!(cgs, CircuitGate((j+1,), RzGate(-α[1]), N))
        d[1:2:end] = d[1:2:end] ./ exp(im*α[1]/2)
    end
    if isnothing(cg)
        return compilediag(d[1:2:end], N, cgs, j+1)
    end
    return compilediag(d[1:2:end], N, append!(cg, cgs), j+1)
end
