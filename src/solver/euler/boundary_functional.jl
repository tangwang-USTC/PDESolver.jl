export evalFunctional, calcBndryFunctional, getFunctionalName

@doc """
### EulerEquationMod.evalFunctional

Hight level function that evaluates all the functionals specified over
various edges. This function is agnostic to the type of the functional being
computed and calls a mid level functional-type specific function for the actual
evaluation.

**Arguments**

*  `mesh` :  Abstract mesh object
*  `sbp`  : Summation-By-Parts operator
*  `eqn`  : Euler equation object
*  `opts` : Options dictionary
*  `functionalData` : Object of type AbstractOptimizationData. This is type is associated
                      with the functional being computed and holds all the
                      relevant data.
*  `functional_number` : A number identifying which functional is being computed.
                         This is important when multiple functions, that aren't
                         objective functions are being evaluated. Default value
                         is 1.
"""->
function evalFunctional{Tmsh, Tsol}(mesh::AbstractMesh{Tmsh},
                        sbp::AbstractSBP, eqn::EulerData{Tsol}, opts,
                        functionalData::AbstractOptimizationData;
                        functional_number::Int=1)

  if opts["parallel_type"] == 1

    startDataExchange(mesh, opts, eqn.q, eqn.q_face_send, eqn.q_face_recv,
                      eqn.params.f, wait=true)
    @debug1 println(eqn.params.f, "-----entered if statement around startDataExchange -----")

  end

  eqn.disassembleSolution(mesh, sbp, eqn, opts, eqn.q, eqn.q_vec)
  if mesh.isDG
    boundaryinterpolate!(mesh.sbpface, mesh.bndryfaces, eqn.q, eqn.q_bndry)
  end

  # Calculate functional over edges
  calcBndryFunctional(mesh, sbp, eqn, opts, functionalData)

  return nothing
end

@doc """
EulerEquationMod.evalFunctional_revm

Reverse mode of EulerEquationMod.evalFunctional, It takes in functional value
and return `mesh.dxidx_bndry_bar`

"""->

function evalFunctional_revm{Tmsh, Tsol}(mesh::AbstractMesh{Tmsh},
                        sbp::AbstractSBP, eqn::EulerData{Tsol}, opts,
                        functionalData::AbstractOptimizationData,
                        functionalName::ASCIIString)


  if opts["parallel_type"] == 1

    startDataExchange(mesh, opts, eqn.q, eqn.q_face_send, eqn.q_face_recv,
                      eqn.params.f, wait=true)
    @debug1 println(eqn.params.f, "-----entered if statement around startDataExchange -----")

  end

  eqn.disassembleSolution(mesh, sbp, eqn, opts, eqn.q, eqn.q_vec)
  if mesh.isDG
    boundaryinterpolate!(mesh.sbpface, mesh.bndryfaces, eqn.q, eqn.q_bndry)
  end

  # Calculate functional over edges
  if functionalName == "lift"

    bndry_force_bar = zeros(Tsol, mesh.dim)
    if mesh.dim == 2
      bndry_force_bar[1] -= sin(eqn.params.aoa)
      bndry_force_bar[2] += cos(eqn.params.aoa)
    else
      bndry_force_bar[1] -= sin(eqn.params.aoa)
      bndry_force_bar[3] += cos(eqn.params.aoa)
    end
    calcBndryFunctional_revm(mesh, sbp, eqn, opts, functionalData, bndry_force_bar)

  elseif functionalName == "drag"

    bndry_force_bar = zeros(Tsol, mesh.dim)
    if mesh.dim == 2
      bndry_force_bar[1] = cos(eqn.params.aoa)
      bndry_force_bar[2] = sin(eqn.params.aoa)
    else
      bndry_force_bar[1] = cos(eqn.params.aoa)
      bndry_force_bar[3] = sin(eqn.params.aoa)
    end
    calcBndryFunctional_revm(mesh, sbp, eqn, opts, functionalData, bndry_force_bar)

  else
    error("reverse mode of functional $functionalName not defined")
  end

  return nothing
end


@doc """
### EulerEquationMod.calcBndryFunctional

This function calculates a functional on a geometric boundary of a the
computational space. This is a mid level function that should not be called from
outside the module. DEpending on the functional being computd, it may be
necessary to define another method for this function based on a different
boundary functional type or parameters.

**Inputs**

*  `mesh` :  Abstract mesh object
*  `sbp`  : Summation-By-Parts operator
*  `eqn`  : Euler equation object
*  `opts` : Options dictionary
*  `functionalData` : Object which is a subtype of Abstract OptimizationData.
                      This is type is associated with the functional being
                      computed and holds all the relevant data.

"""->

function calcBndryFunctional{Tmsh, Tsol, Tres, Tdim}(mesh::AbstractDGMesh{Tmsh},
                             sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim},
                             opts, functionalData::BoundaryForceData)

  local_functional_val = zeros(Tsol, functionalData.ndof) # Local processor share
  bndry_force = functionalData.bndry_force
  fill!(bndry_force, 0.0)
  functional_edges = functionalData.geom_faces_functional
  phys_nrm = zeros(Tmsh, Tdim)

  # Get bndry_offsets for the functional edge concerned
  for itr = 1:length(functional_edges)
    g_edge_number = functional_edges[itr] # Extract geometric edge number
    # get the boundary array associated with the geometric edge
    itr2 = 0
    for itr2 = 1:mesh.numBC
      if findfirst(mesh.bndry_geo_nums[itr2],g_edge_number) > 0
        break
      end
    end

    start_index = mesh.bndry_offsets[itr2]
    end_index = mesh.bndry_offsets[itr2+1]
    idx_range = start_index:(end_index-1)
    bndry_facenums = sview(mesh.bndryfaces, idx_range) # faces on geometric edge i

    nfaces = length(bndry_facenums)
    boundary_integrand = zeros(Tsol, functionalData.ndof, mesh.sbpface.numnodes, nfaces)
    q2 = zeros(Tsol, mesh.numDofPerNode)

    for i = 1:nfaces
      bndry_i = bndry_facenums[i]
      global_facenum = idx_range[i]
      for j = 1:mesh.sbpface.numnodes
        q = sview(eqn.q_bndry, :, j, global_facenum)
        convertToConservative(eqn.params, q, q2)
        aux_vars = sview(eqn.aux_vars_bndry, :, j, global_facenum)
        x = sview(mesh.coords_bndry, :, j, global_facenum)
        dxidx = sview(mesh.dxidx_bndry, :, :, j, global_facenum)
        nrm = sview(sbp.facenormal, :, bndry_i.face)
        fill!(phys_nrm, 0.0)
        for k = 1:Tdim
            # nx = dxidx[1,1]*nrm[1] + dxidx[2,1]*nrm[2]
            # ny = dxidx[1,2]*nrm[1] + dxidx[2,2]*nrm[2]
          for l = 1:Tdim
            # phys_nrm[k] = dxidx[1,k]*nrm[1] + dxidx[2,k]*nrm[2]
            phys_nrm[k] += dxidx[l,k]*nrm[l]
          end
        end # End for k = 1:Tdim
        node_info = Int[itr,j,i]
        b_integrand_ji = sview(boundary_integrand,:,j,i)
        calcBoundaryFunctionalIntegrand(eqn.params, q2, aux_vars, phys_nrm,
                                        node_info, functionalData, b_integrand_ji)
      end  # End for j = 1:mesh.sbpface.numnodes
    end    # End for i = 1:nfaces

    val_per_geom_edge = zeros(Tsol, functionalData.ndof)

    integratefunctional!(mesh.sbpface, mesh.bndryfaces[idx_range],
                           boundary_integrand, val_per_geom_edge)

    local_functional_val[:] += val_per_geom_edge[:]

  end # End for itr = 1:length(functional_edges)

  for i = 1:functionalData.ndof
    bndry_force[i] = MPI.Allreduce(local_functional_val[i], MPI.SUM, eqn.comm)
  end

  # Compute lift, drag and their corresponding derivatives w.r.t alpha
  aoa = eqn.params.aoa # Angle of attack
  if mesh.dim == 2 # 2D Flow
    functionalData.lift_val = -bndry_force[1]*sin(aoa) + bndry_force[2]*cos(aoa)
    functionalData.drag_val = bndry_force[1]*cos(aoa) + bndry_force[2]*sin(aoa)
    functionalData.dLiftdAlpha = -bndry_force[1]*cos(aoa) - bndry_force[2]*sin(aoa)
    functionalData.dDragdAlpha = -bndry_force[1]*sin(aoa) + bndry_force[2]*cos(aoa)
  else # 3D Flow
    functionalData.lift_val = -bndry_force[1]*sin(aoa) + bndry_force[3]*cos(aoa)
    functionalData.drag_val = bndry_force[1]*cos(aoa) + bndry_force[3]*sin(aoa)
    functionalData.dLiftdAlpha = -bndry_force[1]*cos(aoa) - bndry_force[3]*sin(aoa)
    functionalData.dDragdAlpha = -bndry_force[1]*sin(aoa) + bndry_force[3]*cos(aoa)
  end

  return nothing
end

@doc """
###EulerEquationMod.calcBndryFunctional_revm

Reverse mode function That actually does the work.

"""

function calcBndryFunctional_revm{Tmsh, Tsol, Tres, Tdim}(mesh::AbstractDGMesh{Tmsh},
                                       sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim},
                                       opts, functionalData::BoundaryForceData,
                                       bndry_force_bar::AbstractArray{Tsol, 1})

  functional_faces = functionalData.geom_faces_functional
  phys_nrm = zeros(Tmsh, Tdim)
  aoa = eqn.params.aoa # Angle of attack

  lift_bar = one(Tsol)
  nxny_bar = zeros(Tmsh, functionalData.ndof)

  # TODO: Figure out the reverse of MPI.Allreduce. Is it even necessary
  local_functional_val_bar = zeros(Tsol, functionalData.ndof)
  # for i = 1:functionalData.ndof
  #   local_function_val_bar[i] = MPI.bcast(bndry_force_bar[i], 0, eqn.comm)
  # end
  local_functional_val_bar[:] += bndry_force_bar[:]

  # Loop over geometrical functional faces
  for itr = 1:length(functional_faces)

    g_face_number = functional_faces[itr] # Extract geometric edge number
    # get the boundary array associated with the geometric edge
    itr2 = 0
    for itr2 = 1:mesh.numBC
      if findfirst(mesh.bndry_geo_nums[itr2],g_face_number) > 0
        break
      end
    end

    start_index = mesh.bndry_offsets[itr2]
    end_index = mesh.bndry_offsets[itr2+1]
    idx_range = start_index:(end_index-1)
    bndry_facenums = sview(mesh.bndryfaces, idx_range) # faces on geometric edge i

    nfaces = length(bndry_facenums)
    boundary_integrand_bar = zeros(Tsol, functionalData.ndof, mesh.sbpface.numnodes, nfaces)
    q2 = zeros(Tsol, mesh.numDofPerNode)

    # local_functional_val[:] += val_per_geom_edge[:]
    val_per_geom_face_bar = zeros(Tsol, functionalData.ndof)
    val_per_geom_face_bar[:] += local_functional_val_bar[:]
    local_functional_val_bar[:] += local_functional_val_bar[:]
    integratefunctional_rev!(mesh.sbpface, mesh.bndryfaces[idx_range],
                             boundary_integrand_bar, val_per_geom_face_bar)


    for i = 1:nfaces
      bndry_i = bndry_facenums[i]
      global_facenum = idx_range[i]
      for j = 1:mesh.sbpface.numnodes
        q = sview(eqn.q_bndry, :, j, global_facenum)
        convertToConservative(eqn.params, q, q2)
        aux_vars = sview(eqn.aux_vars_bndry, :, j, global_facenum)
        x = sview(mesh.coords_bndry, :, j, global_facenum)
        dxidx = sview(mesh.dxidx_bndry, :, :, j, global_facenum)
        nrm = sview(sbp.facenormal, :, bndry_i.face)
        fill!(phys_nrm, 0.0)
        for k = 1:Tdim
          for l = 1:Tdim
            phys_nrm[k] += dxidx[l,k]*nrm[l]
          end
        end # End for k = 1:Tdim
        node_info = Int[itr,j,i]
        b_integrand_ji_bar = sview(boundary_integrand_bar, :, j, i)
        # calcBoundaryFunctionalIntegrand(eqn.params, q2, aux_vars, phys_nrm,
        #                                node_info, functionalData, b_integrand_ji)
        fill!(nxny_bar, 0.0)
        calcBoundaryFunctionalIntegrand_revm(eqn.params, q2, aux_vars, phys_nrm,
                                             node_info, functionalData,
                                             nxny_bar, b_integrand_ji_bar)
        dxidx_bar = sview(mesh.dxidx_bndry_bar, :, :, j, global_facenum)
        for k = 1:Tdim
          # dxidx_bar[1,k] += nxny_bar[k]*nrm[1]
          # dxidx_bar[2,k] += nxny_bar[k]*nrm[2]
          for l = 1:Tdim
            dxidx_bar[l,k] += nxny_bar[k]*nrm[l]
          end
        end # End for k = 1:Tdim

      end  # End for j = 1:mesh.sbpface.numnodes
    end    # End for i = 1:nfaces

  end # End for itr = 1:length(functional_faces)

  return nothing
end

@doc """
###EulerEquationMod.calcBoundaryFunctionalIntegrand

Computes the integrand for boundary functional at a surface SBP node. Every
functional of a different type may need a corresponding method to compute the
integrand. The type of the functional object, which is a subtype of
`AbstractOptimizationData`.

**Arguments**

*  `params` : eqn.params object
*  `q` : Nodal solution
*  `aux_vars` : Auxiliary variables
*  `nrm` : Face normal vector in the physical space
*  `node_info` : Information about the SBP node
*  `objective` : Functional data type
*  `val` : Function output value

"""->
function calcBoundaryFunctionalIntegrand{Tsol, Tres, Tmsh}(params::ParamType{2},
                                         q::AbstractArray{Tsol,1},
                                         aux_vars::AbstractArray{Tres, 1},
                                         nrm::AbstractArray{Tmsh},
                                         node_info::AbstractArray{Int},
                                         objective::BoundaryForceData,
                                         val::AbstractArray{Tsol,1})

  # Compute the numerical flux for the euler equation and extract the X & Y
  # momentum values. The normal vector supplied has already been converted
  # to the physical space from the parametric space.

  euler_flux = params.flux_vals1 # Reuse existing memory
  # nx = nrm[1]
  # ny = nrm[2]

  fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2]))
  # normalize normal vector
  nx = nrm[1]*fac
  ny = nrm[2]*fac

  normal_momentum = nx*q[2] + ny*q[3]

  qg = params.qg
  for i=1:length(q)
    qg[i] = q[i]
  end
  qg[2] -= nx*normal_momentum
  qg[3] -= ny*normal_momentum

  calcEulerFlux(params, qg, aux_vars, nrm, euler_flux)
  val[:] = euler_flux[2:3]

  return nothing
end # End calcBoundaryFunctionalIntegrand 2D

function calcBoundaryFunctionalIntegrand{Tsol, Tres, Tmsh}(params::ParamType{3},
                                         q::AbstractArray{Tsol,1},
                                         aux_vars::AbstractArray{Tres, 1},
                                         nrm::AbstractArray{Tmsh},
                                         node_info::AbstractArray{Int},
                                         objective::BoundaryForceData,
                                         val::AbstractArray{Tsol,1})

  fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3]))
  # normalize normal vector
  nx = nrm[1]*fac
  ny = nrm[2]*fac
  nz = nrm[3]*fac

  normal_momentum = nx*q[2] + ny*q[3] + nz*q[4]
  qg = params.qg
  for i=1:length(q)
    qg[i] = q[i]
  end
  qg[2] -= nx*normal_momentum
  qg[3] -= ny*normal_momentum
  qg[4] -= nz*normal_momentum

  euler_flux = params.flux_vals1 # Reuse existing memory
  calcEulerFlux(params, qg, aux_vars, nrm, euler_flux)
  val[:] = euler_flux[2:4]

  return nothing
end # End calcBoundaryFunctionalIntegrand 3D

@doc """
calcBoundaryFunctionalIntegrand_revm

Reverse mode for boundary functional integrand w.r.t. nrm. Takes in input
val_bar and return nrm_bar for further reverse propagation.

"""->

function calcBoundaryFunctionalIntegrand_revm{Tsol, Tres, Tmsh}(params::ParamType{2},
                                         q::AbstractArray{Tsol,1},
                                         aux_vars::AbstractArray{Tres, 1},
                                         nrm::AbstractArray{Tmsh},
                                         node_info::AbstractArray{Int},
                                         objective::BoundaryForceData,
                                         nrm_bar::AbstractArray{Tmsh,1},
                                         val_bar::AbstractArray{Tres, 1})

  #---- Forward sweep
  fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2]))
  nx = nrm[1]*fac # Normalized unit vectors
  ny = nrm[2]*fac #
  normal_momentum = nx*q[2] + ny*q[3]
  qg = params.qg
  for i=1:length(q)
    qg[i] = q[i]
  end
  qg[2] -= nx*normal_momentum
  qg[3] -= ny*normal_momentum

  #---- Reverse Sweep
  euler_flux_bar = zeros(Tsol, 4) # For 2D
  qg_bar = zeros(Tsol, 4)
  q_bar = zeros(Tsol,4)

  # Reverse diff val[:] = euler_flux[2:3]
  euler_flux_bar[2:3] += val_bar[:]

  # Reverse diff calcEulerFlux
  calcEulerFlux_revm(params, qg, aux_vars, nrm, euler_flux_bar, nrm_bar)
  calcEulerFlux_revq(params, qg, aux_vars, nrm, euler_flux_bar, qg_bar)
  ny_bar = zero(Tsol)               # Initialize
  nx_bar = zero(Tsol)               #
  normal_momentum_bar = zero(Tsol)  #

  # Reverse diff qg[3] -= ny*normal_momentum
  ny_bar -= qg_bar[3]*normal_momentum
  normal_momentum_bar -= qg_bar[3]*ny
  qg_bar[3] += qg_bar[3]

  # Reverse diff qg[2] -= nx*normal_momentum
  nx_bar -= qg_bar[2]*normal_momentum
  normal_momentum_bar -= qg_bar[2]*nx
  qg_bar[2] += qg_bar[2]

  # Reverse diff qg[:] = q[:]
  q_bar[:] += qg_bar[:]

  # Reverse diff normal_momentum = nx*q[2] + ny*q[3]
  nx_bar += normal_momentum_bar*q[2]
  ny_bar += normal_momentum_bar*q[3]
  q_bar[2] += normal_momentum_bar*nx
  q_bar[3] += normal_momentum_bar*ny

  # Reverse diff ny = nrm[2]*fac
  fac_bar = zero(Tsol)
  nrm_bar[2] += ny_bar*fac
  fac_bar += ny_bar*nrm[2]

  # Reverse diff nx = nrm[1]*fac
  nrm_bar[1] += nx_bar*fac
  fac_bar += nx_bar*nrm[1]

  # Reverse diff fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2]))
  nrm_bar[1] -= fac_bar*((nrm[1]*nrm[1] + nrm[2]*nrm[2])^(-1.5))*nrm[1]
  nrm_bar[2] -= fac_bar*((nrm[1]*nrm[1] + nrm[2]*nrm[2])^(-1.5))*nrm[2]

  return nothing
end # End calcBoundaryFunctionalIntegrand_revm 2D

function calcBoundaryFunctionalIntegrand_revm{Tsol, Tres, Tmsh}(params::ParamType{3},
                                         q::AbstractArray{Tsol,1},
                                         aux_vars::AbstractArray{Tres, 1},
                                         nrm::AbstractArray{Tmsh},
                                         node_info::AbstractArray{Int},
                                         objective::BoundaryForceData,
                                         nrm_bar::AbstractArray{Tmsh,1},
                                         val_bar::AbstractArray{Tres, 1})

  # Forward Sweep
  fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3]))
  nx = nrm[1]*fac
  ny = nrm[2]*fac
  nz = nrm[3]*fac

  normal_momentum = nx*q[2] + ny*q[3] + nz*q[4]
  qg = params.qg
  for i=1:length(q)
    qg[i] = q[i]
  end
  qg[2] -= nx*normal_momentum
  qg[3] -= ny*normal_momentum
  qg[4] -= nz*normal_momentum

  # Reverse Sweep
  euler_flux_bar = zeros(Tsol, 5) # For 2D
  qg_bar = zeros(Tsol, 5)
  q_bar = zeros(Tsol,5)

  # Reverse diff val[:] = euler_flux[2:4]
  euler_flux_bar[2:4] += val_bar[:]

  # Reverse diff calcEulerFlux
  calcEulerFlux_revm(params, qg, aux_vars, nrm, euler_flux_bar, nrm_bar)
  calcEulerFlux_revq(params, qg, aux_vars, nrm, euler_flux_bar, qg_bar)
  nz_bar = zero(Tsol)               #
  ny_bar = zero(Tsol)               # Initialize
  nx_bar = zero(Tsol)               #
  normal_momentum_bar = zero(Tsol)  #

  # qg[4] -= nz*normal_momentum
  nz_bar -= qg_bar[4]*normal_momentum
  normal_momentum_bar -= qg_bar[4]*nz
  qg_bar[4] += qg_bar[4]

  # Reverse diff qg[3] -= ny*normal_momentum
  ny_bar -= qg_bar[3]*normal_momentum
  normal_momentum_bar -= qg_bar[3]*ny
  qg_bar[3] += qg_bar[3]

  # Reverse diff qg[2] -= nx*normal_momentum
  nx_bar -= qg_bar[2]*normal_momentum
  normal_momentum_bar -= qg_bar[2]*nx
  qg_bar[2] += qg_bar[2]

  # Reverse diff qg[:] = q[:]
  q_bar[:] += qg_bar[:]

  # normal_momentum = nx*q[2] + ny*q[3] + nz*q[4]
  nx_bar += normal_momentum_bar*q[2]
  ny_bar += normal_momentum_bar*q[3]
  nz_bar += normal_momentum_bar*q[4]

  # nz = nrm[3]*fac
  nrm_bar[3] += nz_bar*fac
  fac_bar = nz_bar*nrm[3]

  # Reverse diff ny = nrm[2]*fac
  nrm_bar[2] += ny_bar*fac
  fac_bar += ny_bar*nrm[2]

  # Reverse diff nx = nrm[1]*fac
  nrm_bar[1] += nx_bar*fac
  fac_bar += nx_bar*nrm[1]

  # fac = 1.0/(sqrt(nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3]))
  nrm_bar[1] -= fac_bar*((nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3])^(-1.5))*nrm[1]
  nrm_bar[2] -= fac_bar*((nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3])^(-1.5))*nrm[2]
  nrm_bar[3] -= fac_bar*((nrm[1]*nrm[1] + nrm[2]*nrm[2] + nrm[3]*nrm[3])^(-1.5))*nrm[3]

  return nothing
end # End calcBoundaryFunctionalIntegrand_revm 3D

#=
@doc """
### EulerEquationMod.targetCp

"""

type targetCp <: FunctionalType
end

function call{Tsol, Tres, Tmsh}(obj::targetCp, params, q::AbstractArray{Tsol,1},
              aux_vars::AbstractArray{Tres, 1}, nrm::AbstractArray{Tmsh},
              node_info::AbstractArray{Int},
              objective::AbstractOptimizationData, val::AbstractArray{Tsol,1})

  cp_node = calcPressureCoeff(params, q)
  g_face = node_info[1]
  node = node_info[2]
  face = node_info[3]
  cp_target = objective.pressCoeff_obj.targetCp_arr[g_face][node, face]

  val[1] = 0.5*((cp_node - cp_target).^2)

  return nothing
end


@doc """
### EulerEquationMod.FunctionalDict

It stores the names of all possible functional options that can be computed.
Whenever a new functional is created, it should be added to FunctionalDict.

"""->
global const FunctionalDict = Dict{ASCIIString, FunctionalType}(
"drag" => drag(),
"lift" => lift(),
"targetCp" => targetCp(),
"dLiftdAlpha" => dLiftdAlpha(),
"dDragdAlpha" => dDragdAlpha(),
"boundaryForce" => boundaryForce()
)


@doc """
### EulerEquationMod.getFunctionalName

Gets the name of the functional that needs to be computed at a particular point

**Inputs**

*  `opts`     : Input dictionary
*  `f_number` : Number of the functional in the input dictionary

**Outputs**

*  `functional` : Returns the functional name in the dictionary. It is of type
                  `FucntionalType`,

"""->
function getFunctionalName(opts, f_number;is_objective_fn=false)

  key = string("functional_name", f_number)
  val = opts[key]

  return functional = FunctionalDict[val]
end

function getnFaces(mesh::AbstractDGMesh, g_face::Int)

  i = 0
  for i = 1:mesh.numBC
    if findfirst(mesh.bndry_geo_nums[i],g_face) > 0
      break
    end
  end

  start_index = mesh.bndry_offsets[i]
  end_index = mesh.bndry_offsets[i+1]
  idx_range = start_index:(end_index-1)
  bndry_facenums = sview(mesh.bndryfaces, idx_range) # faces on geometric edge i
  nfaces = length(bndry_facenums)

  return nfaces
end
=#

#=

function calcPhysicalEulerFlux{Tsol}(params::ParamType{2}, q::AbstractArray{Tsol,1},
                               F::AbstractArray{Tsol, 2})

  u = q[2]/q[1]
  v = q[3]/q[1]
  p = calcPressure(params, q)

  # Calculate Euler Flux in X-direction
  F[1,1] = q[2]
  F[2,1] = q[2]*u + p
  F[3,1] = q[2]*v
  F[4,1] = u*(q[4] + p)

  # Calculate Euler Flux in Y-direction

  F[1,2] = q[3]
  F[2,2] = q[3]*u
  F[3,2] = q[3]*v + p
  F[4,2] = v*(q[4] + p)

  return nothing
end

function calcBndryfunctional{Tmsh, Tsol, Tres, Tdim}(mesh::AbstractCGMesh{Tmsh},
                            sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim},
                            opts, g_edge_number)

  # Specify the boundary conditions for the edge on which the force needs to be computed
  # separately in the input dictionary. Use that boundary number to access the boundary
  # offset array. Then proceed the same as bndryflux to get the forces using
  # boundaryintegrate!


  # g_edge_number = 1 # Geometric boundary edge on which the force needs to be computed
  start_index = mesh.bndry_offsets[g_edge_number]
  end_index = mesh.bndry_offsets[g_edge_number+1]
  bndry_facenums = sview(mesh.bndryfaces, start_index:(end_index - 1)) # faces on geometric edge i
  # println("bndry_facenums = ", bndry_facenums)

  nfaces = length(bndry_facenums)
  boundary_press = zeros(Tsol, Tdim, sbp.numfacenodes, nfaces)
  boundary_force = zeros(Tsol, Tdim, sbp.numnodes, mesh.numEl)
  q2 = zeros(Tsol, mesh.numDofPerNode)
  # analytical_force = zeros(Tsol, sbp.numfacenodes, nfaces)


  for i = 1:nfaces
    bndry_i = bndry_facenums[i]
    for j = 1:sbp.numfacenodes
      k = sbp.facenodes[j, bndry_i.face]
      q = sview(eqn.q, :, k, bndry_i.element)
      convertToConservative(eqn.params, q, q2)
      aux_vars = sview(eqn.aux_vars, :, k, bndry_i.element)
      x = sview(mesh.coords, :, k, bndry_i.element)
      dxidx = sview(mesh.dxidx, :, :, k, bndry_i.element)
      nrm = sview(sbp.facenormal, :, bndry_i.face)

      # analytical_force[k,bndry_i.element] = calc_analytical_forces(mesh, eqn.params, x)
      nx = dxidx[1,1]*nrm[1] + dxidx[2,1]*nrm[2]
      ny = dxidx[1,2]*nrm[1] + dxidx[2,2]*nrm[2]

      # Calculate euler flux for the current iteration
      euler_flux = zeros(Tsol, mesh.numDofPerNode)
      calcEulerFlux(eqn.params, q2, aux_vars, [nx, ny], euler_flux)

      # Boundary pressure in "ndimensions" direcion
      boundary_press[:,j,i] =  euler_flux[2:3]
    end # end for j = 1:sbp.numfacenodes
  end   # end for i = 1:nfaces
  boundaryintegrate!(mesh.sbpface, mesh.bndryfaces[start_index:(end_index - 1)],
                     boundary_press, boundary_force)

  functional_val = zeros(Tsol,2)

  for (bindex, bndry) in enumerate(mesh.bndryfaces[start_index:(end_index - 1)])
    for i = 1:sbp.numfacenodes
      k = sbp.facenodes[i, bndry.face]
      functional_val[:] += boundary_force[:,k,bndry.element]
    end
  end  # end enumerate


  return functional_val
end
=#
