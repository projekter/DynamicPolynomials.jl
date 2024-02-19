export Variable, @polyvar, @ncpolyvar, @polycvar

function polyarrayvar(
    variable_order,
    monomial_order,
    complex_kind,
    prefix,
    indices...,
)
    return map(
        i -> Variable(
            "$(prefix)[$(join(i, ","))]",
            variable_order,
            monomial_order,
            complex_kind,
        ),
        Iterators.product(indices...),
    )
end

function buildpolyvar(var, variable_order, monomial_order, complex_kind)
    if isa(var, Symbol)
        var,
        :(
            $(esc(var)) = $Variable(
                $"$var",
                $variable_order,
                $monomial_order,
                $complex_kind,
            )
        )
    else
        isa(var, Expr) || error("Expected $var to be a variable name")
        Base.Meta.isexpr(var, :ref) ||
            error("Expected $var to be of the form varname[idxset]")
        (2 ≤ length(var.args)) ||
            error("Expected $var to have at least one index set")
        varname = var.args[1]
        prefix = string(varname)
        varname,
        :(
            $(esc(varname)) = polyarrayvar(
                $(variable_order),
                $(monomial_order),
                $(complex_kind),
                $prefix,
                $(esc.(var.args[2:end])...),
            )
        )
    end
end

function buildpolyvars(args, variable_order, monomial_order, complex_kind)
    vars = Symbol[]
    exprs = []
    for arg in args
        var, expr =
            buildpolyvar(arg, variable_order, monomial_order, complex_kind)
        push!(vars, var)
        push!(exprs, expr)
    end
    return vars, exprs
end

# Inspired from `JuMP.Containers._extract_kw_args`
function _extract_kw_args(args, variable_order, complex_kind)
    positional_args = Any[]
    monomial_order = :($(MP.Graded{MP.LexOrder}))
    for arg in args
        if Base.Meta.isexpr(arg, :(=))
            if arg.args[1] == :variable_order
                variable_order = esc(arg.args[2])
            elseif arg.args[1] == :monomial_order
                monomial_order = esc(arg.args[2])
            elseif arg.args[1] == :complex
                complex_kind = arg.args[2] == :true ? cpFull : cpNone
            else
                error("Unrecognized keyword argument `$(arg.args[1])`")
            end
        else
            push!(positional_args, arg)
        end
    end
    return positional_args, variable_order, monomial_order, complex_kind
end

# Variable vector x returned garanteed to be sorted so that if p is built with x then vars(p) == x
macro polyvar(args...)
    pos_args, variable_order, monomial_order, complex_kind =
        _extract_kw_args(args, :($(Commutative{CreationOrder})), cpNone)
    vars, exprs =
        buildpolyvars(pos_args, variable_order, monomial_order, complex_kind)
    return :($(foldl((x, y) -> :($x; $y), exprs, init = :()));
    $(Expr(:tuple, esc.(vars)...)))
end

macro ncpolyvar(args...)
    pos_args, variable_order, monomial_order, complex_kind =
        _extract_kw_args(args, :($(NonCommutative{CreationOrder})), cpNone)
    vars, exprs =
        buildpolyvars(pos_args, variable_order, monomial_order, complex_kind)
    return :($(foldl((x, y) -> :($x; $y), exprs, init = :()));
    $(Expr(:tuple, esc.(vars)...)))
end

macro polycvar(args...)
    pos_args, variable_order, monomial_order, complex_kind =
        _extract_kw_args(args, :($(Commutative{CreationOrder})), cpFull)
    vars, exprs =
        buildpolyvars(pos_args, variable_order, monomial_order, complex_kind)
    return :($(foldl((x, y) -> :($x; $y), exprs, init = :()));
    $(Expr(:tuple, esc.(vars)...)))
end

abstract type AbstractVariableOrdering end

struct CreationOrder <: AbstractVariableOrdering
    id::Int
end

function instantiate(::Type{CreationOrder})
    # gensym returns something like Symbol("##42")
    # we first remove "##" and then parse it into an Int
    id = parse(Int, string(gensym())[3:end])
    return CreationOrder(id)
end

struct Commutative{O<:AbstractVariableOrdering} <: AbstractVariableOrdering
    order::O
end

iscomm(::Type{<:Commutative}) = false
function instantiate(::Type{Commutative{O}}) where {O}
    return Commutative(instantiate(O))
end

struct NonCommutative{O<:AbstractVariableOrdering} <: AbstractVariableOrdering
    order::O
end

iscomm(::Type{<:NonCommutative}) = false
function instantiate(::Type{NonCommutative{O}}) where {O}
    return NonCommutative(instantiate(O))
end

@enum ComplexKind cpNone cpFull cpConj cpReal cpImag

struct Variable{V,M} <: AbstractVariable
    name::String
    kind::ComplexKind
    variable_order::V

    function Variable{V,M}(
        name::AbstractString,
        kind::ComplexKind = cpNone,
    ) where {V<:AbstractVariableOrdering,M<:MP.AbstractMonomialOrdering}
        return new{V,M}(convert(String, name), kind, instantiate(V))
    end

    function Variable(
        name::AbstractString,
        ::Type{V},
        ::Type{M},
        kind::ComplexKind = cpNone,
    ) where {V<:AbstractVariableOrdering,M<:MP.AbstractMonomialOrdering}
        return new{V,M}(convert(String, name), kind, instantiate(V))
    end

    function Variable(
        from::Variable{V,M},
        kind::ComplexKind,
    ) where {V<:AbstractVariableOrdering,M<:MP.AbstractMonomialOrdering}
        (from.kind == cpNone && kind == cpNone) ||
            (from.kind != cpNone && kind != cpNone) ||
            error("Cannot change the complex type of an existing variable")
        return new{V,M}(from.name, kind, from.variable_order)
    end
end

Base.hash(x::Variable, u::UInt) = hash(x.variable_order.order.id, u)
Base.broadcastable(x::Variable) = Ref(x)

MP.name(v::Variable) = v.name
function MP.name_base_indices(v::Variable)
    splits = split(v.name, r"[\[,\]]\s*", keepempty = false)
    if length(splits) == 1
        return v.name, Int[]
    else
        return splits[1], parse.(Int, splits[2:end])
    end
end

MP.monomial(v::Variable) = Monomial(v)
MP.variables(v::Variable) = [v]
MP.ordering(v::Variable) = MP.ordering(typeof(v))
MP.ordering(::Type{Variable{V,M}}) where {V,M} = M

iscomm(::Type{Variable{C}}) where {C} = C

Base.isreal(x::Variable{C}) where {C} = x.kind != cpFull && x.kind != cpConj
MP.isrealpart(x::Variable{C}) where {C} = x.kind == cpReal
MP.isimagpart(x::Variable{C}) where {C} = x.kind == cpImag
MP.isconj(x::Variable{C}) where {C} = x.kind == cpConj
function MP.ordinary_variable(x::Variable)
    return x.kind == cpNone || x.kind == cpFull ? x : Variable(x, cpFull)
end

function Base.conj(x::Variable)
    if x.kind == cpFull
        return Variable(x, cpConj)
    elseif x.kind == cpConj
        return Variable(x, cpFull)
    else
        return x
    end
end

function Base.real(x::Variable)
    if x.kind == cpFull || x.kind == cpConj
        return Variable(x, cpReal)
    else
        return x
    end
end
function Base.imag(x::Variable{V,M}) where {V,M}
    if x.kind == cpFull
        return Variable(x, cpImag)
    elseif x.kind == cpConj
        return _Term{V,M,Int}(-1, Monomial(Variable(x, cpImag)))
    else
        return MA.Zero()
    end
end

function mergevars_to!(
    vars::Vector{PV},
    varsvec::Vector{Vector{PV}},
) where {PV<:Variable}
    empty!(vars)
    n = length(varsvec)
    is = ones(Int, n)
    maps = zeros.(Int, length.(varsvec))
    nonempty = BitSet(findall(!isempty, varsvec))
    while !isempty(nonempty)
        imin = 0
        for i in nonempty
            if imin == 0 || varsvec[i][is[i]] > varsvec[imin][is[imin]]
                imin = i
            end
        end
        var = varsvec[imin][is[imin]]
        push!(vars, var)
        for i in nonempty
            if var == varsvec[i][is[i]]
                maps[i][is[i]] = length(vars)
                if is[i] == length(varsvec[i])
                    pop!(nonempty, i)
                else
                    is[i] += 1
                end
            end
        end
    end
    return maps
end
function mergevars(varsvec::Vector{Vector{PV}}) where {PV<:Variable}
    vars = PV[]
    maps = mergevars_to!(vars, varsvec)
    return vars, maps
end
function mergevars_of(::Type{Variable{V,M}}, polys::AbstractVector) where {V,M}
    varsvec =
        Vector{Variable{V,M}}[variables(p) for p in polys if p isa PolyType]
    # TODO avoid computing `maps`
    return mergevars(varsvec)
end
