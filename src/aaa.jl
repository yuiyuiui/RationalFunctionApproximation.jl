# These functions are mainly superseded by the `approximate` function. They are kept here as
# reference implementations.

#####
##### Discrete AAA
#####

"""
    aaa(y, z)
    aaa(f)

Adaptively compute a rational interpolant.

# Arguments

## discrete mode
- `y::AbstractVector{<:Number}`: values at nodes
- `z::AbstractVector{<:Number}`: interpolation nodes

## continuous mode
- `f::Function`: function to approximate on the interval [-1,1]

# Keyword arguments
- `max_degree::Integer=150`: maximum numerator/denominator degree to use
- `float_type::Type=Float64`: floating point type to use for the computation
- `tol::Real=1000*eps(float_type)`: tolerance for stopping
- `stagnation::Integer=10`: number of iterations to determines stagnation
- `stats::Bool=false`: return convergence statistics

# Returns
- `r::Barycentric`: the rational interpolant
- `stats::NamedTuple`: convergence statistics, if keyword `stats=true`

# Examples
```julia-repl
julia> z = 1im * range(-10, 10, 500);

julia> y = @. exp(z);

julia> r = aaa(z, y);

julia> degree(r)   # both numerator and denominator
12

julia> first(nodes(r), 4)
4-element Vector{ComplexF64}:
 0.0 - 6.272545090180361im
 0.0 + 9.43887775551102im
 0.0 - 1.1022044088176353im
 0.0 + 4.909819639278557im

julia> r(1im * π / 2)
-2.637151617496356e-15 + 1.0000000000000002im
```

See also [`approximate`](@ref) for approximating a function on a curve or region.
"""
function aaa(y::AbstractVector{<:Number}, z::AbstractVector{<:Number};
    max_degree = 150,
    float_type = promote_type(typeof(float(1)), real_type(eltype(z)), real_type(eltype(y))),
    tol = 1000*eps(float_type),
    stagnation = 10,
    stats = false
    )

    fmax = norm(y, Inf)    # for scaling
    m = length(z)
    iteration = NamedTuple[]
    err = float_type[]
    besterr, bestidx, best = Inf, NaN, nothing

    # Allocate space for Cauchy matrix, Loewner matrix, and residual
    C = similar(z, (m, m))
    L = similar(z, (m, m))
    R = complex(zeros(size(z)))

    ȳ = sum(y) / m
    s, idx = findmax(abs(y - ȳ) for y in y)
    push!(err, s)

    # The ordering of nodes matters, while the order of test points does not.
    node_index = Int[]
    push!(node_index, idx)
    test_index = Set(1:m)
    delete!(test_index, idx)

    n = 0    # number of poles
    while true
        n += 1
        σ = view(z, node_index)
        fσ = view(y, node_index)
        # Fill in matrices for the latest node
        @inbounds @fastmath for i in test_index
            δ = z[i] - σ[n]
            # δ can be zero if there are repeats in z
            C[i, n] = iszero(δ) ? 1 / eps() : 1 / δ
            L[i, n] = (y[i] - fσ[n]) * C[i, n]
        end
        istest = collect(test_index)
        _, _, V = svd( view(L, istest, 1:n) )
        w = V[:, end]    # barycentric weights

        CC = view(C, istest, 1:n)
        num = CC * (w.*fσ)
        den = CC * w
        @. R[istest] = y[istest] - num / den
        push!(err, norm(R, Inf))
        push!(iteration, (; weights=w, active=copy(node_index)))

        if (last(err) < besterr)
            besterr, bestidx, best = last(err), length(iteration), last(iteration)
        end

        # Are we done?
        if (besterr <= tol*fmax) ||
            (n == max_degree + 1) ||
            ((length(iteration) - bestidx >= stagnation) && (besterr < 1e-2*fmax))
            break
        end

        # To make sure columns of V won't be thrown away in svd and prevent overfitting
        if n>=((m+1)>>1) break end

        _, j = findmax(abs, R)
        push!(node_index, j)
        delete!(test_index, j)
        R[j] = 0
    end

    idx, w = best.active, best.weights
    r = Barycentric(z[idx], y[idx], w)
    if stats
        return r, (;err, iteration)
    else
        return r
    end
end

#####
##### Continuum AAA on [-1, 1] only
#####

function aaa(
    f::Function;
    max_degree=150,
    float_type = promote_type(typeof(float(1)), real_type(f(11//23))),
    tol=1000*eps(float_type),
    refinement=3,
    stagnation=10,
    stats=false
    )

    CT = Complex{float_type}
    # arrays for tracking convergence progress
    err, nbad = float_type[], Int[]
    nodes, vals, pol, weights = Vector{float_type}[], Vector{CT}[], Vector{CT}[], Vector{CT}[]

    S = [-one(float_type), one(float_type)]     # initial nodes
    fS = f.(S)
    besterr, bestm = Inf, NaN
    while true                                  # main loop
        m = length(S)
        push!(nodes, copy(S))
        X = refine(S, max(refinement, ceil(16-m)))    # test points
        fX = f.(X)
        push!(vals, copy(fS))
        C = [ 1/(x-s) for x in X, s in S ]
        L = [a-b for a in fX, b in fS] .* C
        _, _, V = svd(L)
        w = V[:,end]
        push!(weights, w)
        R = (C*(w.*fS)) ./ (C*w)                # values of the rational interpolant
        push!(err, norm(fX - R, Inf) )

        zp =  poles(Barycentric(S, fS, w))
        push!(pol, zp)
        I = (imag(zp).==0) .& (abs.(zp).<=1)    # bad poles indicator
        push!(nbad, sum(I))
        # If valid and the best yet, save it:
        if (last(nbad) == 0) && (last(err) < besterr)
            besterr, bestm = last(err), m
        end

        fmax = max( norm(fS, Inf), norm(fX, Inf) )     # scale of f
        # Check stopping:
        if (besterr <= tol*fmax) ||                                # goal met
            (m == max_degree + 1) ||                                   # max degree reached
            ((m - bestm >= stagnation) && (besterr < 1e-2*fmax))    # stagnation
            break
        end

        # We're continuing the iteration, so add the worst test point to the nodes:
        _, j = findmax(abs, fX - R)
        push!(S, X[j])
        push!(fS, fX[j])
    end

    # Use the best result found:
    S, y, w = nodes[bestm-1], vals[bestm-1], weights[bestm-1]
    idx = sortperm(S)
    x, y, w = S[idx], y[idx], w[idx]
    if isreal(w) && isreal(y)
        y, w = real(y), real(w)
    end

    if stats
        if isreal(w) && isreal(y)
            weights = real.(weights)
            vals = real.(vals)
        end
        st = ConvergenceStats(bestm-1, err, nbad, nodes, vals, weights, pol)
        r = Barycentric(x, y, w; stats=st)
    else
        r = Barycentric(x, y, w)
    end

    return r
end
