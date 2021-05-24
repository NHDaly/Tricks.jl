module Tricks

using Base: rewrap_unionall, unwrap_unionall, uncompressed_ast
using Base: CodeInfo

export static_hasmethod, static_methods, compat_hasmethod, static_fieldnames, static_fieldcount, static_fieldtypes

# This is used to create the CodeInfo returned by static_hasmethod.
_hasmethod_false(@nospecialize(f), @nospecialize(t)) = false
_hasmethod_true(@nospecialize(f), @nospecialize(t)) = true

"""
    static_hasmethod(f, type_tuple::Type{<:Tuple)

Like `hasmethod` but runs at compile-time (and does not accept a worldage argument).
"""
@generated function static_hasmethod(
    @nospecialize(f),
    @nospecialize(t::Type{T}),
    @nospecialize(kwnames_type_tuple::Type{<:Tuple})=Type{Tuple{}},
    ) where {T<:Tuple}
    # The signature type:
    world = typemax(UInt)
    method_insts = Core.Compiler.method_instances(f.instance, T, world)

    ftype = Tuple{f, fieldtypes(T)...}
    kwnames = only(kwnames_type_tuple.parameters).parameters
    covering_method_insts = filter(method_insts) do mi
        ftype <: mi.def.sig && has_kwargs(mi.def, kwnames)
    end

    method_doesnot_exist = isempty(covering_method_insts)
    ret_func = method_doesnot_exist ? _hasmethod_false : _hasmethod_true
    ci_orig = uncompressed_ast(typeof(ret_func).name.mt.defs.func)
    ci = ccall(:jl_copy_code_info, Ref{CodeInfo}, (Any,), ci_orig)

    # Now we add the edges so if a method is defined this recompiles
    if method_doesnot_exist
        # No method so attach to method table
        mt = f.name.mt
        typ = rewrap_unionall(Tuple{f, unwrap_unionall(T).parameters...}, T)
        ci.edges = Core.Compiler.vect(mt, typ)
    else  # method exists, attach edges to all instances
        ci.edges = covering_method_insts
    end
    return ci
end

"checks if the method `m` accepts keyword arguments with the names `kwnames`"
function has_kwargs(m::Method, kwnames)
    isempty(kwnames) && return true  # no kwargs means any method matches

    mt = Base.get_methodtable(m)
    !isdefined(mt, :kwsorter) && return false  # no kwsorter means no keywords for sure.

    kws = Base.kwarg_decl(m, typeof(mt.kwsorter))
    isempty(kws) && return false  # no keyword args means doesn't accept these

    # if accepts kwargs... then definately accepts these names
    endswith(string(kws[end]), "...") && return true

    return kwnames ⊆ kws
end


function create_codeinfo_with_returnvalue(argnames, spnames, sp, value)
    expr = Expr(:lambda,
        argnames,
        Expr(Symbol("scope-block"),
            Expr(:block,
                Expr(:return, value),
            )
        )
    )
    if spnames !== nothing
        expr = Expr(Symbol("with-static-parameters"), expr, spnames...)
    end
    ci = ccall(:jl_expand, Any, (Any, Any), expr, @__MODULE__)
    return ci
end

"""
    static_methods(f, [type_tuple::Type{<:Tuple])
    static_methods(@nospecialize(f)) = _static_methods(Main, f, Tuple{Vararg{Any}})

Like `methods` but runs at compile-time (and does not accept a worldage argument).
"""
static_methods(@nospecialize(f)) = static_methods(f, Tuple{Vararg{Any}})
@generated function static_methods(@nospecialize(f) , @nospecialize(_T::Type{T})) where {T <: Tuple}
    list_of_methods = methods(f.instance, T)
    ci = create_codeinfo_with_returnvalue([Symbol("#self#"), :f, :_T], [:T], (:T,), :($list_of_methods))

    # Now we add the edges so if a method is defined this recompiles
    mt = f.name.mt
    ci.edges = Core.Compiler.vect(mt, Tuple{Vararg{Any}})
    return ci
end

@static if VERSION < v"1.3"
    const compat_hasmethod = hasmethod
else
    const compat_hasmethod = static_hasmethod
end

Base.@pure static_fieldnames(t::Type) = Base.fieldnames(t)
Base.@pure static_fieldtypes(t::Type) = Base.fieldtypes(t)
Base.@pure static_fieldcount(t::Type) = Base.fieldcount(t)

end  # module
