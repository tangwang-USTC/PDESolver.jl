# shock capturing using any the SBP-SAT discretization of the second derivative
# term

"""
  Applies [`SBPParabolic`](@ref) shock capturing.
"""
function calcShockCapturing(mesh::AbstractMesh, sbp::AbstractOperator,
                             eqn::EulerData, opts,
                             capture::SBPParabolicReduced2SC{Tsol, Tres},
                             shockmesh::ShockedElements) where {Tsol, Tres}

  computeGradW(mesh, sbp, eqn, opts, capture, shockmesh,
               capture.entropy_vars, capture.diffusion)

  computeVolumeTerm(mesh, sbp, eqn, opts, capture, shockmesh)

  computeFaceTerm(mesh, sbp, eqn, opts, capture, shockmesh, capture.diffusion,
                  capture.penalty)

  # this doesn't seem to help
#  computeDirichletBoundaryTerm(mesh, sbp, eqn, opts, capture, shockmesh)
  #println("after face term, residual norm = ", calcNorm(eqn, eqn.res))

#  if shockmesh.isNeumann
#    computeNeumannBoundaryTerm(mesh, sbp, eqn, opts, capture, shockmesh)
#  else
#    computeDirichletBoundaryTerm(mesh, sbp, eqn, opts, capture, shockmesh)
#  end

#  computeSharedFaceTerm(mesh, sbp, eqn, opts, capture, shockmesh,
#                              capture.diffusion, capture.penalty)


  return nothing
end

"""
  Computes:

  [ grad_x q  =  [ lambda_xx lambda_xy  [ Dx * w
    grad_y q]      lambda_yx lambda_yy]   Dy * w]

  and stores it in `capture.grad_w`.  Note that lambda = 0 for elements that
  do not have shocks in them, so the `grad_q` is set to zero there.

  **Inputs**

   * mesh
   * sbp
   * eqn
   * opts
   * capture: [`SBPParabolicReduced2SC`](@ref)
   * shockmesh: the `ShockedElements`
   * entropy_vars: an [`AbstractVariables`](@ref) object
   * diffusion: an [`AbstractDiffusion`](@ref)
"""
function computeGradW(mesh, sbp, eqn, opts, capture::SBPParabolicReduced2SC{Tsol, Tres},
                      shockmesh::ShockedElements,
                      entropy_vars::AbstractVariables,
                      diffusion::AbstractDiffusion,
                     ) where {Tsol, Tres}

  wxi = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerElement, mesh.dim)
  grad_w = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerElement, mesh.dim)

  # do local elements
  @simd for i in shockmesh.local_els
    i_full = shockmesh.elnums_all[i]
    @simd for j=1:mesh.numNodesPerElement
      q_j = ro_sview(eqn.q, :, j, i_full)
      w_j = sview(capture.w_el, :, j, i)

      # convert to entropy variables
      convertToEntropy(entropy_vars, eqn.params, q_j, w_j)
    end

    # apply D operator
    q_i = ro_sview(eqn.q, :, :, i_full)
    w_i = ro_sview(capture.w_el, :, :, i)
    coords = ro_sview(mesh.coords, :, :, i_full)
    dxidx_i = ro_sview(mesh.dxidx, :, :, :, i_full)
    jac_i = ro_sview(mesh.jac, :, i_full)
    fill!(grad_w, 0)
    applyDx(sbp, w_i, dxidx_i, jac_i, wxi, grad_w)

    # apply diffusion tensor
    lambda_gradq_i = sview(capture.grad_w, :, :, :, i)

    applyDiffusionTensor(diffusion, sbp, eqn.params, q_i, w_i, coords, dxidx_i,
                         jac_i, i, grad_w, lambda_gradq_i)
  end

  # the diffusion is zero in the neighboring elements, so convert to entropy
  # but zero out grad_w
  @simd for i in shockmesh.neighbor_els
    i_full = shockmesh.elnums_all[i]
    @simd for j=1:mesh.numNodesPerElement
      q_j = ro_sview(eqn.q, :, j, i_full)
      w_j = sview(capture.w_el, :, j, i)
      convertToEntropy(entropy_vars, eqn.params, q_j, w_j)
    end

    gradw_i = sview(capture.grad_w, :, :, :, i)
    fill!(gradw_i, 0)
  end

  # do shared elements
  for peer=1:shockmesh.npeers
    peer_full = shockmesh.peer_indices[peer]
    data = eqn.shared_data[peer_full]
    metrics = mesh.remote_metrics[peer_full]

    for i in shockmesh.shared_els[peer]
      i_full = getSharedElementIndex(shockmesh, mesh, peer, i)

      # compute entropy variables
      for j=1:mesh.numNodesPerElement
        q_j = ro_sview(data.q_recv, :, j, i_full)
        w_j = sview(capture.w_el, :, j, i)
        convertToEntropy(entropy_vars, eqn.params, q_j, w_j)
      end

      lambda_gradq_i = sview(capture.grad_w, :, :, :, i)

      # some of these have ee = 0, but we don't have the sensor so we can't
      # check
      q_i = ro_sview(data.q_recv, :, :, i_full)
      w_i = ro_sview(capture.w_el, :, :, i)
      coords_i = ro_sview(metrics.coords, :, :, i_full)
      dxidx_i = ro_sview(metrics.dxidx, :, :, :, i_full)
      jac_i = ro_sview(metrics.jac, :, i_full)
      fill!(grad_w, 0)

      applyDx(sbp, w_i, dxidx_i, jac_i, wxi, grad_w)
      applyDiffusionTensor(diffusion, sbp, eqn.params, q_i,  w_i, coords_i,
                           dxidx_i, jac_i, i, grad_w, lambda_gradq_i)

    end  # end i
  end  # end peer

  return nothing
end


"""
  Computes the volume terms, using the intermediate variable calcualted by
  [`computeGradW`](@ref).  The residual is updated with

  [Qx Qy] * [Lambda] * [Dx * w
                        Dy * w]

  Note that this used Qx, not Qx^T, so the term has not been integrated by
  parts.

  **Inputs**

   * mesh
   * sbp
   * eqn
   * opts
   * capture: [`SBPParbaolicSC`](@ref)
   * shockmesh
"""
@noinline function computeVolumeTerm(mesh, sbp, eqn, opts,
                           capture::SBPParabolicReduced2SC{Tsol, Tres},
                           shockmesh::ShockedElements) where {Tsol, Tres}

  # computeGradW computes Lambda * D * w, so all that remains to do is
  # compute Qx * grad_q_x
  # Note that this term is not entropy stable by itself, because Qx was
  # not replaced by -Qx^T + Ex.  The entire discretization should be
  # entropy-stable however.
  work = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerElement, mesh.dim)
  op = SummationByParts.Subtract()
  for i=1:shockmesh.numShock
    i_full = shockmesh.elnums_all[i]

    gradq_i = ro_sview(capture.grad_w, :, :, :, i)
    dxidx_i = ro_sview(mesh.dxidx, :, :, :, i_full)
    res_i = sview(eqn.res, :, :, i_full)
    #applyQx(sbp, gradq_i, dxidx_i, work, res_i)

    applyQxTransposed(sbp, gradq_i, dxidx_i, work, res_i, op)
  end

  return nothing
end


"""
  Computes the interior face term for any [`SBPParabolic`](@ref) shock
  capturing scheme.

  **Inputs**

   * mesh
   * sbp
   * eqn: `eqn.res` is updated with the result
   * opts
   * shockmesh
   * diffusion: the [`AbstractDiffusion`](@ref) to use (must be consistent
                with the one passed to [`computeGradW`](@ref).
   * penalty: [`AbstractDiffusionPenalty`](@ref) specifying which scheme to use

"""
@noinline function computeFaceTerm(mesh, sbp, eqn, opts,
                      capture::SBPParabolicReduced2SC{Tsol, Tres},
                      shockmesh::ShockedElements, diffusion::AbstractDiffusion,
                      penalty::AbstractDiffusionPenalty) where {Tsol, Tres}

  #TODO: avoid recalculating the diffusion tensor 6 time: add an API for
  #      caching it (called in getFaceData) and then apply it.  Add a clear
  #      cache function at end so future calls to applyDiffusionTensor work
  delta_w = zeros(Tsol, mesh.numDofPerNode, mesh.numNodesPerFace)
  theta = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)

  t1L = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t1R = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t2L = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t2R = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  op = SummationByParts.Subtract()

  for i=1:shockmesh.numInterfaces
    iface_red = shockmesh.ifaces[i].iface
    iface_idx = shockmesh.ifaces[i].idx_orig
    elnumL = shockmesh.elnums_all[iface_red.elementL]
    elnumR = shockmesh.elnums_all[iface_red.elementR]

    # get data needed for next steps
    qL = ro_sview(eqn.q, :, :, elnumL)
    qR = ro_sview(eqn.q, :, :, elnumR)
    wL = ro_sview(capture.w_el, :, :, iface_red.elementL)
    wR = ro_sview(capture.w_el, :, :, iface_red.elementR)
    gradwL = ro_sview(capture.grad_w, :, :, :, iface_red.elementL)
    gradwR = ro_sview(capture.grad_w, :, :, :, iface_red.elementR)

    coordsL = ro_sview(mesh.coords, :, :, elnumL)
    coordsR = ro_sview(mesh.coords, :, :, elnumR)
    nrm_face = ro_sview(mesh.nrm_face, :, :, iface_idx)
    dxidxL = ro_sview(mesh.dxidx, :, :, :, elnumL)
    dxidxR = ro_sview(mesh.dxidx, :, :, :, elnumR)
    jacL = ro_sview(mesh.jac, :, elnumL)
    jacR = ro_sview(mesh.jac, :, elnumR)
    resL = sview(eqn.res, :, :, elnumL)
    resR = sview(eqn.res, :, :, elnumR)

    # compute delta w tilde and theta_bar = Dgk w_k + Dgn w_n
    getFaceVariables(capture, mesh.sbpface, iface_red, wL, wR, gradwL, gradwR,
                     nrm_face, delta_w)

    # apply the penalty coefficient matrix
    applyReduced2Penalty(penalty, sbp, eqn.params, mesh.sbpface, diffusion,
                 iface_red, delta_w, theta,
                 qL, qR, wL, wR, coordsL, coordsR, nrm_face, dxidxL,
                 dxidxR, jacL, jacR, t1L, t1R)

    # apply Rgk^T, Rgn^T, Dgk^T, Dgn^T
    # need to apply R^T * t1, not R^T * B * t1, so
    # interiorFaceIntegrate won't work.  Use the reverse mode instead
    for j=1:mesh.numNodesPerFace
      for k=1:mesh.numDofPerNode
        t1L[k, j] = -t1L[k, j]  # the SAT has a minus sign in front of it
        t1R[k, j] = -t1R[k, j]
      end
    end
    interiorFaceInterpolate_rev!(mesh.sbpface, iface_red, resL, resR, t1L, t1R)
#=
    # apply Dgk^T and Dgn^T
    # TODO: there is an allocation here caused by the number of arguments
    #       to the function, however the allocation is context dependent.
    #       Pulling this function out of PDESolver removes the allocation.
    #       The allocation can be avoided by packing dxidxL, jacL, and resL
    #       into a tuple (and similarly for the corresponding R arguments),
    #       however the allocation does not appear to cause a significant
    #       performance problem.
    applyDgkTranspose(capture, sbp, eqn.params, mesh.sbpface, iface_red,
                      diffusion, t2L, t2R,
                      qL, qR, wL, wR, coordsL, coordsR, nrm_face, dxidxL,
                      dxidxR, jacL, jacR, resL, resR, op)
=#
  end  # end loop i

  return nothing
end

#=
"""
  Does the same thing as `compuateFaceTerm`, but for the shared faces, updating
  the residual on the local element only
"""
@noinline function computeSharedFaceTerm(mesh, sbp, eqn, opts,
                      capture::SBPParabolicReduced2SC{Tsol, Tres},
                      shockmesh::ShockedElements, diffusion::AbstractDiffusion,
                      penalty::AbstractDiffusionPenalty) where {Tsol, Tres}

  delta_w = zeros(Tsol, mesh.numDofPerNode, mesh.numNodesPerFace)
  theta = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)

  t1L = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t1R = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t2L = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  t2R = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  op = SummationByParts.Subtract()


  # don't care about resR for shared faces
  resR = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerElement)
  for _peer=1:shockmesh.npeers
    # finish parallel communication for this set of faces
    peer = receiveAlpha(capture, shockmesh)

    peer_full = shockmesh.peer_indices[peer]
    metrics = mesh.remote_metrics[peer_full]
    data = eqn.shared_data[peer_full]

    for i=1:shockmesh.numSharedInterfaces[peer]
      iface_red = shockmesh.shared_interfaces[peer][i].iface
      iface_idx = shockmesh.shared_interfaces[peer][i].idx_orig
      elnumL = shockmesh.elnums_all[iface_red.elementL]
      elnumR = getSharedElementIndex(shockmesh, mesh, peer, iface_red.elementR)

      # get data needed for next steps
      qL = ro_sview(eqn.q, :, :, elnumL)
      qR = ro_sview(data.q_recv, :, :, elnumR)
      wL = ro_sview(capture.w_el, :, :, iface_red.elementL)
      wR = ro_sview(capture.w_el, :, :, iface_red.elementR)
      gradwL = ro_sview(capture.grad_w, :, :, :, iface_red.elementL)
      gradwR = ro_sview(capture.grad_w, :, :, :, iface_red.elementR)

      coordsL = ro_sview(mesh.coords   , :, :, elnumL)
      coordsR = ro_sview(metrics.coords, :, :, elnumR)
      nrm_face = ro_sview(mesh.nrm_sharedface[peer_full], :, :, iface_idx)
      dxidxL = ro_sview(mesh.dxidx,    :, :, :, elnumL)
      dxidxR = ro_sview(metrics.dxidx, :, :, :, elnumR)
      jacL = ro_sview(mesh.jac,    :, elnumL)
      jacR = ro_sview(metrics.jac, :, elnumR)
      alphas = ro_sview(capture.alpha_parallel[peer], :, i)
      resL = sview(eqn.res, :, :, elnumL)

      # compute delta w tilde and theta_bar = Dgk w_k + Dgn w_n
      getFaceVariables(capture, mesh.sbpface, iface_red, wL, wR, gradwL, gradwR,
                       nrm_face, delta_w, theta)

      # apply the penalty coefficient matrix
      applyPenalty(penalty, sbp, eqn.params, mesh.sbpface, diffusion,
                   iface_red, delta_w,
                   theta, qL, qR,  wL, wR, coordsL, coordsR, nrm_face, alphas,
                   dxidxL, dxidxR, jacL, jacR, t1L, t1R, t2L, t2R)

      # apply Rgk^T, Rgn^T, Dgk^T, Dgn^T
      # need to apply R^T * t1, not R^T * B * t1, so
      # interiorFaceIntegrate won't work.  Use the reverse mode instead
      for j=1:mesh.numNodesPerFace
        for k=1:mesh.numDofPerNode
          t1L[k, j] = -t1L[k, j]  # the SAT has a minus sign in front of it
          t1R[k, j] = -t1R[k, j]
        end
      end
      #TODO: this could be a boundaryIntegrate now that resR doesn't matter
      interiorFaceInterpolate_rev!(mesh.sbpface, iface_red, resL, resR,
                                   t1L, t1R)

      # apply Dgk^T and Dgn^T
      applyDgkTranspose(capture, sbp, eqn.params, mesh.sbpface, iface_red,
                        diffusion,
                        t2L, qL, wL, coordsL, nrm_face, dxidxL, jacL, resL, op)
    end  # end i
  end  # end peer

  return nothing
end
=#

"""
  Compute delta_w = Rgk * wL - Rgn - wR and theta = Dgk * wL + Dgn * wR
  at the face.

  **Inputs**

   * capture: an [`SBPParabolic`](@ref) object
   * sbpface
   * iface_red: an `Interface` object from the `shockmesh`
   * wL: the entropy variables for the left element, `numDofPerNode` x
         `numNodesPerElement`
   * wR: the entropy variables for the right element, same size as `wL`
   * gradwL: Lambda * [Dx, Dy]*wL (as computed by [`computeGradW`](@ref),
             `numDofPerNode` x `numNodesPerElement` x `dim`
   * gradwR: same as `gradwR`, but for the right element
   * nrm_face: the (scaled) normal vectors for the face, `dim` x
               `numNodesPerFace`

  **Inputs/Outputs**

   * delta_w: `numDofPerNode` x `numNodesPerFace`, overwritten
   * theta: `numDofPerNode` x `numNodesPerFace`, overwritten
"""
function getFaceVariables(capture::SBPParabolicReduced2SC{Tsol, Tres},
                          sbpface::AbstractFace, iface_red::Interface,
                          wL::AbstractMatrix, wR::AbstractMatrix,
                          gradwL::Abstract3DArray, gradwR::Abstract3DArray,
                          nrm_face::AbstractMatrix,
                          delta_w::AbstractMatrix,
                         ) where {Tsol, Tres}

  numDofPerNode, numNodesPerElement = size(wL)
  numNodesPerFace = size(delta_w, 2)
  dim = size(gradwL, 3)

  @unpack capture w_faceL w_faceR grad_faceL grad_faceR

  interiorFaceInterpolate!(sbpface, iface_red, wL, wR, w_faceL, w_faceR)

  @simd for j=1:numNodesPerFace
    @simd for k=1:numDofPerNode
      delta_w[k, j] = w_faceL[k, j] - w_faceR[k, j]
    end
  end

  return nothing
end


#------------------------------------------------------------------------------
# Dirichlet boundary condition


const ParabolicReduceds{Tsol, Tres} = Union{SBPParabolicReducedSC{Tsol, Tres},
                                            SBPParabolicReduced2SC{Tsol, Tres}
                                           }


"""
  Computes a Dirichlet BC that is consistent with the inviscid one
"""
@noinline function computeDirichletBoundaryTerm(mesh, sbp, eqn, opts,
                      capture::ParabolicReduceds{Tsol, Tres},
                      shockmesh::ShockedElements,
                      ) where {Tsol, Tres}

  for i=1:mesh.numBC
    bc_range = (shockmesh.bndry_offsets[i]:(shockmesh.bndry_offsets[i+1]-1))
    bc_func = mesh.bndry_funcs[i]

    calcBoundaryFlux(mesh, sbp, eqn, opts, shockmesh, capture,
                     capture.penalty, capture.diffusion, 
                     capture.entropy_vars, bc_func, bc_range)
  end

  return nothing
end

@noinline function calcBoundaryFlux(mesh::AbstractMesh, sbp, eqn::EulerData, opts,
                      shockmesh::ShockedElements,
                      capture::ParabolicReduceds{Tsol, Tres},
                      penalty::AbstractDiffusionPenalty,
                      diffusion::AbstractDiffusion,
                      entropy_vars::AbstractVariables, bc_func::BCType,
                      bc_range::AbstractVector,
                      ) where {Tsol, Tres}


  delta_w = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  res1 = zeros(Tres, mesh.numDofPerNode, mesh.numNodesPerFace)
  op = SummationByParts.Subtract()  # the - sign is applied with B

  for i in bc_range
    bndry_i = shockmesh.bndryfaces[i].bndry
    idx_orig = shockmesh.bndryfaces[i].idx_orig
    elnum_orig = shockmesh.elnums_all[bndry_i.element]

    w_i = ro_sview(capture.w_el, :, :, bndry_i.element)
    q_i = ro_sview(eqn.q, :, :, elnum_orig)
    coords_i = ro_sview(mesh.coords_bndry, :, :, idx_orig)
    nrm_i = ro_sview(mesh.nrm_bndry, :, :, idx_orig)
    #alpha = capture.alpha_b[i]
    alpha = 1
    dxidxL = ro_sview(mesh.dxidx, :, :, :, elnum_orig)
    jacL = ro_sview(mesh.jac, :, elnum_orig)
    res_i = sview(eqn.res, :, :, elnum_orig)

    computeDirichletDelta(capture, eqn.params, mesh.sbpface, bndry_i,
                          bc_func, entropy_vars, w_i, q_i, coords_i,
                          nrm_i, delta_w)

    applyDirichletPenalty(penalty, sbp, eqn.params, mesh.sbpface, diffusion,
                          bndry_i, delta_w, q_i, w_i, coords_i, nrm_i, alpha,
                          dxidxL, jacL, res1)

#    println("after pnealty, res1 = ", res1)
    # apply R^T to T_D * delta_w
    scale!(res1, -1)  # SAT has a - sign in front of it

    boundaryFaceInterpolate_rev!(mesh.sbpface, bndry_i.face, res_i, res1)
#    boundaryFaceInterpolate_rev!(mesh.sbpface, bndry_i.face, res_i, delta_w)

    # apply B and then Dgk^T to delta_w
    for j=1:mesh.numNodesPerFace
      for i=1:mesh.numDofPerNode
        delta_w[i, j] *= -mesh.sbpface.wface[j]  # the sat has a - sign in 
                                                 # front of it
      end
    end

    applyDgkTranspose(capture, sbp, eqn.params, mesh.sbpface, bndry_i,
                      diffusion, delta_w, q_i, w_i, coords_i, nrm_i, dxidxL,
                      jacL, res_i, op)  # the op is because the B_gamma has
                                        # a negative sign

#    println("after Dgk^T, res = ", res_i)
  end

  return nothing
end

"""
  Method to apply Dgk^T * t2L only.
"""
function applyDgkTranspose(capture::ParabolicReduceds{Tsol, Tres}, sbp,
                           params::ParamType,
                           sbpface, bndry::Union{Interface, Boundary},
                           diffusion::AbstractDiffusion,
                           t2L::AbstractMatrix,
                           qL::AbstractMatrix,
                           wL::AbstractMatrix,
                           coordsL::AbstractMatrix,
                           nrm_face::AbstractMatrix,
                           dxidxL::Abstract3DArray,
                           jacL::AbstractVector,
                           resL::AbstractMatrix,
                           op::SummationByParts.UnaryFunctor=SummationByParts.Add()) where {Tsol, Tres}

  dim, numNodesPerFace = size(nrm_face)
  numNodesPerElement = size(resL, 2)
  numDofPerNode = size(wL, 1)

  @unpack capture temp1L temp2L temp3L work
  fill!(temp2L, 0)

  # apply N and R^T
  @simd for d=1:dim
    @simd for j=1:numNodesPerFace
      @simd for k=1:numDofPerNode
        temp1L[k, j] =  nrm_face[d, j]*t2L[k, j]
      end
    end

    tmp2L = sview(temp2L, :, :, d);
    boundaryFaceInterpolate_rev!(sbpface, getFaceL(bndry), tmp2L, temp1L)
  end

  # multiply by D^T Lambda
  applyDiffusionTensor(diffusion, sbp, params, qL, wL, coordsL, dxidxL, jacL,
                       getElementL(bndry), temp2L, temp3L)

  applyDxTransposed(sbp, temp3L, dxidxL, jacL, work, resL, op)

  return nothing
end


"""
  Computes the difference between the solution at the face and the
  prescribed Dirichlet boundary condition.  Specifically, computes the
  difference between the entropy variables interpolated to the face
  and the Dirichlet state computed from the interpolated conservative
  variables (for consistency with the inviscid BC).

  This only works for boundary conditions that define `getDirichletState`.

  **Inputs**

   * capture
   * params
   * sbpface
   * bndry: `Boundary` object
   * bndry_node: `BoundaryNode` object
   * func: `BCType` for this boundary condition
   * entropy_vars: an [`AbstractVariables`](@ref) 
   * wL: entropy variables for the element, `numDofPerNode` x
         `numNodesPerElement`
   * qL: conservative variables for the element, same size as `wL`
   * coords: `dim` x `numNodesPerFace` array containing the xyz coordinates
             of the face nodes
   * nrm_face: `dim` x `numNodesPerFace` containing the normal vector at the
               face nodes (can be scaled or unscaled, `getDirichletState`
               should not care).
   
  **Inputs/Outputs**

   * delta_w: array to be overwritten with the result. `numDofPerNode` x
              `numNodesPerFace`
"""
function computeDirichletDelta(capture::ParabolicReduceds{Tsol, Tres},
                               params::ParamType,
                               sbpface::AbstractFace, bndry::Boundary,
                               func::BCType, entropy_vars::AbstractVariables,
                               wL::AbstractMatrix, qL::AbstractMatrix,
                               coords::AbstractMatrix, nrm_face::AbstractMatrix,
                               delta_w::AbstractMatrix
                              ) where {Tsol, Tres}

  numDofPerNode, numNodesPerFace = size(delta_w)
  numNodesPerElement = size(wL, 2)

  #TODO: maybe interpolating the conservative variables and then converting
  #      would be more consistent, but Eq. 31 requires the same interpolation
  #      Rgk * w for both the interface and the boundary term.
  #      For the boundary state qg we have more leeway because it is zero
  #      for the energy stability analysis (-> entropy stability when u = w)
  wface = zeros(Tsol, numDofPerNode, numNodesPerFace)
  boundaryFaceInterpolate!(sbpface, bndry.face, wL, wface)

  qface = zeros(Tsol, numDofPerNode, numNodesPerFace)
  qgface = zeros(Tres, numDofPerNode)
  wgface = zeros(Tres, numDofPerNode)
  aux_vars = Tres[]

  # the inviscid boundary conditions interpolate q to the face and then
  # compute qg, so do that here as well for consistency
  boundaryFaceInterpolate!(sbpface, bndry.face, qL, qface)
  for i=1:numNodesPerFace
    q_i = sview(qface, :, i)
    coords_i = sview(coords, :, i)
    nrm_i = sview(nrm_face, :, i)

    getDirichletState(func, params, q_i, aux_vars, coords_i, nrm_i, qgface)

    convertToEntropy(entropy_vars, params, qgface, wgface)
#    fill!(wgface, 0)  #TODO: undo this
#    println("wgface = ", wgface)

    # compute the delta
    for j=1:numDofPerNode
      delta_w[j, i] = wface[j, i] - wgface[j]  
    end
  end

  return nothing
end





#------------------------------------------------------------------------------
# penalty functions


"""
  Applies the penalty for the SBP-SAT generalization of the modified scheme
  of Bassi and Rebay (BR2).
"""
function applyReduced2Penalty(penalty::BR2Penalty{Tsol, Tres}, sbp, params::AbstractParamType,
                      sbpface,
                      diffusion::AbstractDiffusion, iface::Interface,
                      delta_w::AbstractMatrix{Tsol}, theta::AbstractMatrix{Tres},
                      qL_el::AbstractMatrix, qR_el::AbstractMatrix,
                      wL::AbstractMatrix, wR::AbstractMatrix,
                      coordsL::AbstractMatrix, coordsR::AbstractMatrix,
                      nrm_face::AbstractMatrix,
                      dxidxL::Abstract3DArray, dxidxR::Abstract3DArray,
                      jacL::AbstractVector, jacR::AbstractVector,
                      res1L::AbstractMatrix, res1R::AbstractMatrix,
                     ) where {Tsol, Tres}

  fill!(res1L, 0); fill!(res1R, 0)
  numDofPerNode, numNodesPerFace = size(delta_w)
  numNodesPerElement = length(jacL)
  dim = size(nrm_face, 1)

  @unpack penalty delta_w_n qL qR t1L t1R t2L t2R
  fill!(qL, 0); fill!(qR, 0)

  #--------------------------
  # apply T1
  # multiply by normal vector, then R^T B
  #alpha_g = 1/(dim + 1)  # = 1/number of faces of a simplex
  @simd for d1=1:dim
    @simd for j=1:numNodesPerFace
      @simd for k=1:numDofPerNode
        delta_w_n[k, j] = 0.25*delta_w[k, j]*nrm_face[d1, j]
      end
    end
    
    qL_d = sview(qL, :, :, d1); qR_d = sview(qR, :, :, d1)
    interiorFaceIntegrate!(sbpface, iface, delta_w_n, qL_d, qR_d)

    # interiorFaceIntegrates -= the second output
    @simd for j=1:numNodesPerElement
      @simd for k=1:numDofPerNode
        qR_d[k, j] = -qR_d[k, j]
      end
    end
  end

  # apply Lambda matrix
  applyDiffusionTensor(diffusion, sbp, params, qL_el, wL, coordsL, dxidxL, jacL, iface.elementL, sbpface, iface.faceL,
                       qL, t1L)
  applyDiffusionTensor(diffusion, sbp, params, qR_el, wR, coordsR, dxidxR, jacR, 
                       iface.elementR, sbpface, iface.faceR,
                       qR, t1R)

  # apply inverse mass matrix, then apply B*Nx*R*t2L_x + B*Ny*R*t2L_y
  @simd for d1=1:dim
    @simd for j=1:numNodesPerElement
      facL = jacL[j]/sbp.w[j]
      facR = jacR[j]/sbp.w[j]
      #facL = (3)*jacL[j]/sbp.w[j]
      #facR = (3)*jacR[j]/sbp.w[j]

      @simd for k=1:numDofPerNode
        t1L[k, j, d1] *= facL
        t1R[k, j, d1] *= facR
      end
    end

    #TODO: make t2L 2D rather than 3D
    t1L_d = ro_sview(t1L, :, :, d1); t1R_d = ro_sview(t1R, :, :, d1)
    t2L_d = sview(t2L, :, :, d1);    t2R_d = sview(t2R, :, :, d1)
    interiorFaceInterpolate!(sbpface, iface, t1L_d, t1R_d, t2L_d, t2R_d)

    @simd for j=1:numNodesPerFace
      @simd for k=1:numDofPerNode
        val = sbpface.wface[j]*nrm_face[d1, j]*(t2L_d[k, j] + t2R_d[k, j])
        res1L[k, j] += val
        res1R[k, j] -= val  # delta_w is reversed for elementR
      end
    end

  end  # end d1

#=
  #----------------------------
  # apply T2 and T3
  @simd for j=1:numNodesPerFace
    @simd for k=1:numDofPerNode
      val1 =  0.5*sbpface.wface[j]*theta[k, j]
      val2 = -0.5*sbpface.wface[j]*delta_w[k, j]
      res1L[k, j] += val1
      res1R[k, j] += val1
      res2L[k, j] += val2
      res2R[k, j] -= val2  # delta_w is reversed for elementR
    end
  end
=#
  return nothing
end


