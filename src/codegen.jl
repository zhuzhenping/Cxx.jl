# This file contains the logic that turns the "pseudo-AST" created by @cxx
# into a clang AST, as well as performing the necessary work to do the
# actual codegen.

const CxxBuiltinTypes = Union(Type{Bool},Type{Int64},Type{Int32},Type{Uint32},
    Type{Uint64},Type{Float32},Type{Float64})

# # # Section 1: Pseudo-AST handling
#
# Recall from the general overview, that in order to get the AST information
# through to the staged function, we represent this information as type
# and decode it into a clang AST. The main vehicle to do this is CppNNS,
# which represents a C++ name, potentially qualified by templates or namespaces.
#
# E.g. the @cxx macro will rewrite `@cxx foo::bar()` into
#
# # This is a call, so we use the staged function cppcall
# cppcall(
#    # The name to be called is foo::bar. This gets turned into a tuple
#    # representing the `::` separated parts (which may include template
#    # instantiations, etc.). Note that we then create an instance, to make
#    # sure the staged function gets the type CppNNS{(:foo,:bar)} as its
#    # argument, so we may reconstruct the intent.
#    CppNNS{(:foo,:bar)}()
# )
#
# For more details on the macro, see cxxmacro.jl.
#
# In addition to CppNNS, there are several modifiers that can be applied such
# as `CppAddr` or `CppDeref` for introducing address-of or deref operators into
# the clang AST.
#
# These modifiers are handles by three functions, stripmodifier, resolvemodifier
# and resolvemodifier_llvm. As the names indicate, stripmodifier, just returns
# the modified NNS while resolvemodifier and resolvemodifier_llvm apply any
# necessary transformations at the LLVM, resp. Clang level.
#

# Pseudo-AST definitions

immutable CppNNS{chain}; end

immutable CppExpr{T,targs}; end

# Force cast the data portion of a jl_value_t to the given C++
# type
immutable JLCppCast{T,JLT}
    data::JLT
    function call{T,JLT}(::Type{JLCppCast{T}},data::JLT)
        JLT.mutable ||
            error("Can only pass pointers to mutable values. " *
                  "To pass immutables, use an array instead.")
        new{T,JLT}(data)
    end
end

cpptype{T,jlt}(p::Type{JLCppCast{T,jlt}}) = pointerTo(cpptype(T))

macro jpcpp_str(s,args...)
    JLCppCast{CppBaseType{symbol(s)}}
end

# Represents a forced cast form the value T
# (which may be any C++ compatible value)
# to the the C++ type To
immutable CppCast{T,To}
    from::T
end
CppCast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)
cast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)

# Represents a C++ Deference
immutable CppDeref{T}
    val::T
end
CppDeref{T}(val::T) = CppDeref{T}(val)

# Represent a C++ addrof (&foo)
immutable CppAddr{T}
    val::T
end
CppAddr{T}(val::T) = CppAddr{T}(val)

# On base types, don't do anything for stripmodifer/resolvemodifier. Since,
# we'll be dealing with these directly

stripmodifier{f}(cppfunc::Type{CppFptr{f}}) = cppfunc
stripmodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}},
    Type{CppRef{T,CVR}}, Type{CppValue{T,CVR}})) = p
stripmodifier{s}(p::Type{CppEnum{s}}) = p
stripmodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}) = p
stripmodifier(p::CxxBuiltinTypes) = p
stripmodifier(p::Type{Function}) = p
stripmodifier{T}(p::Type{Ptr{T}}) = p
stripmodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}) = p

resolvemodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}},
    Type{CppValue{T,CVR}}), e::pcpp"clang::Expr") = e
resolvemodifier(p::CxxBuiltinTypes, e::pcpp"clang::Expr") = e
resolvemodifier{T}(p::Type{Ptr{T}}, e::pcpp"clang::Expr") = e
resolvemodifier{s}(p::Type{CppEnum{s}}, e::pcpp"clang::Expr") = e
resolvemodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}, e::pcpp"clang::Expr") = e
resolvemodifier{f}(cppfunc::Type{CppFptr{f}}, e::pcpp"clang::Expr") = e
resolvemodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}, e::pcpp"clang::Expr") = e
resolvemodifier(p::Type{Function}, e::pcpp"clang::Expr") = e

# For everything else, perform the appropriate transformation
stripmodifier{T,To}(p::Type{CppCast{T,To}}) = T
stripmodifier{T}(p::Type{CppDeref{T}}) = T
stripmodifier{T}(p::Type{CppAddr{T}}) = T

resolvemodifier{T,To}(p::Type{CppCast{T,To}}, e::pcpp"clang::Expr") =
    createCast(e,cpptype(To),CK_BitCast)
resolvemodifier{T}(p::Type{CppDeref{T}}, e::pcpp"clang::Expr") =
    createDerefExpr(e)
resolvemodifier{T}(p::Type{CppAddr{T}}, e::pcpp"clang::Expr") =
    CreateAddrOfExpr(e)

# The LLVM operations themselves are slightly more tricky, since we need
# to translate from julia's llvm representation to clang's llvm representation
# (note that we still insert a bitcast later, so we only have to make sure it
# matches at a level that is bitcast-able)

# Builtin types and plain pointers are easy - they are represented the
# same in julia and Clang
resolvemodifier_llvm{ptr}(builder, t::Type{Ptr{ptr}}, v::pcpp"llvm::Value") = v
resolvemodifier_llvm(builder, t::CxxBuiltinTypes, v::pcpp"llvm::Value") = v

# Functions are also simple (for now) since we're just passing them through
# as an jl_function_t*
resolvemodifier_llvm(builder, t::Type{Function}, v::pcpp"llvm::Value") = v


function resolvemodifier_llvm{T,CVR}(builder,
    t::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}}), v::pcpp"llvm::Value")
    # CppPtr and CppRef are julia immutables with one field, so at the LLVM
    # level they are represented as LLVM structrs with one (pointer) field.
    # To get at the pointer itself, we simply need to emit an extract
    # instruction
    ExtractValue(v,0)
end

# Same situation as the pointer case
resolvemodifier_llvm{s}(builder, t::Type{CppEnum{s}}, v::pcpp"llvm::Value") =
    ExtractValue(v,0)
resolvemodifier_llvm{f}(builder, t::Type{CppFptr{f}}, v::pcpp"llvm::Value") =
    ExtractValue(v,0)

# Very similar to the pointer case, but since there may be additional wrappers
# hiding behind the T, we need to recursively call back into
# resolvemodifier_llvm
resolvemodifier_llvm{T,To}(builder, t::Type{CppCast{T,To}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))
resolvemodifier_llvm{T}(builder, t::Type{CppDeref{T}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))
resolvemodifier_llvm{T}(builder, t::Type{CppAddr{T}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))


# We need to cast from a named struct with two fields to an anonymous struct
# with two fields. This isn't bitcastable, so we need to use to sets of insert
# and extract instructions
function resolvemodifier_llvm{base,fptr}(builder,
        t::Type{CppMFptr{base,fptr}}, v::pcpp"llvm::Value")
    t = getLLVMStructType([julia_to_llvm(Uint64),julia_to_llvm(Uint64)])
    undef = getUndefValue(t)
    i1 = InsertValue(builder, undef, ExtractValue(v,0), 0)
    return InsertValue(builder, i1, ExtractValue(v,1), 1)
end

# We want to pass the content of a C-compatible julia struct to C++. Recall that
# (boxed) julia objects are layed out as
#
#  +---------------+
#  |     type      |    # pointer to the type of this julia object
#  +---------------+
#  |    field1     |    # Fields are stored inline and generally layed out
#  |    field2     |    # compatibly with (i.e. padded according to) the C
#  |     ...       |    # memory layout
#  +---------------+
#
# An LLVM value acts like a value to the first address of the object, i.e. the
# type pointer. Thus to get to the data, all we have to do is skip the type
# pointer.
#
function resolvemodifier_llvm{T,jlt}(builder,
        t::Type{JLCppCast{T,jlt}}, v::pcpp"llvm::Value")
    # Skip the type pointer to get to the actual data
    return CreateConstGEP1_32(builder,v,1)
end

# CppValue is perhaps the trickiest of them all, since we store the data in an
# array. This means that the CppValue is boxed and so we need to do some pointer
# arithmetic to get to the data:
#
#  +---------------+    +--------------------+
#  |   CppValue    |    |    Array{Uint8}    |
#  +---------------+    +--------------------+
#              ^                     ^
#  +-----------|---+      +----------|----+
#  |     type -|   |  /---|---> type-/    |
#  +---------------+  |   +---------------+
#  |     data -----|--/   |     data -----|-----> The data we want
#  +---------------+      +---------------+
#    We start here
#

function resolvemodifier_llvm{s,targs}(builder,
        t::Type{CppValue{s,targs}}, v::pcpp"llvm::Value")
    @assert v != C_NULL
    ty = cpptype(t)
    if !isPointerType(getType(v))
        dump(v)
        error("Value is not of pointer type")
    end
    # Get the array
    array = CreateConstGEP1_32(builder,v,1)
    arrayp = CreateLoad(builder,
        CreateBitCast(builder,array,getPointerTo(getType(array))))
    # Get the data pointer
    data = CreateConstGEP1_32(builder,arrayp,1)
    dp = CreateBitCast(builder,data,getPointerTo(getPointerTo(tollvmty(ty))))
    # A pointer to the actual data
    CreateLoad(builder,dp)
end

# Turning a CppNNS back into a Decl
#
# This can be considered a more fancy form of name lookup, etc. because it
# can it can descend into template declarations, as well as having to
# unmarshall the CppNNS structure. However, the basic functionality and
# caveats named in typetranslation.jl still apply.
#

function typeForNNS{nns}(T::Type{CppNNS{nns}})
    if length(nns) == 1 && (nns[1] <: CppPtr || nns[1] <: CppRef)
        return cpptype(nns[1])
    end
    typeForDecl(declfornns(T))
end

function declfornns{nns}(::Type{CppNNS{nns}},cxxscope=C_NULL)
    @assert isa(nns,Tuple)
    d = tu = translation_unit()
    for (i,n) in enumerate(nns)
        if !isa(n, Symbol)
            if n <: CppTemplate
                d = lookup_name((n.parameters[1],),C_NULL,d)
                cxxt = cxxtmplt(d)
                @assert cxxt != C_NULL
                arr = Any[]
                for arg in n.parameters[2]
                    if isa(arg,Type)
                        if arg <: CppNNS
                            push!(arr,typeForNNS(arg))
                        elseif arg <: CppPtr
                            push!(arr,cpptype(arg))
                        end
                    else
                        push!(arr,arg)
                    end
                end
                d = specialize_template_clang(cxxt,arr,cpptype)
                @assert d != C_NULL
                # TODO: Do we need to extend the cxxscope here
            else
                @assert d == tu
                t = cpptype(n)
                dump(t)
                dump(getPointeeType(t))
                # TODO: Do we need to extend the cxxscope here
                d = getAsCXXRecordDecl(getPointeeType(t))
            end
        else
            d = lookup_name((n,), cxxscope, d, i != length(nns))
        end
        @assert d != C_NULL
    end
    d
end


# # # Section 2: CodeGen
#
# # Overview
#
# To build perform code generation, we do the following.
#
# 1. Create Clang-level ParmVarDecls (buildargexprs)
#
# In order to get clang to know about the llvm level values, we create a
# ParmVarDecl for every LLVM Value we want clang to know about. ParmVarDecls
# are the clang AST-level representation of function parameters. Luckily, Clang
# doesn't care if these match the actual parameters to any function, so they
# are the perfect way to inject our LLVM values into Clang's AST. Note that
# these should be given the clang type that will pick up where we leave the
# LLVM value off. To explain what this means, consider
#
# julia> bar = pcpp"int"(C_NULL)
# julia> @cxx foo(*(bar))
#
# The parameter of the LLVM function will have the structure
#
# { # CppDeref
#   { # CppPtr
#       ptr : C_NULL
#   }
# }
#
# The two LLVM struct wrappers around the bare pointer are stripped in llvmargs.
# However, the type of Clang-level ParmVarDecl will still be `int *`, even
# though we'll end up passing the dereferenced value to Clang. Clang itself
# will take care of emitting the code for the dereference (we introduce the
# appropriate node into the AST in `resolvemodifier`).
#
# Finally note that we also need to create a DeclRefExpr, since the ParmVarDecl
# just declares the parameter (since it's a Decl), we need to reference the decl
# to put it into the AST.
#
# 2. Create the Clang AST and emit it
#
# This basically amounts to finding the correct method to call in order to build
# up AST node we need and calling it with the DeclRefExpr's we obtained in step
# 1. One further tricky aspect is that for the next step we need to know the
# return type we'll get back from clang. In general, all clang Expression need
# to be tagged with the result type of the expression in order to construct
# them, which for our purposes can defeat the purpose (since we may need to
# provide in to construct the AST, even though we don't it yet). In cases where
# that information is still useful, it can be extracted from an Expr *, using
# the `GetExprResultType` function. However, even in other cases, we can still
# convince clang to tell us what the return type is by making use of the C++
# standard required type inference capabilities used for auto and
# decltype(auto) (we use the latter to make sure we actually return references
# when a function we're calling is declared a reference). The remaining case
# is that where we're calling a constructor for which the return type is
# obviously known.
#
# 3. Create an LLVM function that will be passed to llvmcall.
#
# The argument types of the LLVM function will still be julia representation
# of the underlying values and potentially any modifiers. This is taken care
# of by the resolvemodifier_llvm function above which is called by `llvmargs`
# below.
# The reason for this mostly historic and could be simplified,
# though some LLVM-level processing will always be necessary.
#
# 4. Hook up the LLVM level representation to Clang's (associateargs)
#
# This is fairly simple. We can simply tell clang which llvm::Value to use.
# Usually, this would be the llvm::Value representing the actual argument to the
# LLVM-level function, but it's also fine to use our adjusted Values (LLVM
# doesn't really distinguish).
#

#
# `f` is the function we are emitting into, i.e. the function that gets
# julia-level arguments. This function, goes through all the arguments and
# applies any necessary llvm-level transformation for the llvm values to be
# compatible with the type expected by clang.
#
# Returns the list of processed arguments
function llvmargs(builder, f, argt)
    args = Array(pcpp"llvm::Value", length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall(
            (:get_nth_argument,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),f,i-1))
        @assert args[i] != C_NULL
        args[i] = resolvemodifier_llvm(builder, t, args[i])
        if args[i] == C_NULL
            error("Failed to process argument")
        end
    end
    args
end

function buildargexprs(argt)
    callargs = pcpp"clang::Expr"[]
    pvds = pcpp"clang::ParmVarDecl"[]
    for i in 1:length(argt)
        #@show argt[i]
        t = argt[i]
        st = stripmodifier(t)
        argit = cpptype(st)
        st <: CppValue && (argit = pointerTo(argit))
        argpvd = CreateParmVarDecl(argit)
        push!(pvds, argpvd)
        expr = CreateDeclRefExpr(argpvd)
        st <: CppValue && (expr = createDerefExpr(expr))
        expr = resolvemodifier(t, expr)
        push!(callargs,expr)
    end
    callargs, pvds
end

function associateargs(builder,argt,args,pvds)
    for i = 1:length(args)
        t = stripmodifier(argt[i])
        argit = cpptype(t)
        if t <: CppValue
            argit = pointerTo(argit)
        end
        AssociateValue(pvds[i],argit,args[i])
    end
end

# # #

# Some utilities

function irbuilder()
    pcpp"clang::CodeGen::CGBuilderTy"(
        ccall((:clang_get_builder,libcxxffi),Ptr{Void},()))
end
function julia_to_llvm(x::ANY)
    pcpp"llvm::Type"(ccall(:julia_type_to_llvm,Ptr{Void},(Any,),x))
end

# @cxx llvm::dyn_cast{vcpp"clang::ClassTemplateDecl"}
function cxxtmplt(p::pcpp"clang::Decl")
    pcpp"clang::ClassTemplateDecl"(
        ccall((:cxxtmplt,libcxxffi),Ptr{Void},(Ptr{Void},),p))
end


# Checks the arguments to make sure we have concrete C++ compatible
# types in the signature. This is used both in cases where type inference
# cannot infer the appropriate argument types during staging (in which case
# the error here will cause it to fall back to runtime) as well as when the
# user has bad types (in which case you'll get a compile-time (but not stage-time)
# error.
function check_args(argt,f)
    for (i,t) in enumerate(argt)
        if isa(t,UnionType) || (isa(t,DataType) && t.abstract) ||
            (!(t <: CppPtr) && !(t <: CppRef) && !(t <: CppValue) && !(t <: CppCast) &&
                !(t <: CppFptr) && !(t <: CppMFptr) && !(t <: CppEnum) &&
                !(t <: CppDeref) && !(t <: CppAddr) && !(t <: Ptr) &&
                !(t <: JLCppCast) &&
                !in(t,[Bool, Uint8, Int32, Uint32, Int64, Uint64, Float32, Float64]))
            error("Got bad type information while compiling $f (got $t for argument $i)")
        end
    end
end


#
# Code generation for value references (basically everything that's not a call).
# Syntactically, these are of the form
#
#   - @cxx foo
#   - @cxx foo::bar
#   - @cxx foo->bar
#

# Handle member references, i.e. syntax of the form `@cxx foo->bar`
stagedfunction cxxmemref(expr, args...)
    this = args[1]
    check_args([this], expr)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end
    exprs, pvds = buildargexprs([this])
    me = BuildMemberReference(exprs[1], cpptype(this), this <: CppPtr,
        expr.parameters[1])
    isaddrof && (me = CreateAddrOfExpr(me))
    emitRefExpr(me, pvds[1], this)
end

# Handle all other references. This is more complicated than the above for two
# reasons.
# a) We can reference types (e.g. `@cxx int`)
# b) Clang cares about how the reference was qualified, so we need to deal with
#    cxxscopes.
stagedfunction cxxref(expr)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end

    cxxscope = newCXXScopeSpec()
    d = declfornns(expr,cxxscope)
    @assert d.ptr != C_NULL

    # If this is a typedef or something we'll try to get the primary one
    primary_decl = to_decl(primary_ctx(toctx(d)))
    if primary_decl != C_NULL
        d = primary_decl
    end

    if isaValueDecl(d)
        expr = dre = CreateDeclRefExpr(d;
            islvalue = isaVarDecl(d) ||
                (isaFunctionDecl(d) && !isaCXXMethodDecl(d)),
            cxxscope=cxxscope)

        deleteCXXScopeSpec(cxxscope)

        if isaddrof
            expr = CreateAddrOfExpr(dre)
        end

        return emitRefExpr(expr)
    else
        return :( $(juliatype(QualType(typeForDecl(d)))) )
    end
end

function emitRefExpr(expr, pvd = nothing, ct = nothing)
    # Ask clang what the type is we're expecting
    rt = GetExprResultType(expr)

    if isFunctionType(rt)
        error("Cannot reference function by value")
    end

    rett = juliatype(rt)

    @assert !(rett <: None)

    needsret = false
    if rett <: CppValue
        needsret = true
    end

    argt = Type[]
    needsret && push!(argt,Ptr{Uint8})
    (pvd != nothing) && push!(argt,ct)

    llvmrt = julia_to_llvm(rett)
    f = CreateFunction(llvmrt, map(julia_to_llvm,argt))
    state = setup_cpp_env(f)
    builder = irbuilder()

    args = llvmargs(builder, f, argt)

    (pvd != nothing) && associateargs(builder,[ct],args[needsret ? 1:1 : 2:2],[pvd])

    MarkDeclarationsReferencedInExpr(expr)
    if !needsret
        ret = EmitAnyExpr(expr)
    else
        EmitAnyExprToMem(expr, args[1], false)
    end

    createReturn(builder,f,ct !== nothing ? (ct,) : (),
        ct !== nothing ? [ct] : [],llvmrt,rett,rt,ret,state)
end

#
# Call Handling
#
# There are four major cases we need to take care of:
#
# 1) Membercall, e.g. @cxx foo->bar(...)
# 2) Regular call, e.g. @cxx foo()
# 3) Constructors e.g. @cxx fooclass()
# 4) Heap allocation, e.g. @cxxnew fooclass()
#

function _cppcall(expr, thiscall, isnew, argt)
    check_args(argt, expr)

    callargs, pvds = buildargexprs(argt)

    rett = Void
    isne = isctce = isce = false
    ce = nE = ctce = C_NULL

    if thiscall # membercall
        @assert expr <: CppNNS
        fname = expr.parameters[1][1]
        @assert isa(fname,Symbol)

        me = BuildMemberReference(callargs[1], cpptype(argt[1]),
            argt[1] <: CppPtr, fname)
        (me == C_NULL) && error("Could not find member $name")

        ce = BuildCallToMemberFunction(me,callargs[2:end])
    else
        targs = ()
        if expr <: CppTemplate
            targs = expr.args[2]
            expr = expr.args[1]
        end

        d = declfornns(expr)
        @assert d.ptr != C_NULL
        # If this is a typedef or something we'll try to get the primary one
        primary_decl = to_decl(primary_ctx(toctx(d)))
        if primary_decl != C_NULL
            d = primary_decl
        end
        # Let's see if we're constructing something.
        cxxd = dcastCXXRecordDecl(d)
        fname = symbol(_decl_name(d))
        cxxt = cxxtmplt(d)
        if cxxd != C_NULL || cxxt != C_NULL
            if cxxd == C_NULL
                cxxd = specialize_template(cxxt,targs,cpptype)
            end

            # targs may have changed because the name is canonical
            # but the default targs may be substituted by typedefs
            targs = getTemplateParameters(cxxd)

            T = CppBaseType{fname}
            if !isempty(targs)
                T = CppTemplate{T,tuple(targs...)}
            end
            rett = juliart = T = CppValue{T,NullCVR}

            if isnew
                rett = CppPtr{T,NullCVR}
                nE = BuildCXXNewExpr(QualType(typeForDecl(cxxd)),callargs)
                if nE == C_NULL
                    error("Could not construct `new` expression")
                end
                MarkDeclarationsReferencedInExpr(nE)
            else
                rt = QualType(typeForDecl(cxxd))
                ctce = BuildCXXTypeConstructExpr(rt,callargs)
            end
        else
            myctx = getContext(d)
            while declKind(myctx) == LinkageSpec
                myctx = getParentContext(myctx)
            end
            @assert myctx != C_NULL
            dne = BuildDeclarationNameExpr(split(string(fname),"::")[end],myctx)

            ce = CreateCallExpr(dne,callargs)
        end
    end

    EmitExpr(ce,nE,ctce, argt, pvds, rett)
end

# Emits either a CallExpr, a NewExpr, or a CxxConstructExpr, depending on which
# one is non-NULL
function EmitExpr(ce,nE,ctce, argt, pvds, rett = Void; kwargs...)
    builder = irbuilder()
    llvmargt = [argt...]
    issret = false
    rslot = C_NULL
    rt = C_NULL
    ret = C_NULL

    if ce != C_NULL
        # First we need to get the return type of the C++ expression
        rt = BuildDecltypeType(ce)
        rett = juliatype(rt)

        issret = (rett != None) && rett <: CppValue
    elseif ctce != C_NULL
        issret = true
        rt = GetExprResultType(ctce)
        #@show rt
    end
    if issret
        llvmargt = [Ptr{Uint8},llvmargt]
    end

    llvmrt = julia_to_llvm(rett)

    # Let's create an LLVM function
    f = CreateFunction(issret ? julia_to_llvm(Void) : llvmrt,
        map(julia_to_llvm,llvmargt))

    # Clang's code emitter needs some extra information about the function, so let's
    # initialize that as well
    state = setup_cpp_env(f)

    builder = irbuilder()

    # First compute the llvm arguments (unpacking them from their julia wrappers),
    # then associate them with the clang level variables
    args = llvmargs(builder, f, llvmargt)
    associateargs(builder, argt, issret ? args[2:end] : args,pvds)

    if ce != C_NULL
        if issret
            rslot = CreateBitCast(builder,args[1],getPointerTo(toLLVM(rt)))
        end
        MarkDeclarationsReferencedInExpr(ce)
        ret = EmitCallExpr(ce,rslot)
        if rett <: CppValue
            ret = C_NULL
        end
    elseif nE != C_NULL
        ret = EmitCXXNewExpr(nE)
    elseif ctce != C_NULL
        MarkDeclarationsReferencedInExpr(ctce)
        EmitAnyExprToMem(ctce,args[1],true)
    end

    # Common return path for everything that's calling a normal function
    # (i.e. everything but constructors)
    createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; kwargs...)
end

#
# Common return path for a number of codegen functions. It takes cares of
# actually emitting the llvmcall and packaging the LLVM values we get
# from clang back into the format that julia expects. Unfortunately, it needs
# access to an alarming number of parameters. Hopefully this can be cleaned up
# in the future
#
function createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; argidxs = [1:length(argt)])
    argt = Type[argt...]

    jlrt = rett
    if ret == C_NULL
        jlrt = Void
        CreateRetVoid(builder)
    else
        #@show rett
        if rett == Void
            CreateRetVoid(builder)
        else
            if rett <: CppPtr || rett <: CppRef || rett <: CppEnum || rett <: CppFptr
                undef = getUndefValue(llvmrt)
                elty = getStructElementType(llvmrt,0)
                ret = CreateBitCast(builder,ret,elty)
                ret = InsertValue(builder, undef, ret, 0)
            elseif rett <: CppMFptr
                undef = getUndefValue(llvmrt)
                i1 = InsertValue(builder,undef,CreateBitCast(builder,
                        ExtractValue(ret,0),getStructElementType(llvmrt,0)),0)
                ret = InsertValue(builder,i1,CreateBitCast(builder,
                        ExtractValue(ret,1),getStructElementType(llvmrt,1)),1)
            end
            CreateRet(builder,ret)
        end
    end

    cleanup_cpp_env(state)

    args2 = Expr[]
    for (j,i) = enumerate(argidxs)
        if argt[j] <: JLCppCast
            push!(args2,:(args[$i].data))
            argt[j] = JLCppCast.parameters[1]
        else
            push!(args2,:(args[$i]))
        end
    end

    if (rett != None) && rett <: CppValue
        arguments = [:(pointer(r.data)), args2]
        size = cxxsizeof(rt)
        return Expr(:block,
            :( r = ($(rett))(Array(Uint8,$size)) ),
            Expr(:call,:llvmcall,f.ptr,Void,tuple(llvmargt...),arguments...),
            :r)
    else
        return Expr(:call,:llvmcall,f.ptr,rett,tuple(argt...),args2...)
    end
end

# And finally the staged functions to drive the call logic above
stagedfunction cppcall(expr, args...)
    _cppcall(expr, false, false, args)
end

stagedfunction cppcall_member(expr, args...)
    _cppcall(expr, true, false, args)
end

stagedfunction cxxnewcall(expr, args...)
    _cppcall(expr, false, true, args)
end
