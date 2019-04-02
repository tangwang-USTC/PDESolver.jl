# Dissipation based homotopy predictor-corrector globalization for solving
# steady problems using Newton's method
# based on Brown and Zingg, "A monolithic Homotopy Continuation Algorithm 
# with applications to Computational Fluid Dynamics"
# Journal of Computational Physics 321, (2016), 55-75
# specifically, Algorithm 2
#=
mutable struct HomotopyData{Tsol, Tjac}

  time::Float64
  lambda::Float64 # homotopy parameter
  myrank::Int

  # parameters
  lambda_min::Float64
  lambda_cutoff::Float64
  itermax::Int
  res_reltol::Float64
  res_abstol::Float64
  krylov_reltol0::Float64
  orig_newton_globalize_euler::Bool  # value to reset opts afterwards
  use_pc::Bool  # true if PC is not PCNone

  # working variables
  iter::Int  # current major iteration
  homotopy_tol::Float64
  delta_max::Float64  # step size limit
  psi_max::Float64  # max angle between tangent vectors (radians)
  psi::Float64  # current angle between tangent vectors (radians)
  tan_norm::Float64  # current tangent vector norm
  tan_norm_1::Float64  # previous tangent vector norm
  res_norm::Float64   # current norm of physics (not homotopy) residual
  res_norm_0::Float64  # norm of physics residual of initial guess
  h::Float64  # step size

  # arrays
  q_vec0::Array{Tsol, 1}
  delta_q::Array{Tsol, 1}
  tan_vec::Array{Tjac, 1}
  tan_vec_1::Array{Tjac, 1}
  dHdLambda_real::Array{Tjac, 1}

  # composite objects
  recalc_polocy::AbstractRecalculation
  ls::LinearSolver
  newton_data::NewtonData
  fconv  #TODO: type


  function HomotopyData{T}(mesh, sbp, eqn, opts) where {T}
    time = eqn.params.time
    lambda = 1.0  # homotopy parameter
    myrank = mesh.myrank

    # some parameters
    lambda_min = 0.0
    lambda_cutoff = 0.000  # was 0.005
    itermax = opts["itermax"]::Int
    res_reltol=opts["res_reltol"]::Float64
    res_abstol=opts["res_abstol"]::Float64
    krylov_reltol0 = opts["krylov_reltol"]::Float64
    orig_newton_globalize_euler = opts["newton_globalize_euler"]  # reset value


    # counters/loop variables
    #TODO: make a type to store these
    iter = 1
    homotopy_tol = 1e-2
    delta_max = 1.0  # step size limit, set to 1 initially,
    psi_max = 10*pi/180  # angle between tangent limiter
    psi = 0.0  # angle between tangent vectors
    tan_norm = 0.0  # current tangent vector norm
    tan_norm_1 = 0.0  # previous tangent vector norm
    res_norm = 0.0  # norm of residual (not homotopy)
    res_norm_0 = 0.0  # residual norm of initial guess
    h = 0.05  # step size
    lambda -= h  # the jacobian is ill-conditioned at lambda=1, so skip it
    recalc_policy = getRecalculationPolicy(opts, "homotopy")
    # log file
    @mpi_master fconv = BufferedIO("convergence.dat", "a+")

    # needed arrays
    q_vec0 = zeros(eqn.q_vec)
    delta_q = zeros(eqn.q_vec)
    tan_vec = zeros(Tjac, length(eqn.q_vec))  # tangent vector
    tan_vec_1 = zeros(tan_vec)  # previous tangent vector
    dHdLambda_real = zeros(Tjac, length(eqn.q_vec))  

    # stuff for newtonInner
    # because the homotopy function is a pseudo-physics, we can reuse the
    # Newton PC and LO stuff, supplying homotopyPhysics in ctx_residual
    rhs_func = physicsRhs
    pc, lo = getHomotopyPCandLO(mesh, sbp, eqn, opts)
    use_pc = !(typeof(pc) <: PCNone)
    if use_pc
      pc.lambda = lambda
    end
    lo.lambda = lambda
    ls = StandardLinearSolver(pc, lo, eqn.comm, opts)


    # configure NewtonData
    newton_data, rhs_vec = setupNewton(mesh, pmesh, sbp, eqn, opts, ls)
    newton_data.itermax = 30

    obj = new()
    setLambda(obj, lambda)
   
    return obj
  end
end

function setLambda(data::HomotopyData, lambda::Number)

  if !(typeof(pc) <: PCNone)
    pc.lambda = lambda
  end
  lo.lambda = lambda
  data.lambda = lambda

  return nothing
end
=#

"""
  This function solves steady problems using a dissipation-based
  predictor-correcor homotopy globalization for Newtons method.

  Inputs:
    physics_func: the function to solve, ie. func(q) = 0  mathematically.
                  func must have the signature func(mesh, sbp, eqn, opts)

    g_func: the function that evalutes G(q), the dissipation.
            If explicit jacobian calculation is used, then
            [`evalHomotopyJacobian`](@ref) must evaluate the jacobian of this 
            function wrt. q
    sbp: an SBP operator
    eqn: a AbstractSolutionData.  On entry, eqn.q_vec must be the
         initial condition.  On exit, eqn.q_vec will be the solution to
         func(q) = 0
    opts: options dictionary

  Keyword Arguments:
    pmesh: mesh used for calculating preconditioner


  This function uses Newtons method internally, and supports all the
  different jacobian types and jacobian calculation methods that 
  Newton does.

  On entry, eqn.q_vec should contain the initial guess for q.  On exit
  it will contain the solution for func(q) = 0.

  This function is reentrant.

  **Options Keys**

   * calc_jac_explicit
   * itermax
   * res_reltol
   * res_abstol
   * krylov_reltol
   * homotopy_globalize_euler: activate implicit euler globalization when
                               lambda = 0
   * homotopy_tighten_early: tighten the newton solve tolerance and active
                             implicit Euler globalization when 
                             `lambda < lambda_cutoff`, typically 0.005.
                             This may slow down the Newton solve significantly

  This function supports jacobian/preconditioner freezing using the
  prefix "newton".  Note that this recalcuation policy only affects
  this function, and not newtonInner, and defaults to never recalculating
  (and letting newtonInner update the jacobian/preconditioner according to
  its recalculationPolicy).
"""
function predictorCorrectorHomotopy(physics_func::Function,
                  g_func::Function,
                  mesh::AbstractMesh{Tmsh}, 
                  sbp::AbstractOperator, 
                  eqn::AbstractSolutionData{Tsol, Tres}, 
                  opts; pmesh=mesh) where {Tsol, Tres, Tmsh}

#  global evalPhysicsResidual = physics_func
#  global evalHomotopyResidual = g_func
  #----------------------------------------------------------------------------
  # define the homotopy function H and dH/dLambda
  # defines these as nested functions so predictorCorrectorHomotopy is
  # re-entrant
  res_homotopy = zeros(eqn.res)  # used by homotopyPhysics
  """
    This function makes it appear as though the combined homotopy function H
    is a physics.  This works because an elementwise combinations of physics
    is still a physics.

    physics_func is used for the physcs function R and g_func is used for 
    the homotopy function G.  The combined homotopy function is

      (1 - lambda)R(q) + lambda*G(q)

    Inputs: 
      mesh
      sbp
      eqn
      opts
      t
  """
  function homotopyPhysics(mesh, sbp, eqn, opts, t)

    # this function is only for use with Newton's method, where parallel
    # communication is started outside the physics
    # q_vec -> q

#    res_homotopy = zeros(eqn.res)
    fill!(eqn.res, 0.0)
    fill!(res_homotopy, 0.0)


    # calculate physics residual
    # call this function before g_func, to receive parallel communication
    physics_func(mesh, sbp, eqn, opts, t)

    # calculate homotopy function
    g_func(mesh, sbp, eqn, opts, res_homotopy)

    # combine (use lambda from outer function)
    lambda_c = 1 - lambda # complement of lambda
    for i=1:length(eqn.res)
      eqn.res[i] =  lambda_c*eqn.res[i] + lambda*res_homotopy[i]
    end

  #  println("homotopy physics exiting with residual norm ", norm(vec(eqn.res)))
    return nothing
  end


  #----------------------------------------------------------------------------
  # setup

  Tjac = real(Tres)

 

  time = eqn.params.time
  lambda = 1.0  # homotopy parameter
  myrank = mesh.myrank

  # some parameters
  lambda_min = 0.0
  lambda_cutoff = 0.005  # was 0.005
  itermax = opts["itermax"]::Int
  res_reltol=opts["res_reltol"]::Float64
  res_abstol=opts["res_abstol"]::Float64
  krylov_reltol0 = opts["krylov_reltol"]::Float64
  orig_newton_globalize_euler = opts["newton_globalize_euler"]  # reset value
  tighten_early = opts["homotopy_tighten_early"]::Bool


  # counters/loop variables
  #TODO: make a type to store these
  iter = 1
  homotopy_tol = 1e-2
  delta_max = 0.5  # step size limit, set to 1 initially,
  psi_max = 10*pi/180  # angle between tangent limiter
  psi = 0.0  # angle between tangent vectors
  tan_norm = 0.0  # current tangent vector norm
  tan_norm_1 = 0.0  # previous tangent vector norm
  res_norm = 0.0  # norm of residual (not homotopy)
  res_norm_0 = 0.0  # residual norm of initial guess
  h = 0.05  # step size
  lambda -= h  # the jacobian is ill-conditioned at lambda=1, so skip it
  recalc_policy = getRecalculationPolicy(opts, "homotopy")
  # log file
  @mpi_master fconv = BufferedIO("convergence.dat", "a+")

  # needed arrays
  q_vec0 = zeros(eqn.q_vec)
  delta_q = zeros(eqn.q_vec)
  tan_vec = zeros(Tjac, length(eqn.q_vec))  # tangent vector
  tan_vec_1 = zeros(tan_vec)  # previous tangent vector
  dHdLambda_real = zeros(Tjac, length(eqn.q_vec))  


  # stuff for newtonInner
  # because the homotopy function is a pseudo-physics, we can reuse the
  # Newton PC and LO stuff, supplying homotopyPhysics in ctx_residual
  rhs_func = physicsRhs
  ctx_residual = (homotopyPhysics,)
  pc, lo = getHomotopyPCandLO(mesh, sbp, eqn, opts)
  if !(typeof(pc) <: PCNone)
    pc.lambda = lambda
  end
  lo.lambda = lambda
  ls = StandardLinearSolver(pc, lo, eqn.comm, opts)


  # configure NewtonData
  newton_data, rhs_vec = setupNewton(mesh, pmesh, sbp, eqn, opts, ls)
  newton_data.itermax = 30
 
  # calculate physics residual
  res_norm = real(physicsRhs(mesh, sbp, eqn, opts, eqn.res_vec, (physics_func,)))
  res_norm_0 = res_norm

  # print to log file
  @mpi_master println(fconv, 0, " ", res_norm, " ", 0.0)
  @mpi_master flush(fconv)

  eqn.majorIterationCallback(0, mesh, sbp, eqn, opts, BSTDOUT)

  #----------------------------------------------------------------------------
  # main loop
  while res_norm > res_norm_0*res_reltol && res_norm > res_abstol && iter < itermax  # predictor loop

    @mpi_master begin
      println(BSTDOUT, "\npredictor iteration ", iter, ", lambda = ", lambda)
      println(BSTDOUT, "res_norm = ", res_norm)
      println(BSTDOUT, "res_norm/res_norm_0 = ", res_norm/res_norm_0)
      println(BSTDOUT, "h = ", h)
    end

    # calculate homotopy residual
    homotopy_norm = physicsRhs(mesh, sbp, eqn, opts, eqn.res_vec, (homotopyPhysics,))

    homotopy_norm0 = homotopy_norm
    copy!(q_vec0, eqn.q_vec)  # save initial q to calculate delta_q later

    # if we have finished traversing the homotopy path, solve the 
    # homotopy problem (= the physics problem because lambda is zero)
    # tightly
    changed_tols = false
    if abs(lambda - lambda_min) <= eps()
      @mpi_master println(BSTDOUT, "tightening homotopy tolerance at lambda = 0")
      changed_tols = true
      homotopy_tol = res_reltol
      reltol = res_reltol*1e-3  # smaller than newton tolerance
      abstol = res_abstol*1e-3  # smaller than newton tolerance
      setTolerances(newton_data.ls, reltol, abstol, -1, -1)
      krylov_reltol0 = reltol  # do this so the call to setTolerances below
                               # does not reset the tolerance
      # enable globalization if required
      opts["newton_globalize_euler"] = opts["homotopy_globalize_euler"]
      newton_data.itermax = opts["itermax"]
    elseif lambda < lambda_cutoff && tighten_early

      # turn on implicit euler and tighten tolerances
      # Thjs helps for shock problems when the algorithm takes very small steps
      # in lambda near the end, because lambda may become too small to prevent
      # Newton from diverging
      @mpi_master println(BSTDOUT, "tightening homotopy tolerance at lambda cutoff")
      changed_tols = true
      homotopy_tol = 1e-4

      reltol = res_reltol*1e-3  # smaller than newton tolerance
      abstol = res_abstol*1e-3  # smaller than newton tolerance
      setTolerances(newton_data.ls, reltol, abstol, -1, -1)
      krylov_reltol0 = reltol  # do this so the call to setTolerances below
                               # does not reset the tolerance
      # enable globalization if required
      opts["newton_globalize_euler"] = opts["homotopy_globalize_euler"]
      newton_data.itermax = opts["itermax"]
    end

    if changed_tols
      @mpi_master begin
        println(BSTDOUT, "setting homotopy tolerance to ", homotopy_tol)
        println(BSTDOUT, "ksp reltol = ", reltol)
        println(BSTDOUT, "ksp abstol = ", abstol)
      end
    end

    # calculate the PC and LO if needed
    doRecalculation(recalc_policy, iter, newton_data.ls, mesh, sbp, eqn, opts, ctx_residual, 0.0)

    # do corrector steps
    newton_data.res_reltol = homotopy_tol
    # reset tolerances in case newton is doing inexact-NK and thus has changed
    # the tolerances
    setTolerances(newton_data.ls, krylov_reltol0, -1, -1, -1)
    newtonInner(newton_data, mesh, sbp, eqn, opts, rhs_func, ls, 
                rhs_vec, ctx_residual)

    # compute delta_q
    for i=1:length(eqn.q)
      delta_q[i] = eqn.q_vec[i] - q_vec0[i]
    end
    delta = calcNorm(eqn, delta_q)
    println("L2 norm delta = ", delta)
    #delta = calcEuclidianNorm(mesh.comm, delta_q)
    #println("Euclidian norm delta = ", delta)
    #if iter == 2
    #  delta_max = delta
    #  println("delta max = ", delta_max)
    #end

    # predictor step calculation
    if abs(lambda - lambda_min) > eps()
      # calculate dHdLambda at new q value
      calcdHdLambda(mesh, sbp, eqn, opts, lambda, physics_func, g_func, rhs_vec)
      for i=1:length(rhs_vec)
        dHdLambda_real[i] = real(rhs_vec[i])
      end

      # calculate tangent vector dH/dq * t = dH/dLambda
      @mpi_master println(BSTDOUT, "solving for tangent vector")
#      calcPCandLO(ls, mesh, sbp, eqn, opts, ctx_residual, 0.0)

      tsolve = @elapsed linearSolve(ls, dHdLambda_real, tan_vec)
      eqn.params.time.t_solve += tsolve

      # normalize tangent vector
      # t = [z, -1], where z is a delta_q sized vector, so the norm is
      # sqrt(calcNorm(z)^2 + (1)^2).  In the code tan_vec = z, so what is
      # really happenening is the z component of t is being normalize.  The
      # -1 component will be handled below
      tan_norm = calcNorm(eqn, tan_vec)
      tan_norm = sqrt(tan_norm*tan_norm + 1)
      scale!(tan_vec, 1/tan_norm)

      psi = psi_max
      if iter > 1
        #TODO: make psi real, not complex
        # compute phi = acos(tangent_i_1 dot tangent_i)
        # however, use the L2 norm for the z part of the tangent vector
        tan_term = calcL2InnerProduct(eqn, tan_vec_1, tan_vec)
#        time.t_allreduce += @elapsed tan_term = MPI.Allreduce(tan_term, MPI.SUM, eqn.comm)
        # now add the normalized -1 components of t_i and t_i_1 to complete
        # the inner product between t_i and t_i_1 = inner_product(z_i, z_i_1) 
        # + -1*-1/(||z_i||*||z_i_1||)
        tan_norm_term = (1/tan_norm)*(1/tan_norm_1)
        arg = tan_term + tan_norm_term
        arg = clamp(arg, -1.0, 1.0)
        psi = acos( arg )
      end

      # save the tangent vector
      copy!(tan_vec_1, tan_vec)
      tan_norm_1 = tan_norm

      # calculate step size
      fac = max(real(psi/psi_max), sqrt(delta/delta_max))
      #fac = real(psi/psi_max)
      println("psi/psi_max = ", psi/psi_max)
      println("delta/delta_max = ", delta/delta_max)
      println("fac = ", fac)
      h /= fac
      println("new h = ", h)

      # take predictor step
      scale!(tan_vec, h)
      for i=1:length(eqn.q_vec)
        eqn.q_vec[i] += tan_vec[i]
      end

#      prev_lambda = lambda
#      lambda_final_step = 0.05  # maximum size of final step in lambda
      lambda = max(lambda_min, lambda - h)
#      if lambda < lambda_cutoff
#        println(BSTDOUT, "Reached lambda cutoff, forcing lambda to 0")

        # if this is the final step to lambda = 0, and the step is too large,
        # force an intermediate step
        # use 2 * lambda_final_step as heuristic for "too big"
 #       if prev_lambda - lambda_min > 2*lambda_final_step
 #         println(BSTDOUT, "limiting size of final step")
 #         lambda = lambda_min + lambda_final_step
 #       else  # otherwise set lambda to zero
#          lambda = 0.0
#        end
#      end
      if !(typeof(pc) <: PCNone)
        pc.lambda = lambda
      end
      lo.lambda = lambda
    end  # end if lambda too large

    # calculate physics residual at new state q
    res_norm = real(physicsRhs(mesh, sbp, eqn, opts, eqn.res_vec, (physics_func,),))

    # print to log file
    @mpi_master println(fconv, iter, " ", res_norm, " ", h )
    @mpi_master flush(fconv)

    eqn.majorIterationCallback(iter, mesh, sbp, eqn, opts, BSTDOUT)

    iter += 1
  end  # end while loop

  print(BSTDOUT, "\n")

  # inform user of final status
  @mpi_master if iter >= itermax
    println(BSTDERR, "Warning: predictor-corrector did not converge in $iter iterations")
  
  elseif res_norm <= res_abstol
    println(BSTDOUT, "predictor-corrector converged with absolute residual norm $res_norm")
  elseif res_norm/res_norm_0 <= res_reltol
    tmp = res_norm/res_norm_0
    println(BSTDOUT, "predictor-corrector converged with relative residual norm $tmp")
  end

  # reset options dictionary
  opts["newton_globalize_euler"] = orig_newton_globalize_euler

  free(newton_data)
#  cleanupNewton(newton_data, mesh, mesh, sbp, eqn, opts)

  flush(BSTDOUT)
  flush(BSTDERR)

  return nothing
end



"""
  This function calculates dH/dLambda, where H is the homotopy function
  calculated by homotopyPhysics.  The differentiation is done analytically

  Inputs:
    mesh
    sbp
    eqn: eqn.res and eqn.res_vec are overwritten
    opts
    lambda: homotopy parameter lambda
    physics_func: function that evalutes the physics residual
    g_func: function that evalutes g(q)

  Inputs/Outputs
    res_vec: vector to store dH/dLambda in

  Aliasing restrictions: res_vec and eqn.res_vec may not alias
"""
function calcdHdLambda(mesh, sbp, eqn, opts, lambda, physics_func, g_func, res_vec)

  # it appears this only gets called after parallel communication is done
  # so no need to start communication here

#  lambda = eqn.params.homotopy_lambda
  res_homotopy = zeros(eqn.res)


  # calculate physics residual
  physics_func(mesh, sbp, eqn, opts)
  array3DTo1D(mesh, sbp, eqn, opts, eqn.res, eqn.res_vec)


  # calculate homotopy function
  g_func(mesh, sbp, eqn, opts, res_homotopy)
  array3DTo1D(mesh, sbp, eqn, opts, res_homotopy, res_vec)

  # combine them
  for i=1:length(res_vec)
    res_vec[i] -= eqn.res_vec[i]
  end

  return nothing
end


function getHomotopyPCandLO(mesh, sbp, eqn, opts)

  # get PC
  if opts["jac_type"] <= 2
    pc = PCNone(mesh, sbp, eqn, opts)
  else
    pc = HomotopyMatPC(mesh, sbp, eqn, opts)
  end 

  jactype = opts["jac_type"]
  if jactype == 1
    lo = HomotopyDenseLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 2
    lo = HomotopySparseDirectLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 3
    lo = HomotopyPetscMatLO(pc, mesh, sbp, eqn, opts)
  elseif jactype == 4
    lo = HomotopyPetscMatFreeLO(pc, mesh, sbp, eqn, opts)
  end

  return pc, lo
end




# Define PC and LO objects
#------------------------------------------------------------------------------
# PC:

mutable struct HomotopyMatPC <: AbstractPetscMatPC
  pc_inner::NewtonMatPC
  lambda::Float64  # homotopy parameter
end

function HomotopyMatPC(mesh::AbstractMesh, sbp::AbstractOperator,
                    eqn::AbstractSolutionData, opts::Dict)


  pc_inner = NewtonMatPC(mesh, sbp, eqn, opts)
  lambda = 1.0

  return HomotopyMatPC(pc_inner, lambda)
end

function calcPC(pc::HomotopyMatPC, mesh::AbstractMesh, sbp::AbstractOperator,
                eqn::AbstractSolutionData, opts::Dict, ctx_residual, t)

  # compute the Jacobian of the Newton PC
  calcPC(pc.pc_inner, mesh, sbp, eqn, opts, ctx_residual, t)

  if opts["calc_jac_explicit"]
    A = getBasePC(pc).A
    assembly_begin(A, MAT_FINAL_ASSEMBLY)
    assembly_end(A, MAT_FINAL_ASSEMBLY)

    lambda_c = 1 - lambda # complement of lambda
    scale!(A, lambda_c)

    # compute the homotopy contribution to the Jacobian
    assembler = AssembleElementData(A, mesh, sbp, eqn, opts)
    evalHomotopyJacobian(mesh, sbp, eqn, opts, assembler, lambda)
  end

  return nothing
end

#------------------------------------------------------------------------------
# LO:

mutable struct HomotopyDenseLO <: AbstractDenseLO
  lo_inner::NewtonDenseLO
  lambda::Float64
end

function HomotopyDenseLO(pc::PCNone, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = NewtonDenseLO(pc, mesh, sbp, eqn, opts)
  lambda = 1.0
  return HomotopyDenseLO(lo_inner, lambda)
end

mutable struct HomotopySparseDirectLO <: AbstractSparseDirectLO
  lo_inner::NewtonSparseDirectLO
  lambda::Float64
end

function HomotopySparseDirectLO(pc::PCNone, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = NewtonSparseDirectLO(pc, mesh, sbp, eqn, opts)
  lambda = 1.0

  return HomotopySparseDirectLO(lo_inner, lambda)
end

mutable struct HomotopyPetscMatLO <: AbstractPetscMatLO
  lo_inner::NewtonPetscMatLO
  lambda::Float64
end


function HomotopyPetscMatLO(pc::AbstractPetscPC, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = NewtonPetscMatLO(pc, mesh, sbp, eqn, opts)
  lambda = 1.0

  return HomotopyPetscMatLO(lo_inner, lambda)
end


mutable struct HomotopyPetscMatFreeLO <: AbstractPetscMatFreeLO
  lo_inner::NewtonPetscMatFreeLO
  lambda::Float64  # this is unused, but needed for consistency
end

"""
  Homotopy mat-free linear operator constructor

  **Inputs**

   * pc
   * mesh
   * sbp
   * eqn
   * opts
   * rhs_func: rhs_func from [`newtonInner`](@ref)
"""
function HomotopyPetscMatFreeLO(pc::AbstractPetscPC, mesh::AbstractMesh,
                    sbp::AbstractOperator, eqn::AbstractSolutionData, opts::Dict)

  lo_inner = NewtonPetscMatFreeLO(pc, mesh, sbp, eqn, opts)
  lambda = 1.0

  return HomotopyPetscMatFreeLO(lo_inner, lambda)
end


"""
  Homotopy matrix-explicit linear operators
"""
const HomotopyMatLO = Union{HomotopyDenseLO, HomotopySparseDirectLO, HomotopyPetscMatLO}


function calcLinearOperator(lo::HomotopyMatLO, mesh::AbstractMesh,
                            sbp::AbstractOperator, eqn::AbstractSolutionData,
                            opts::Dict, ctx_residual, t)

   
  calcLinearOperator(lo.lo_inner, mesh, sbp, eqn, opts, ctx_residual, t)

  if opts["calc_jac_explicit"]
    A = getBaseLO(lo).A
    assembly_begin(A, MAT_FINAL_ASSEMBLY)
    assembly_end(A, MAT_FINAL_ASSEMBLY)

    lambda_c = 1 - lo.lambda # complement of lambda
    scale!(A, lambda_c)

    # compute the homotopy contribution to the Jacobian
    assembler = _AssembleElementData(A, mesh, sbp, eqn, opts)
    evalHomotopyJacobian(mesh, sbp, eqn, opts, assembler, lo.lambda)
  end

  return nothing
end


function calcLinearOperator(lo::HomotopyPetscMatFreeLO, mesh::AbstractMesh,
                            sbp::AbstractOperator, eqn::AbstractSolutionData,
                            opts::Dict, ctx_residual, t)

  calcLinearOperator(lo.lo_inner, mesh, sbp, eqn, opts, ctx_residual, t)

  setLOCtx(lo, mesh, sbp, eqn, opts, ctx_residual, 0.0)

  # nothing to do here

  return nothing
end


function applyLinearOperator(lo::HomotopyPetscMatFreeLO, mesh::AbstractMesh,
                       sbp::AbstractOperator, eqn::AbstractSolutionData{Tsol},
                       opts::Dict, ctx_residual, t, x::AbstractVector, 
                       b::AbstractVector) where Tsol

  @assert !(Tsol <: AbstractFloat)  # complex step only!

  # ctx_residual[1] = homotopyPhysics, so this computes both the physics
  # and homotopy contribution
  applyLinearOperator(lo.lo_inner, mesh, sbp, eqn, opts, ctx_residual, t, x, b)

  return nothing
end

function applyLinearOperatorTranspose(lo::HomotopyPetscMatFreeLO, 
                             mesh::AbstractMesh,
                             sbp::AbstractOperator, eqn::AbstractSolutionData{Tsol},
                             opts::Dict, ctx_residual, t, x::AbstractVector, 
                             b::AbstractVector) where Tsol

  error("applyLinearOperatorTranspose() not supported by HomotopyPetscMatFreeLO")

end
