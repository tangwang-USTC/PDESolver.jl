# auxiliary types and functions for Newton's method
# linear operator, newton data etc.

@doc """
  This type holds the data required by [`newtonInner`](@ref) as well as
  configuration settings.

  **Public Fields**

   * myrank: MPI rank
   * commsize: MPI communicator size
   * itr: number of iterations
   * res_norm_i: current iteration residual norm
   * res_norm_i_1: previous iteration residual norm
   * step_norm_i: current iteration newton step norm
   * step_norm_i_1: previous iteration newton step norm
   * res_norm_rel: norm of residual used as the reference point when computing
                   relative residuals.  If this is -1 on entry to newtonInner,
                   then the norm of the initial residual is used.
   * step_fac: factor used in step size limiter
   * res_reltol: nonlinear relative residual tolerance
   * res_abstol: nonlinear residual absolute tolerance
   * step_tol: step norm tolerance
   * itermax: maximum number of newton iterations
   * use_inexact_nk: true if inexact-NK should be used, false otherwise
   * krylov_gamma: parameter used by inexact newton-krylov
   * recalc_policy: a [`RecalculationPolicy`](@ref).
   * ls: a [`LinearSolver`](@ref)
   * fconv: convergence.dat file handle (or DevNull if not used)
   * verbose: how much logging/output to do

  **Options Keys**

  If `res_reltol0` is negative, the residual of the initial condition will be
  used for res_norm_rel

  `newton_verbosity` is used to the `verbose` field
"""->
mutable struct NewtonData{Tsol, Tres, Tsolver <: LinearSolver}

  # MPI info
  myrank::Int
  commsize::Int
  itr::Int  # newton iteration number

  # working variables
  res_norm_i::Float64  # current step residual norm
  res_norm_i_1::Float64  # previous step residual norm
  step_norm_i::Float64
  step_norm_i_1::Float64
  res_norm_rel::Float64  # norm of the residual used for the relative residual
                         # tolerance
  set_rel_norm::Bool # whether or not to use the initial residual as the
                     # res_norm_rel
  step_fac::Float64

  # tolerances (newton)
  res_reltol::Float64
  res_abstol::Float64
  step_tol::Float64
  itermax::Int

  # inexact Newton-Krylov parameters
  use_inexact_nk::Bool
  krylov_gamma::Float64  # update parameter for krylov tolerance

  recalc_policy::RecalculationPolicy
  ls::Tsolver
  res_0::Array{PetscScalar, 1}
  delta_q_vec::Array{PetscScalar, 1}
  fconv::IO  # convergence.dat, rank 0 only
  verbose::Int

end

#TODO: see if the static parameters are still needed
function NewtonData(mesh, sbp,  
        eqn::AbstractSolutionData{Tsol, Tres}, opts,
        ls::LinearSolver) where {Tsol, Tres}

  myrank = mesh.myrank
  commsize = mesh.commsize
  itr = 0
  verbose = opts["newton_verbosity"]

  res_norm_i = 0.0
  res_norm_i_1 = 0.0
  step_norm_i = 0.0
  step_norm_i_1 = 0.0
  res_norm_rel = opts["res_reltol0"]
  set_rel_norm = res_norm_rel < 1
  step_fac = 1.0

  res_reltol = opts["res_reltol"]
  res_abstol = opts["res_abstol"]
  step_tol = opts["step_tol"]
  itermax = opts["itermax"]

  use_inexact_nk = opts["use_inexact_nk"]
  krylov_gamma = opts["krylov_gamma"]

  recalc_policy = getRecalculationPolicy(opts, "newton")

  # temporary vectors
  res_0 = zeros(PetscScalar, mesh.numDof)  # function evaluated at u0
  delta_q_vec = zeros(PetscScalar, mesh.numDof)  # newton update

  # convergence.dat
  if verbose >= 5
    if myrank == 0
      fconv = BufferedIO("convergence.dat", "a+")
    else
      fconv = DevNull
    end
  else
    fconv = DevNull
  end


  return NewtonData{Tsol, Tres, typeof(ls)}(myrank, commsize, itr,
                    res_norm_i, res_norm_i_1, step_norm_i, step_norm_i_1,
                    res_norm_rel, set_rel_norm, step_fac,
                    res_reltol, res_abstol, step_tol, itermax,
                    use_inexact_nk, krylov_gamma, recalc_policy, ls, res_0,
                    delta_q_vec, fconv, verbose)
end

@doc """
### NonlinearSolvers.setupNewton
  Performs setup work for [`newtonInner`](@ref), including creating a 
  [`NewtonData`](@ref) object.

  This function also resets the implicit Euler globalization.

  alloc_rhs: keyword arg to allocate a new object or not for rhs_vec
                true (default) allocates a new vector
                false will use eqn.res_vec

  rhs_func: only used for Petsc in matrix-free mode to do Jac-vec products
            should be the rhs_func passed into [`newtonInner`](@ref)
  ctx_residual: ctx_residual passed into [`newtonInner`](@ref)

  Allocates Jac & RHS

  See [`cleanupNewton`](@ref) to the cleanup function

"""->
function setupNewton(mesh, pmesh, sbp,
         eqn::AbstractSolutionData{Tsol, Tres}, opts,
         ls::LinearSolver; alloc_rhs=true) where {Tsol, Tres}

  newton_data = NewtonData(mesh, sbp, eqn, opts, ls)

  clearEulerConstants(ls)
  # For simple cases, especially for Newton's method as a steady solver,
  #   having rhs_vec and eqn.res_vec pointing to the same memory
  #   saves us from having to copy back and forth
  if alloc_rhs 
    rhs_vec = zeros(Tsol, size(eqn.res_vec))
  else
    rhs_vec = eqn.res_vec
  end

  return newton_data, rhs_vec

end   # end of setupNewton

"""
  Reinitialized the NewtonData object for a new solve.

  Note that this does not reset the linear solver, which might be a problem
  if inexact newton-krylov was used for the previous solve

  Uses `opts["newton_scale_euler"]` to determine how the `opts["euler_tau"]`
  value should be interpreted
"""
function reinitNewtonData(newton_data::NewtonData, mesh, sbp, eqn, opts)

  clearEulerConstants(newton_data.ls)
  newton_data.itr = 0
  newton_data.res_norm_i = 0
  newton_data.res_norm_i_1 = 0
  newton_data.step_norm_i = 0
  newton_data.step_norm_i_1 = 0
  newton_data.step_fac = 1.0
  resetRecalculationPolicy(newton_data.recalc_policy)

  # if using globalization, reset it
  if opts["newton_globalize_euler"]
    lo = getInnerLO(newton_data.ls.lo, NewtonLO)

    #TODO: it would be slightly better to update tau_vec inplace
    reinitImplicitEuler(mesh, opts, lo.idata)

    if !(typeof(newton_data.ls.pc) <: PCNone)
      # no need to do anything for PCNone
      pc = getInnerPC(newton_data.ls.pc, NewtonPC)
      reinitImplicitEuler(mesh, opts, lo.idata)
    end


    if opts["newton_scale_euler"]
      # in this mode, we say that the euler wants the pseudo time step to
      # be opts["euler_tau"] when the residual norm = 1 (therefore the residual
      # norm of the initial condition causes the time step to get scaled
      # up or down depending on the residual).
      recordEulerResidual(newton_data.ls, 1)
      # shift the residuals so they are in the i-1 position
      # This is caused by a bad interface to ImplicitEulerData:
      # recordEulerResidual should do this shifting, not useEulerConstants
      useEulerConstants(lo)
      if !(typeof(newton_data.ls.pc) <: PCNone)
        useEulerConstants(Pc)
      end
    end
  end

  return nothing
end

"""
  Cleans up after running Newton's method.

  **Inputs**

   * newton_data: the NewtonData object

"""
function free(newton_data::NewtonData)

  free(newton_data.ls)
  close(newton_data.fconv)

  return nothing
end

"""
  Records the most recent nonlinear residual norm in the NewtonData object.
  Also updates the implicit Euler globalization

  **Inputs**

   * newton_data: the NewtonData
   * res_norm: the residual norm
"""
function recordResNorm(newton_data::NewtonData, res_norm::Number)

  newton_data.res_norm_i_1 = newton_data.res_norm_i
  newton_data.res_norm_i = res_norm
  
  # update implicit Euler globalization
  recordEulerResidual(newton_data.ls, res_norm)

  return nothing
end

"""
  Records norm of the most recent newton step (ie. the norm of delta q)
  in the NewtonData object

  **Inputs**

   * newton_data: the NewtonData object
   * step_norm: the norm of the step
"""
function recordStepNorm(newton_data::NewtonData, step_norm::Number)

  newton_data.step_norm_i_1 = newton_data.step_norm_i
  newton_data.step_norm_i = step_norm

  return nothing
end

#------------------------------------------------------------------------------
# getter for PC and LO

"""
  Returns the Newton precondtioner and linear operator specified by the options
  dictionary

  **Inputs**

   * mesh
   * sbp
   * eqn
   * opts
   * rhs_func: rhs_func required by [`newtonInner`](@ref)
"""
function getNewtonPCandLO(mesh, sbp, eqn, opts,
                          jactype::Integer=opts["jac_type"])

  # get PC
  if jactype <= 2
    pc = PCNone(mesh, sbp, eqn, opts)
  else
    if opts["use_volume_preconditioner"]
      pc = NewtonBDiagPC(mesh, sbp, eqn, opts)
    else
      pc = NewtonMatPC(mesh, sbp, eqn, opts)
    end
  end 

  if jactype == 1
    lo = NewtonDenseLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 2
    lo = NewtonSparseDirectLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 3
    lo = NewtonPetscMatLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 4
    lo = NewtonPetscMatFreeLO(pc, mesh, sbp, eqn, opts)
  end

  return pc, lo
end

import PDESolver.createLinearSolver

function createLinearSolver(mesh::AbstractMesh, sbp::AbstractOperator,
                            eqn::AbstractSolutionData, opts,
                            jac_type::Integer=opts["jac_type"])

  # general linear solvers should not have globilization
  val_orig = opts["setup_globalize_euler"]
  opts["setup_globalize_euler"] = false
  pc, lo = getNewtonPCandLO(mesh, sbp, eqn, opts, jac_type)
  ls = StandardLinearSolver(pc, lo, eqn.comm, opts)
  opts["setup_globalize_euler"] = val_orig
  
  return ls
end


#------------------------------------------------------------------------------
# preconditioner

abstract type NewtonMatFreePC <: AbstractPetscMatFreePC end


"""
  This function initializes the data needed to do Psudo-Transient Continuation 
  globalization (aka. Implicit Euler) of Newton's method, using a spatially 
  varying pseudo-timestep.

  Updates the jacobian with a diagonal term, as though the jac was the 
  jacobian of this function:
  (u - u_i_1)/delta_t + f(u)
  where f is the original residual and u_i_1 is the previous step solution


  This globalization is activated using the option `newton_globalize_euler`.
  The initial value of the scaling factor tau is specified by the option 
  `euler_tau`.


"""
mutable struct ImplicitEulerData
    use_implicit_euler::Bool  # whether or not use use implicit Euler
    res_norm_i::Float64  # current step residual norm
    res_norm_i_1::Float64  # previous step residual norm
    # Pseudo-transient continuation Euler
    tau_l::Float64  # current pseudo-timestep
    tau_vec::Array{Float64, 1}  # array of element-local time steps
end

"""
  Constructor for the case where implicit Euler will be used  

  **Inputs**

   * mesh
   * opts
   * tau_l: the reference timestep
"""
function ImplicitEulerData(mesh::AbstractMesh, opts, tau_l::Number)

  use_implicit_euler = true
  res_norm_i = 0.0
  res_norm_i_1 = 0.0

  tau_vec = zeros(mesh.numDof)
  calcTauVec(mesh, opts, tau_l, tau_vec)

  return ImplicitEulerData(use_implicit_euler, res_norm_i, res_norm_i_1,
                           tau_l, tau_vec)
end

"""
  Constructor for the case where implicit Euler will not be used.
"""
function ImplicitEulerData()

  use_implicit_euler = false
  res_norm_i = 0.0
  res_norm_i_1 = 0.0
  tau_l = 0.0
  tau_vec = Array{Float64}(0)

  return ImplicitEulerData(use_implicit_euler, res_norm_i, res_norm_i_1,
                           tau_l, tau_vec)
end


"""
  Constructor from options dictionary.  Uses opts["setup_globalize_euler"]
  and opts["euler_tau"] to configure the returned object

  **Inputs**

   * mesh
   * opts
"""
function ImplicitEulerData(mesh::AbstractMesh, opts)

  if opts["setup_globalize_euler"]
    obj = ImplicitEulerData(mesh, opts, opts["euler_tau"])
  else
    obj = ImplicitEulerData()
  end

  return obj
end



"""
  Matrix-based Petsc preconditioner for Newton's method
"""
mutable struct NewtonMatPC <: AbstractPetscMatPC
  pc_inner::PetscMatPC
  idata::ImplicitEulerData
end

"""
  Outer constructor for [`NewtonMatPC`](@ref)
"""
function NewtonMatPC(mesh::AbstractMesh, sbp::AbstractOperator,
                    eqn::AbstractSolutionData, opts::Dict)


  pc_inner = PetscMatPC(mesh, sbp, eqn, opts)
  idata = ImplicitEulerData(mesh, opts)

  return NewtonMatPC(pc_inner, idata)
end

function calcPC(pc::NewtonMatPC, mesh::AbstractMesh, sbp::AbstractOperator,
                eqn::AbstractSolutionData, opts::Dict, ctx_residual, t)

  calcPC(pc.pc_inner, mesh, sbp, eqn, opts, ctx_residual, t)
  physicsJac(mesh, sbp, eqn, opts, getBasePC(pc).A, ctx_residual, t)

  if opts["newton_globalize_euler"]
    # TODO: updating the Euler parameter here is potentially wrong if we
    #       are not updating the Jacobian at every newton step
    updateEuler(pc)
    applyEuler(mesh, sbp, eqn, opts, pc)
  end


  return nothing
end

#------------------------------------------------------------------------------
# linear operator

# because Julia lack multiple inheritance, we have to define 4 of these
# make sure they share the same fields whenever needed

"""
  Dense linear operator for Newton's method.
    
  Subtype of [`AbstractDenseLO`](@ref)
"""
mutable struct NewtonDenseLO <: AbstractDenseLO
  lo_inner::DenseLO
  idata::ImplicitEulerData
  myrank::Int
  commsize::Int
end

"""
  Outer constructor for [`NewtonDenseLO`](@ref)
"""
function NewtonDenseLO(pc::PCNone, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = DenseLO(pc, mesh, sbp, eqn, opts)
  idata = ImplicitEulerData(mesh, opts)

  return NewtonDenseLO(lo_inner, idata, mesh.myrank, mesh.commsize)
end

"""
  Sparse direct linear operator for Newton's method.  Subtype of
  [`AbstractSparseDirectLO`](@ref)
"""
mutable struct NewtonSparseDirectLO <: AbstractSparseDirectLO
  lo_inner::SparseDirectLO
  idata::ImplicitEulerData
  myrank::Int
  commsize::Int
end

"""
  Outer constructor for [`NewtonSparseDirectLO`](@ref)
"""
function NewtonSparseDirectLO(pc::PCNone, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = SparseDirectLO(pc, mesh, sbp, eqn, opts)
  idata = ImplicitEulerData(mesh, opts)

  return NewtonSparseDirectLO(lo_inner, idata, mesh.myrank, mesh.commsize)
end

"""
  Petsc matrix based linear operator for Newton's method.

  Subtype of [`AbstractPetscMatLO`](@ref)
"""
mutable struct NewtonPetscMatLO <: AbstractPetscMatLO
  lo_inner::PetscMatLO
  idata::ImplicitEulerData
  myrank::Int
  commsize::Int
end

"""
  Outer constructor for [`NewtonPetscMatLO`](@ref)
"""
function NewtonPetscMatLO(pc::AbstractPetscPC, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = PetscMatLO(pc, mesh, sbp, eqn, opts)
  idata = ImplicitEulerData(mesh, opts)

  return NewtonPetscMatLO(lo_inner, idata, mesh.myrank, mesh.commsize)
end

"""
  Petsc matrix-free linear operator for Newton's method.

  Subtype of [`AbstractPetscMatFreeLO`](@ref)
"""
mutable struct NewtonPetscMatFreeLO <: AbstractPetscMatFreeLO
  lo_inner::PetscMatFreeLO
  idata::ImplicitEulerData
  myrank::Int
  commsize::Int
end

"""
  Newton mat-free linear operator constructor

  **Inputs**

   * pc
   * mesh
   * sbp
   * eqn
   * opts
   * rhs_func: rhs_func from [`newtonInner`](@ref)
"""
function NewtonPetscMatFreeLO(pc::AbstractPetscPC, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = PetscMatFreeLO(pc, mesh, sbp, eqn, opts)
  idata = ImplicitEulerData(mesh, opts)

  return NewtonPetscMatFreeLO(lo_inner, idata, mesh.myrank, mesh.commsize)
end

"""
  All Newton linear operators
"""
const NewtonLO = Union{NewtonDenseLO, NewtonSparseDirectLO, NewtonPetscMatLO, NewtonPetscMatFreeLO}

"""
  Newton matrix-explicit linear operators
"""
const NewtonMatLO = Union{NewtonDenseLO, NewtonSparseDirectLO, NewtonPetscMatLO}

"""
  Any PC or LO that has a matrix in the field `A`
"""
const NewtonHasMat = Union{NewtonMatPC, NewtonDenseLO, NewtonSparseDirectLO, NewtonPetscMatLO}

"""
  Any Newton PC or LO.
"""
const NewtonLinearObject = Union{NewtonDenseLO, NewtonSparseDirectLO, NewtonPetscMatLO, NewtonPetscMatFreeLO, NewtonMatPC}

"""
  Any Newton PC
"""
const NewtonPC = Union{NewtonMatPC, NewtonMatFreePC}

function calcLinearOperator(lo::NewtonMatLO, mesh::AbstractMesh,
                            sbp::AbstractOperator, eqn::AbstractSolutionData,
                            opts::Dict, ctx_residual, t)

   
  calcLinearOperator(lo.lo_inner, mesh, sbp, eqn, opts, ctx_residual, t)

  lo2 = getBaseLO(lo)
  physicsJac(mesh, sbp, eqn, opts, lo2.A, ctx_residual, t)

  if opts["newton_globalize_euler"]
    # TODO: updating the Euler parameter here is potentially wrong if we
    #       are not updating the Jacobian at every newton step
    updateEuler(lo)
    applyEuler(mesh, sbp, eqn, opts, lo)
  end

  return nothing
end

function calcLinearOperator(lo::NewtonPetscMatFreeLO, mesh::AbstractMesh,
                            sbp::AbstractOperator, eqn::AbstractSolutionData,
                            opts::Dict, ctx_residual, t)

  if opts["newton_globalize_euler"]
    updateEuler(lo)
  end

  setLOCtx(lo, mesh, sbp, eqn, opts, ctx_residual, t)

  return nothing
end


function applyLinearOperator(lo::NewtonPetscMatFreeLO, mesh::AbstractMesh,
                       sbp::AbstractOperator, eqn::AbstractSolutionData{Tsol},
                       opts::Dict, ctx_residual, t, x::AbstractVector, 
                       b::AbstractVector) where Tsol

  @assert !(Tsol <: AbstractFloat)  # complex step only!

  epsilon =  opts["epsilon"]::Float64
  pert = Tsol(0, epsilon)

  # apply perturbation
  for i=1:mesh.numDof
    eqn.q_vec[i] += pert*x[i]
  end

  physicsRhs(mesh, sbp, eqn, opts, eqn.res_vec, ctx_residual, t)
  
  # calculate derivatives, store into b
  calcJacCol(b, eqn.res_vec, epsilon)

  if opts["newton_globalize_euler"]
    applyEuler(mesh, sbp, eqn, opts, x, lo, b)
  end

  # undo perturbation
  for i=1:mesh.numDof
    eqn.q_vec[i] -= pert*x[i]
  end

  return nothing
end

function applyLinearOperatorTranspose(lo::NewtonPetscMatFreeLO, 
                             mesh::AbstractMesh,
                             sbp::AbstractOperator, eqn::AbstractSolutionData{Tsol},
                             opts::Dict, ctx_residual, t, x::AbstractVector, 
                             b::AbstractVector) where Tsol

  error("applyLinearOperatorTranspose() not supported by NewtonPetscMatFreeLO")

end
