# functional definitions

import PDESolver.createFunctional

@doc """
###AdvectionEquationMod.QfluxData

Data type for storing relevant information pertaining to an a functional or an
objective function.

**Members**

*  `bcnums` : boundary condition groups on which the functional is to be
                             computed.
*  `val` : Computed value of the functional
*  `target_qFlux` : Target value for the functional qFlux

"""->
mutable struct QfluxData{Topt} <: AbstractBoundaryFunctional{Topt}
  bcnums::Array{Int,1}
  val::Topt
  target_qflux::Topt
end # End type OfluxData

"""
  Constructor for QfluxData
"""
function QfluxDataConstructor(::Type{Topt}, mesh, sbp, eqn, opts, bcnums) where Topt

  val = zero(Topt)
  target_qflux = zero(Topt)
  return QfluxData{Topt}(bcnums, val, target_qflux)
end

"""
  Functional that integrates the solution q over the specified boundary(/ies)

  **Fields**

   * bcnums: the boundary condition groups the functional is computed over
   * val: the value of the functional, initially 0.0

"""
mutable struct IntegralQData{Topt} <: AbstractBoundaryFunctional{Topt}
  bcnums::Array{Int, 1}
  val::Topt
end

"""
  Constructor for IntegralQData
"""
function IntegralQDataConstructor(::Type{Topt}, mesh, sbp, eqn, opts,
                                  bcnums) where Topt

  val = 0.0
  return IntegralQData{Topt}(bcnums, val)
end


"""
  See the generic method for docs.
"""
function createFunctional(mesh::AbstractMesh,
                  sbp::AbstractOperator,
                  eqn::AdvectionData{Tsol}, opts,
                  functional_name::AbstractString,
                  functional_bcs::Vector{I}) where {Tsol, I<:Integer}

  func_constructor = FunctionalDict[functional_name]
  functional = func_constructor(Tsol, mesh, sbp, eqn, opts, functional_bcs)

  return functional
end


"""
  Maps names of functionals to their outer constructor functions

  See `FunctionalDict` in the Euler module for descriptions of the constructors
  and arguments.
"""
global const FunctionalDict = Dict{String, Function}(
"qflux" => QfluxDataConstructor,
"integralq" => IntegralQDataConstructor,
)


