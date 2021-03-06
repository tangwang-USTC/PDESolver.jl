module SimpleODEMod

using PDESolver
using SolverCommon
using ArrayViews
import ArrayViews.view
using ODLCommonTools
using SummationByParts
using PdePumiInterface
using NonlinearSolvers  # need this because not using call_nlsolver
using Jacobian
using MPI
using Utils
using Input
import ODLCommonTools: sview
export SimpleODEData, SimpleODEData_ #getMass, array3DTo1D, array1DTo3D
export evalResidual, init, run_simpleode # exported from simpleODE.jl
export ICDict              # exported from ic.jl
export ode_pre_func, ode_post_func    # exported from simpleODE_func.jl


abstract type AbstractSimpleODEData{Tsol, Tres} <: AbstractSolutionData{Tsol, Tres} end
abstract type SimpleODEData{Tsol, Tres, Tdim} <: AbstractSimpleODEData{Tsol, Tres} end


# TODO: which of these
include("types.jl")
include("check_options.jl")
include(joinpath(Pkg.dir("PDESolver"), "src/solver/debug.jl"))  # debug macro
include("simpleODE.jl")
include("common_funcs.jl")
include("ic.jl")
include("eqn_deepcopy.jl")
include("startup_func.jl")

global const PhysicsName = "SimpleODE"
register_physics(PhysicsName, SimpleODEMod, createObjects, checkOptions)

@doc """
### SimpleODEMod.calcMassMatrix

  This function calculate the mass matrix and returns it.
  Beause w are using SBP operators, the mass matrix is diagonal, so it is
  stored in a vector.

  Arguments:
    mesh: AbstractMesh
    sbp: SBP operator
    eqn: an implementation of SimpleODEData. Does not have to be fully initialized.

  Outputs:
    M: vector containing mass matrix

"""->
function calcMassMatrix(mesh::AbstractMesh{Tmsh}, 
sbp::AbstractSBP, eqn::SimpleODEData{Tsol, Tres, Tdim}) where {Tmsh,  Tsol, Tres, Tdim}
# calculate the (diagonal) mass matrix as a vector
# return the vector M

  M = zeros(Tmsh, mesh.numDof)
  for i=1:mesh.numEl
    for j=1:sbp.numnodes
      for k=1:mesh.numDofPerNode
        dofnum_k = mesh.dofs[k,j,i]
        # multiplication is faster than division, so do the division here
        # and then multiply solution vector times M
        M[dofnum_k] += (sbp.w[j]/mesh.jac[j,i])
      end
    end
  end

  return M

end     # end of calcMassMatrix function

# functions needed to make it compatible with the NonLinearSolvers module
function matVecA0inv(mesh::AbstractMesh{Tmsh}, 
sbp::AbstractSBP, eqn::SimpleODEData{Tsol, Tres, Tdim},
opts, res_arr::AbstractArray{Tsol, 3}) where {Tmsh, Tsol, Tdim, Tres}

  return nothing
end

function matVecA0(mesh::AbstractMesh{Tmsh},
sbp::AbstractSBP, eqn::SimpleODEData{Tsol, Tres, Tdim}, opts,
res_arr::AbstractArray{Tsol, 3}) where {Tmsh, Tsol, Tdim, Tres}

  return nothing
end

function majorIterationCallback(itr, mesh::AbstractMesh, sbp::AbstractSBP, eqn::AbstractSimpleODEData, opts)

  return nothing
end

end # end module
