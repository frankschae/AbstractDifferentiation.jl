using AbstractDifferentiation
using Test, FiniteDifferences, LinearAlgebra
using ForwardDiff
using Random
Random.seed!(1234)

const FDM = FiniteDifferences

## FiniteDifferences
struct FDMBackend1{A} <: AD.AbstractFiniteDifference
    alg::A
end
FDMBackend1() = FDMBackend1(central_fdm(5, 1))
const fdm_backend1 = FDMBackend1()
# Minimal interface
AD.@primitive function jacobian(ab::FDMBackend1, f, xs...)
    return jacobian(ab.alg, f, xs...)
end

struct FDMBackend2{A} <: AD.AbstractFiniteDifference
    alg::A
end
FDMBackend2() = FDMBackend2(central_fdm(5, 1))
const fdm_backend2 = FDMBackend2()
AD.@primitive function pushforward_function(ab::FDMBackend2, f, xs...)
    return function (vs)
        jvp(ab.alg, f, tuple.(xs, vs)...)
    end
end

struct FDMBackend3{A} <: AD.AbstractFiniteDifference
    alg::A
end
FDMBackend3() = FDMBackend3(central_fdm(5, 1))
const fdm_backend3 = FDMBackend3()
AD.@primitive function pullback_function(ab::FDMBackend3, f, xs...)
    return function (vs)
        # Supports only single output
        if vs isa AbstractVector
            return j′vp(ab.alg, f, vs, xs...)
        else
            @assert length(vs) == 1
            return j′vp(ab.alg, f, vs[1], xs...)

        end
    end
end
##


## ForwardDiff
struct ForwardDiffBackend1 <: AD.AbstractForwardMode end
const forwarddiff_backend1 = ForwardDiffBackend1()
AD.@primitive function jacobian(ab::ForwardDiffBackend1, f, xs...)
    if xs isa AbstractArray
        return ForwardDiff.jacobian(f, xs)
    elseif xs isa Number
        return ForwardDiff.derivative(f, xs)
    elseif xs isa Tuple
        @assert length(xs) <= 2
        if eltype(xs) <: Number
            # Can this be avoided for the derivative computation? It seems to defeat the purpose of AbstractDifferentiation. 
            # If eltype(xs) isa Number, ForwardDiff will error by saying that Jacobian expects an array.
            # if we convert the number to an array in AbstractDifferentiation, we get a no method error due to log(x) and exp(x)
            if length(xs) == 1
                (ForwardDiff.derivative(f, xs[1]),)
            else
                _f1 = x -> f(x,xs[2])
                _f2 = x -> f(xs[1], x)
                (ForwardDiff.derivative(_f1, xs[1]),ForwardDiff.derivative(_f2, xs[2]))
            end      
        else
            if length(xs) == 1
                out = f(xs[1])
                if out isa Number
                    # Lazy Jacobian test pb fails otherwise with "dimensions must match: a has dims (Base.OneTo(1), Base.OneTo(5)), b has dims (Base.OneTo(5),), mismatch at 1"
                    (reshape(ForwardDiff.gradient(f, xs[1]),(1,length(xs[1]))),)
                else
                    (ForwardDiff.jacobian(f, xs[1]),)
                end
            else
                out = f(xs...)
                _f1 = x -> f(x,xs[2])
                _f2 = x -> f(xs[1], x)
                if out isa Number
                    # reshape for pullback tests (similar as above)
                    (reshape(ForwardDiff.gradient(_f1, xs[1]),(1,length(xs[1]))),
                    reshape(ForwardDiff.gradient(_f2, xs[2]), (1, length(xs[2]))))
                else
                    (ForwardDiff.jacobian(_f1, xs[1]),ForwardDiff.jacobian(_f2, xs[2]))
                end
                
            end    
        end 
    else
        error(typeof(xs)) 
    end
end

struct ForwardDiffBackend2 <: AD.AbstractForwardMode end
const forwarddiff_backend2 = ForwardDiffBackend2()
AD.@primitive function pushforward_function(ab::ForwardDiffBackend2, f, xs...)
    # jvp = f'(x)*v, i.e., differentiate f(x + h*v) wrt h at 0
    return function (vs)
        if xs isa Tuple
            @assert length(xs) <= 2
            if length(xs) == 1
                (ForwardDiff.derivative(h->f(xs[1]+h*vs[1]),0),)
            else
                ForwardDiff.derivative(h->f(xs[1]+h*vs[1], xs[2]+h*vs[2]),0)
            end
        else
            ForwardDiff.derivative(h->f(xs+h*vs),0)
        end
    end
end
##


fder(x, y) = exp(y) * x + y * log(x)
dfderdx(x, y) = exp(y) + y * 1/x
dfderdy(x, y) = exp(y) * x + log(x)

fgrad(x, y) = prod(x) + sum(y ./ (1:length(y)))
dfgraddx(x, y) = prod(x)./x
dfgraddy(x, y) = one(eltype(y)) ./ (1:length(y))
dfgraddxdx(x, y) = prod(x)./(x*x') - Diagonal(diag(prod(x)./(x*x')))
dfgraddydy(x, y) = zeros(length(y),length(y))

function fjac(x, y)
    x + Bidiagonal(-ones(length(y)) * 3, ones(length(y) - 1) / 2, :U) * y
end
dfjacdx(x, y) = I(length(x))
dfjacdy(x, y) = Bidiagonal(-ones(length(y)) * 3, ones(length(y) - 1) / 2, :U)

# Jvp
jxvp(x,y,v) = dfjacdx(x,y)*v
jyvp(x,y,v) = dfjacdy(x,y)*v

# vJp
vJxp(x,y,v) = dfjacdx(x,y)'*v
vJyp(x,y,v) = dfjacdy(x,y)'*v

const xscalar = rand()
const yscalar = rand()

const xvec = rand(5)
const yvec = rand(5)

# to check if vectors get mutated
xvec2 = deepcopy(xvec)
yvec2 = deepcopy(yvec)


function test_fdm_derivatives(backend, fdm_backend)
    # fdm_backend for comparison with finite differences 
    der1 = AD.derivative(backend, fder, xscalar, yscalar)
    der2 = (
        fdm_backend.alg(x -> fder(x, yscalar), xscalar),
        fdm_backend.alg(y -> fder(xscalar, y), yscalar),
    )
    @test minimum(isapprox.(der1, der2, rtol=1e-10))
    valscalar, der3 = AD.value_and_derivative(backend, fder, xscalar, yscalar)
    @test valscalar == fder(xscalar, yscalar)
    @test der3 .- der1 == (0, 0)
    der_exact = (dfderdx(xscalar,yscalar), dfderdy(xscalar,yscalar))
    @test minimum(isapprox.(der_exact, der1, rtol=1e-10))
    # test if single input (no tuple works)
    valscalara, dera = AD.value_and_derivative(backend, x -> fder(x, yscalar), xscalar)
    valscalarb, derb = AD.value_and_derivative(backend, y -> fder(xscalar, y), yscalar)
    @test valscalar == valscalara
    @test valscalar == valscalarb
    @test isapprox(dera[1], der1[1], rtol=1e-10)
    @test isapprox(derb[1], der1[2], rtol=1e-10)
end

function test_fdm_gradients(backend, fdm_backend)
    grad1 = AD.gradient(backend, fgrad, xvec, yvec)
    grad2 = FDM.grad(fdm_backend.alg, fgrad, xvec, yvec)
    @test minimum(isapprox.(grad1, grad2, rtol=1e-10))
    valscalar, grad3 = AD.value_and_gradient(backend, fgrad, xvec, yvec)
    @test valscalar == fgrad(xvec, yvec)
    @test norm.(grad3 .- grad1) == (0, 0)
    grad_exact = (dfgraddx(xvec,yvec), dfgraddy(xvec,yvec))
    @test minimum(isapprox.(grad_exact, grad1, rtol=1e-10))
    @test xvec == xvec2
    @test yvec == yvec2
    # test if single input (no tuple works)
    valscalara, grada = AD.value_and_gradient(backend, x -> fgrad(x, yvec), xvec)
    valscalarb, gradb = AD.value_and_gradient(backend, y -> fgrad(xvec, y), yvec)
    @test valscalar == valscalara
    @test valscalar == valscalarb
    @test isapprox(grada[1], grad1[1], rtol=1e-10)
    @test isapprox(gradb[1], grad1[2], rtol=1e-10)
end

function test_fdm_jacobians(backend,fdm_backend)
    jac1 = AD.jacobian(backend, fjac, xvec, yvec)
    jac2 = FDM.jacobian(fdm_backend.alg, fjac, xvec, yvec)
    @test  minimum(isapprox.(jac1, jac2, rtol=1e-10))
    valvec, jac3 = AD.value_and_jacobian(backend, fjac, xvec, yvec)
    @test valvec == fjac(xvec, yvec)
    @test norm.(jac3 .- jac1) == (0, 0)
    grad_exact = (dfjacdx(xvec, yvec), dfjacdy(xvec, yvec))
    @test minimum(isapprox.(grad_exact, jac1, rtol=1e-10))
    @test xvec == xvec2
    @test yvec == yvec2
    # test if single input (no tuple works)
    valveca, jaca = AD.value_and_jacobian(backend, x -> fjac(x, yvec), xvec)
    valvecb, jacb = AD.value_and_jacobian(backend, y -> fjac(xvec, y), yvec)
    @test valvec == valveca
    @test valvec == valvecb
    @test isapprox(jaca[1], jac1[1], rtol=1e-10)
    @test isapprox(jacb[1], jac1[2], rtol=1e-10)
end

function test_fdm_hessians(backend, fdm_backend)
    H1 = AD.hessian(backend, fgrad, xvec, yvec)
    @test dfgraddxdx(xvec,yvec) ≈ H1[1] atol=1e-10
    @test dfgraddydy(xvec,yvec) ≈ H1[2] atol=1e-10

    # test if single input (no tuple works)
    fhess = x -> fgrad(x, yvec)
    hess1 = AD.hessian(backend, fhess, xvec)
    hess2 = FDM.jacobian(
        fdm_backend.alg,
        (x) -> begin
            FDM.grad(
                fdm_backend.alg,
                fhess,
                x,
            )
        end,
        xvec,
    )
    @test minimum(isapprox.(hess1, hess2, rtol=1e-10))
    valscalar, hess3 = AD.value_and_hessian(backend, fhess, xvec)
    @test valscalar == fgrad(xvec, yvec)
    @test norm.(hess3 .- hess1) == (0,)
    valscalar, grad, hess4 = AD.value_gradient_and_hessian(backend, fhess, xvec)
    @test valscalar == fgrad(xvec, yvec)
    @test norm.(grad .- AD.gradient(backend, fhess, xvec)) == (0,)
    @test norm.(hess4 .- hess1) == (0,)
    @test dfgraddxdx(xvec,yvec) ≈ hess1[1] atol=1e-10
    @test xvec == xvec2
    @test yvec == yvec2
    fhess2 = x-> dfgraddx(x, yvec)
    hess5 = AD.jacobian(backend, fhess2, xvec)
    @test minimum(isapprox.(hess5, hess1, atol=1e-10))
end

function test_fdm_jvp(backend,fdm_backend)
    v = (rand(length(xvec)), rand(length(yvec)))

    if backend isa Union{FDMBackend2,ForwardDiffBackend2} # augmented version of v
        identity_like = AD.identity_matrix_like(v)
        vaug = map(identity_like) do identity_like_i
            identity_like_i .* v
        end

        pf1 = map(v->AD.pushforward_function(backend, fjac, xvec, yvec)(v), vaug)
        ((valvec1, pf3x), (valvec2, pf3y)) = map(v->AD.value_and_pushforward_function(backend, fjac, xvec, yvec)(v), vaug)
    else
        pf1 = AD.pushforward_function(backend, fjac, xvec, yvec)(v)
        valvec, pf3 = AD.value_and_pushforward_function(backend, fjac, xvec, yvec)(v)
        ((valvec1, pf3x), (valvec2, pf3y)) = (valvec, pf3[1]), (valvec, pf3[2])
    end
    pf2 = (
        FDM.jvp(fdm_backend.alg, x -> fjac(x, yvec), (xvec, v[1])),
        FDM.jvp(fdm_backend.alg, y -> fjac(xvec, y), (yvec, v[2])),
    )
    @test minimum(isapprox.(pf1, pf2, rtol=1e-10))

    @test valvec1 == fjac(xvec, yvec)
    @test valvec2 == fjac(xvec, yvec)
    @test norm.((pf3x,pf3y) .- pf1) == (0, 0)
    @test minimum(isapprox.(pf1, (jxvp(xvec,yvec,v[1]), jyvp(xvec,yvec,v[2])), atol=1e-10))
    @test xvec == xvec2
    @test yvec == yvec2
end

function test_fdm_j′vp(backend,fdm_backend)
    w = rand(length(fjac(xvec, yvec)))
    pb1 = AD.pullback_function(backend, fjac, xvec, yvec)(w)
    pb2 = FDM.j′vp(fdm_backend.alg, fjac, w, xvec, yvec)
    @test all(norm.(pb1 .- pb2) .<= (1e-10, 1e-10))
    valvec, pb3 = AD.value_and_pullback_function(backend, fjac, xvec, yvec)(w)
    @test valvec == fjac(xvec, yvec)
    @test norm.(pb3 .- pb1) == (0, 0)
    @test minimum(isapprox.(pb1, (vJxp(xvec,yvec,w), vJyp(xvec,yvec,w)), atol=1e-10))
    @test xvec == xvec2
    @test yvec == yvec2
end

function test_fdm_lazy_derivatives(backend,fdm_backend)
    # single input function
    der1 = AD.derivative(backend, x->fder(x, yscalar), xscalar)
    der2 = (
        fdm_backend.alg(x -> fder(x, yscalar), xscalar),
        fdm_backend.alg(y -> fder(xscalar, y), yscalar),
    )

    lazyder = AD.LazyDerivative(backend, x->fder(x, yscalar), xscalar)

    # multiplication with scalar
    @test isapprox(der1[1]*yscalar, der2[1]*yscalar, atol=1e-10) 
    @test lazyder*yscalar == der1.*yscalar
    @test lazyder*yscalar isa Tuple

    @test isapprox(yscalar*der1[1], yscalar*der2[1], atol=1e-10)
    @test yscalar*lazyder == yscalar.*der1 
    @test yscalar*lazyder isa Tuple

    # multiplication with array
    @test isapprox(der1[1]*yvec, der2[1]*yvec, atol=1e-10)
    @test lazyder*yvec == (der1.*yvec,)
    @test lazyder*yvec isa Tuple

    @test isapprox(yvec*der1[1], yvec*der2[1], atol=1e-10)
    @test yvec*lazyder == (yvec.*der1,)
    @test yvec*lazyder isa Tuple

    # multiplication with tuple
    @test lazyder*(yscalar,) == lazyder*yscalar
    @test lazyder*(yvec,) == lazyder*yvec

    @test (yscalar,)*lazyder == yscalar*lazyder
    @test (yvec,)*lazyder == yvec*lazyder

    # two input function
    der1 = AD.derivative(backend, fder, xscalar, yscalar)
    der2 = (
        fdm_backend.alg(x -> fder(x, yscalar), xscalar),
        fdm_backend.alg(y -> fder(xscalar, y), yscalar),
    )

    lazyder = AD.LazyDerivative(backend, fder, (xscalar, yscalar))

    # multiplication with scalar
    @test minimum(isapprox.(der1.*yscalar, der2.*yscalar, atol=1e-10))
    @test lazyder*yscalar == der1.*yscalar
    @test lazyder*yscalar isa Tuple

    @test minimum(isapprox.(yscalar.*der1, yscalar.*der2, atol=1e-10)) 
    @test yscalar*lazyder == yscalar.*der1
    @test yscalar*lazyder isa Tuple

    # multiplication with array
    @test minimum(isapprox.((der1[1]*yvec, der1[2]*yvec), (der2[1]*yvec, der2[2]*yvec), atol=1e-10))
    @test lazyder*yvec == (der1[1]*yvec, der1[2]*yvec)
    @test lazyder*yvec isa Tuple

    @test minimum(isapprox.((yvec*der1[1], yvec*der1[2]), (yvec*der2[1], yvec*der2[2]), atol=1e-10))
    @test yvec*lazyder == (yvec*der1[1], yvec*der1[2])
    @test lazyder*yvec isa Tuple

    # multiplication with tuple
    @test lazyder*(yscalar,) == lazyder*yscalar
    @test lazyder*(yvec,) == lazyder*yvec

    @test (yscalar,)*lazyder == yscalar*lazyder
    @test (yvec,)*lazyder == yvec*lazyder
end

function test_fdm_lazy_gradients(backend,fdm_backend)
    # single input function
    grad1 = AD.gradient(backend, x->fgrad(x, yvec), xvec)
    grad2 = FDM.grad(fdm_backend.alg, x->fgrad(x, yvec), xvec)
    lazygrad = AD.LazyGradient(backend, x->fgrad(x, yvec), xvec)

    # multiplication with scalar
    @test minimum(isapprox.(grad1.*yscalar, grad2.*yscalar, atol=1e-10))
    @test norm.(lazygrad*yscalar .- grad1.*yscalar) == (0,)
    @test lazygrad*yscalar isa Tuple

    @test minimum(isapprox.(yscalar.*grad1, yscalar.*grad2, atol=1e-10))
    @test norm.(yscalar*lazygrad .- yscalar.*grad1) == (0,)
    @test yscalar*lazygrad isa Tuple

    # multiplication with tuple
    @test lazygrad*(yscalar,) == lazygrad*yscalar
    @test (yscalar,)*lazygrad == yscalar*lazygrad

    # two input function
    grad1 = AD.gradient(backend, fgrad, xvec, yvec)
    grad2 = FDM.grad(fdm_backend.alg, fgrad, xvec, yvec)
    lazygrad = AD.LazyGradient(backend, fgrad, (xvec, yvec))

    # multiplication with scalar
    @test minimum(isapprox.(grad1.*yscalar, grad2.*yscalar,  atol=1e-10))
    @test norm.(lazygrad*yscalar .- grad1.*yscalar) == (0,0)
    @test lazygrad*yscalar isa Tuple

    @test minimum(isapprox.(yscalar.*grad1, yscalar.*grad2, atol=1e-10))
    @test norm.(yscalar*lazygrad .- yscalar.*grad1) == (0,0)
    @test yscalar*lazygrad isa Tuple

    # multiplication with tuple
    @test lazygrad*(yscalar,) == lazygrad*yscalar
    @test (yscalar,)*lazygrad == yscalar*lazygrad
end

function test_fdm_lazy_jacobians(backend,fdm_backend)
    # single input function
    jac1 = AD.jacobian(backend, x->fjac(x, yvec), xvec)
    jac2 = FDM.jacobian(fdm_backend.alg, x->fjac(x, yvec), xvec)
    lazyjac = AD.LazyJacobian(backend, x->fjac(x, yvec), xvec)

    # multiplication with scalar
    @test minimum(isapprox.(jac1.*yscalar, jac2.*yscalar, atol=1e-10))
    @test norm.(lazyjac*yscalar .- jac1.*yscalar) == (0,)
    @test lazyjac*yscalar isa Tuple

    @test minimum(isapprox.(yscalar.*jac1, yscalar.*jac2, atol=1e-10))
    @test norm.(yscalar*lazyjac .- yscalar.*jac1) == (0,)
    @test yscalar*lazyjac isa Tuple

    w = adjoint(rand(length(fjac(xvec, yvec))))
    v = (rand(length(xvec)),rand(length(xvec)))

    # vjp
    pb1 = FDM.j′vp(fdm_backend.alg, x -> fjac(x, yvec), w, xvec)
    res = w*lazyjac
    @test minimum(isapprox.(pb1, res, atol=1e-10))
    @test res isa Tuple

    # jvp
    pf1 = (FDM.jvp(fdm_backend.alg, x -> fjac(x, yvec), (xvec, v[1])),)
    res = lazyjac*v[1]
    @test minimum(isapprox.(pf1, res, atol=1e-10))
    @test res isa Tuple

    # two input function
    jac1 = AD.jacobian(backend, fjac, xvec, yvec)
    jac2 = FDM.jacobian(fdm_backend.alg, fjac, xvec, yvec)
    lazyjac = AD.LazyJacobian(backend, fjac, (xvec, yvec))

    # multiplication with scalar
    @test minimum(isapprox.(jac1.*yscalar, jac2.*yscalar, atol=1e-10))
    @test norm.(lazyjac*yscalar .- jac1.*yscalar) == (0,0)
    @test lazyjac*yscalar isa Tuple

    @test minimum(isapprox.(yscalar.*jac1, yscalar.*jac2, atol=1e-10))
    @test norm.(yscalar*lazyjac .- yscalar.*jac1) == (0,0)
    @test yscalar*lazyjac isa Tuple

    # vjp
    pb1 = FDM.j′vp(fdm_backend.alg, fjac, w, xvec, yvec)
    res = w*lazyjac
    @test minimum(isapprox.(pb1, res, atol=1e-10))
    @test res isa Tuple

    # jvp
    pf1 = (
        FDM.jvp(fdm_backend.alg, x -> fjac(x, yvec), (xvec, v[1])),
        FDM.jvp(fdm_backend.alg, y -> fjac(xvec, y), (yvec, v[2])),
    )

    if backend isa Union{FDMBackend2,ForwardDiffBackend2} # augmented version of v
        identity_like = AD.identity_matrix_like(v)
        vaug = map(identity_like) do identity_like_i
            identity_like_i .* v
        end

        res = map(v->(lazyjac*v)[1], vaug)
    else
        res = lazyjac*v
    end

    @test minimum(isapprox.(pf1, res, atol=1e-10))
    @test res isa Tuple
end

function test_fdm_lazy_hessians(backend,fdm_backend)
    # fdm_backend not used here yet..
    # single input function
    fhess = x -> fgrad(x, yvec)
    hess1 = (dfgraddxdx(xvec,yvec),)
    lazyhess = AD.LazyHessian(backend, fhess, xvec)

    # multiplication with scalar
    @test minimum(isapprox.(lazyhess*yscalar, hess1.*yscalar, atol=1e-10))
    @test lazyhess*yscalar isa Tuple

    # multiplication with scalar
    @test minimum(isapprox.(yscalar*lazyhess, yscalar.*hess1, atol=1e-10))
    @test yscalar*lazyhess isa Tuple

    w = adjoint(rand(length(xvec)))
    v = rand(length(xvec))

    # Hvp
    Hv = map(h->h*v, hess1)
    res = lazyhess*v
    @test minimum(isapprox.(Hv, res, atol=1e-10))
    @test res isa Tuple

    # H′vp
    wH = map(h->h'*adjoint(w), hess1)
    res = w*lazyhess
    @test minimum(isapprox.(wH, res, atol=1e-10))
    @test res isa Tuple
end

@testset "AbstractDifferentiation.jl" begin
    testFDMbackend = fdm_backend1
    @testset "FiniteDifferences" begin
        @testset "Derivative" begin
            test_fdm_derivatives(fdm_backend1,testFDMbackend)
            test_fdm_derivatives(fdm_backend2,testFDMbackend)
            test_fdm_derivatives(fdm_backend3,testFDMbackend)
        end
        @testset "Gradient" begin
            test_fdm_gradients(fdm_backend1,testFDMbackend)
            test_fdm_gradients(fdm_backend2,testFDMbackend)
            test_fdm_gradients(fdm_backend3,testFDMbackend
            )
        end
        @testset "Jacobian" begin
            test_fdm_jacobians(fdm_backend1,testFDMbackend)
            test_fdm_jacobians(fdm_backend2,testFDMbackend)
            test_fdm_jacobians(fdm_backend3,testFDMbackend)
        end
        @testset "Hessian" begin
            # Works but super slow
            test_fdm_hessians(fdm_backend1,testFDMbackend)
            test_fdm_hessians(fdm_backend2,testFDMbackend)
            test_fdm_hessians(fdm_backend3,testFDMbackend)
        end
        @testset "jvp" begin
            test_fdm_jvp(fdm_backend1,testFDMbackend)
            test_fdm_jvp(fdm_backend2,testFDMbackend)
            test_fdm_jvp(fdm_backend3,testFDMbackend)
        end
        @testset "j′vp" begin
            test_fdm_j′vp(fdm_backend1,testFDMbackend)
            test_fdm_j′vp(fdm_backend2,testFDMbackend)
            test_fdm_j′vp(fdm_backend3,testFDMbackend)
        end
        @testset "Lazy Derivative" begin
            test_fdm_lazy_derivatives(fdm_backend1,testFDMbackend)
            test_fdm_lazy_derivatives(fdm_backend2,testFDMbackend)
            test_fdm_lazy_derivatives(fdm_backend3,testFDMbackend)
        end
        @testset "Lazy Gradient" begin
            test_fdm_lazy_gradients(fdm_backend1,testFDMbackend)
            test_fdm_lazy_gradients(fdm_backend2,testFDMbackend)
            test_fdm_lazy_gradients(fdm_backend3,testFDMbackend)
        end
        @testset "Lazy Jacobian" begin
            test_fdm_lazy_jacobians(fdm_backend1,testFDMbackend)
            test_fdm_lazy_jacobians(fdm_backend2,testFDMbackend)
            test_fdm_lazy_jacobians(fdm_backend3,testFDMbackend)
        end
        @testset "Lazy Hessian" begin
            test_fdm_lazy_hessians(fdm_backend1,testFDMbackend)
            test_fdm_lazy_hessians(fdm_backend2,testFDMbackend)
            test_fdm_lazy_hessians(fdm_backend3,testFDMbackend)
        end
    end
    @testset "ForwardDiff" begin
        @testset "Derivative" begin
            test_fdm_derivatives(forwarddiff_backend1,testFDMbackend)
            test_fdm_derivatives(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Gradient" begin
            test_fdm_gradients(forwarddiff_backend1,testFDMbackend)
            test_fdm_gradients(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Jacobian" begin
            test_fdm_jacobians(forwarddiff_backend1,testFDMbackend)
            test_fdm_jacobians(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Hessian" begin
            # Fails due to setindex! in AbstractDifferentiation Hessian function
            @test_broken test_fdm_hessians(forwarddiff_backend1,testFDMbackend)
            @test_broken test_fdm_hessians(forwarddiff_backend2,testFDMbackend)
        end
        @testset "jvp" begin
            test_fdm_jvp(forwarddiff_backend1,testFDMbackend)
            test_fdm_jvp(forwarddiff_backend2,testFDMbackend)
        end
        @testset "j′vp" begin
            test_fdm_j′vp(forwarddiff_backend1,testFDMbackend)
            test_fdm_j′vp(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Lazy Derivative" begin
            test_fdm_lazy_derivatives(forwarddiff_backend1,testFDMbackend)
            test_fdm_lazy_derivatives(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Lazy Gradient" begin
            test_fdm_lazy_gradients(forwarddiff_backend1,testFDMbackend)
            test_fdm_lazy_gradients(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Lazy Jacobian" begin
            test_fdm_lazy_jacobians(forwarddiff_backend1,testFDMbackend)
            test_fdm_lazy_jacobians(forwarddiff_backend2,testFDMbackend)
        end
        @testset "Lazy Hessian" begin
            #@test_broken test_fdm_lazy_hessians(forwarddiff_backend1,testFDMbackend)
            #@test_broken test_fdm_lazy_hessians(forwarddiff_backend2,testFDMbackend)
        end
    end
end
