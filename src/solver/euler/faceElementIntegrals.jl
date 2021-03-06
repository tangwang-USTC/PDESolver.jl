# functions that do face integral-like operations, but operate on data from
# the entire element


# naming convention
# EC -> entropy conservative
# ES -> entropy stable (ie. dissipative)
# LF -> Lax-Friedrich
# LW -> Lax-Wendroff
#
# so for example, ESLFFaceIntegral is an entropy stable face integral function
# that uses Lax-Friedrich type dissipation

#-----------------------------------------------------------------------------
# entry point functions
"""
  Calculate the face integrals in an entropy conservative manner for a given
  interface.  Unlike standard face integrals, this requires data from
  the entirety of both elements, not just data interpolated to the face

  resL and resR are updated with the results of the computation for the 
  left and right elements, respectively.

  Note that nrm_xy must contains the normal vector in x-y space at the
  face nodes.

  The flux function must be symmetric!

  **Inputs**

   * `params`: `AbstractParamType`
   * `sbpface`: an `AbstractFace`.  Methods are available for both sparse
              and dense faces
   * `iface`: the [`Interface`](@ref) object for the given face
   * `qL`: the solution at the volume nodes of the left element (`numDofPerNode`
     x `numNodesPerElement)
   * `qR`: the solution at the volume nodes of the right element
   * `aux_vars`: the auxiliary variables for `qL`
   * `nrm_xy`: the normal vector at each face node, `dim` x `numNodesPerFace`
   * `functor: the flux function, of type [`FluxType`](@ref)
   

  **Inputs/Outputs**

   * `resL`: the residual of the left element to be updated (not overwritten)
             with the result, same shape as `qL`
   * `resR`: the residual of the right element to be updated (not overwritten)
             with the result, same shape as `qR`

  Aliasing restrictions: none, although its unclear what the meaning of this
                         function would be if resL and resR alias

  Performance note: the version in the tests is the same speed as this one
                    for p=1 Omega elements and about 10% faster for 
                    p=4 elements, but would not be able to take advantage of 
                    the sparsity of R for SBP Gamma elements
"""
function calcECFaceIntegral(
     params::AbstractParamType{Tdim}, 
     sbpface::DenseFace, 
     iface::Interface,
     qL::AbstractMatrix{Tsol}, 
     qR::AbstractMatrix{Tsol}, 
     aux_vars::AbstractMatrix{Tres}, 
     nrm_xy::AbstractMatrix{Tmsh},
     functor::FluxType, 
     resL::AbstractMatrix{Tres}, 
     resR::AbstractMatrix{Tres}) where {Tdim, Tsol, Tres, Tmsh}


  data = params.calc_ec_face_integral_data
  @unpack data fluxD nrmD
  numDofPerNode = size(fluxD, 1)

  fill!(nrmD, 0.0)
  for d=1:Tdim
    nrmD[d, d] = 1
  end

  # loop over the nodes of "left" element that are in the stencil of interp
  for i = 1:sbpface.stencilsize
    p_i = sbpface.perm[i, iface.faceL]
    qi = ro_sview(qL, :, p_i)
    aux_vars_i = ro_sview(aux_vars, :, p_i)  # !!!! why no aux_vars_j???

    # loop over the nodes of "right" element that are in the stencil of interp
    for j = 1:sbpface.stencilsize
      p_j = sbpface.perm[j, iface.faceR]
      qj = ro_sview(qR, :, p_j)

      # compute flux and add contribution to left and right elements
      functor(params, qi, qj, aux_vars_i, nrmD, fluxD)

      @simd for dim = 1:Tdim  # move this inside the j loop, at least
        # accumulate entry p_i, p_j of E
        Eij = zero(Tres)  # should be Tres
        @simd for k = 1:sbpface.numnodes
          # the computation of nrm_k could be moved outside i,j loops and saved
          # in an array of size [3, sbp.numnodes]
          nrm_k = nrm_xy[dim, k]
          kR = sbpface.nbrperm[k, iface.orient]
          Eij += sbpface.interp[i,k]*sbpface.interp[j,kR]*sbpface.wface[k]*nrm_k
        end  # end loop k
 
       
        @simd for p=1:numDofPerNode
          resL[p, p_i] -= Eij*fluxD[p, dim]
          resR[p, p_j] += Eij*fluxD[p, dim]
        end

      end  # end loop dim
    end  # end loop j
  end  # end loop i


  return nothing
end


"""
  Calculate the face integal in an entropy conservative manner and also
  computes an entropy dissipative penalty.

  Uses [`calcECFaceIntegral`](@ref) and [`calcEntropyPenaltyIntegral`](@ref),
  see those functions for details.

  **Inputs**

   * `params`: `AbstractParamType`
   * `sbpface`: an `AbstractFace`.  Methods are available for both sparse
              and dense faces
   * `iface`: the [`Interface`](@ref) object for the given face
   * `kernel`: an [`AbstractEntropyKernel`](@ref) specifying what kind of
               dissipation to apply.
   * `qL`: the solution at the volume nodes of the left element (`numDofPerNode`
     x `numNodesPerElement)
   * `qR`: the solution at the volume nodes of the right element
   * `aux_vars`: the auxiliary variables for `qL`
   * `nrm_xy`: the normal vector at each face node, `dim` x `numNodesPerFace`
   * `functor: the flux function, of type [`FluxType`](@ref)
   

  **Inputs/Outputs**

   * `resL`: the residual of the left element to be updated (not overwritten)
             with the result, same shape as `qL`
   * `resR`: the residual of the right element to be updated (not overwritten)
             with the result, same shape as `qR`

"""
function calcESFaceIntegral(
     params::AbstractParamType{Tdim}, 
     sbpface::AbstractFace, 
     iface::Interface,
     kernel::AbstractEntropyKernel,
     qL::AbstractMatrix{Tsol}, 
     qR::AbstractMatrix{Tsol}, 
     aux_vars::AbstractMatrix{Tres}, 
     nrm_face::AbstractMatrix{Tmsh},
     functor::FluxType, 
     resL::AbstractMatrix{Tres}, 
     resR::AbstractMatrix{Tres}) where {Tdim, Tsol, Tres, Tmsh}

  calcECFaceIntegral(params, sbpface, iface, qL, qR, aux_vars, nrm_face, 
                     functor, resL, resR)
  calcEntropyPenaltyIntegral(params, sbpface, iface, kernel, qL, qR, aux_vars, 
                               nrm_face, resL, resR)

  return nothing
end


#-----------------------------------------------------------------------------
# Internal functions that calculate the penalties

"""
  Calculate a term that provably dissipates (mathematical) entropy using a 
  Lax-Friedrich type of dissipation.  
  This
  requires data from the left and right element volume nodes, rather than
  face nodes for a regular face integral.

  Note that nrm_face must contain the scaled face normal vector in x-y space
  at the face nodes, and qL, qR, resL, and resR are the arrays for the
  entire element, not just the face.

  **Inputs**

   * `params`: `AbstractParamType`
   * `sbpface`: an `AbstractFace`.  Methods are available for both sparse
              and dense faces
   * `iface`: the [`Interface`](@ref) object for the given face
   * `kernel`: an [`AbstractEntropyKernel`](@ref) specifying what kind of
               dissipation to apply.
   * `qL`: the solution at the volume nodes of the left element (`numDofPerNode`
     x `numNodesPerElement)
   * `qR`: the solution at the volume nodes of the right element
   * `aux_vars`: the auxiliary variables for `qL`
   * `nrm_xy`: the normal vector at each face node, `dim` x `numNodesPerFace`
   

  **Inputs/Outputs**

   * `resL`: the residual of the left element to be updated (not overwritten)
             with the result, same shape as `qL`
   * `resR`: the residual of the right element to be updated (not overwritten)
             with the result, same shape as `qR`
"""
function calcEntropyPenaltyIntegral(
             params::ParamType{Tdim, :conservative},
             sbpface::DenseFace, iface::Interface,
             kernel::AbstractEntropyKernel,
             qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
             aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractArray{Tmsh, 2},
             resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tdim, Tsol, Tres, Tmsh}

  numDofPerNode = size(qL, 1)

  # convert qL and qR to entropy variables (only the nodes that will be used)
  data = params.calc_entropy_penalty_integral_data
  @unpack data wL wR wL_i wR_i qL_i qR_i delta_w q_avg flux

  # convert to IR entropy variables
  for i=1:sbpface.stencilsize
    # apply sbpface.perm here
    p_iL = sbpface.perm[i, iface.faceL]
    p_iR = sbpface.perm[i, iface.faceR]
    # these need to have different names from qL_i etc. below to avoid type
    # instability
    qL_itmp = ro_sview(qL, :, p_iL)
    qR_itmp = ro_sview(qR, :, p_iR)
    wL_itmp = sview(wL, :, i)
    wR_itmp = sview(wR, :, i)
    convertToIR(params, qL_itmp, wL_itmp)
    convertToIR(params, qR_itmp, wR_itmp)
  end



  # accumulate wL at the node
  @simd for i=1:sbpface.numnodes  # loop over face nodes
    ni = sbpface.nbrperm[i, iface.orient]
    dir = ro_sview(nrm_face, :, i)
    fastzero!(wL_i)
    fastzero!(wR_i)

    # interpolate wL and wR to this node
    @simd for j=1:sbpface.stencilsize
      interpL = sbpface.interp[j, i]
      interpR = sbpface.interp[j, ni]

      @simd for k=1:numDofPerNode
        wL_i[k] += interpL*wL[k, j]
        wR_i[k] += interpR*wR[k, j]
      end
    end

    #TODO: write getLambdaMaxSimple and getIRA0 in terms of the entropy
    #      variables to avoid the conversion
    convertToConservativeFromIR_(params, wL_i, qL_i)
    convertToConservativeFromIR_(params, wR_i, qR_i)
    
    # compute average qL
    # also delta w (used later)
    @simd for j=1:numDofPerNode
      q_avg[j] = 0.5*(qL_i[j] + qR_i[j])
      delta_w[j] = wL_i[j] - wR_i[j]
    end

    # call kernel (apply symmetric semi-definite matrix)
    applyEntropyKernel(kernel, params, q_avg, delta_w, dir, flux)
    for j=1:numDofPerNode
      flux[j] *= sbpface.wface[i]
    end

    # interpolate back to volume nodes
    @simd for j=1:sbpface.stencilsize
      j_pL = sbpface.perm[j, iface.faceL]
      j_pR = sbpface.perm[j, iface.faceR]

      @simd for p=1:numDofPerNode
        resL[p, j_pL] -= sbpface.interp[j, i]*flux[p]
        resR[p, j_pR] += sbpface.interp[j, ni]*flux[p]
      end
    end

  end  # end loop i

  return nothing
end


"""
  This function modifies the eigenvalues of the euler flux jacobian such
  that if any value is zero, a little dissipation is still added.  The
  absolute values of the eigenvalues modified eigenvalues are calculated.

  Methods are available for 2 and 3 dimensions

  This function depends on the ordering of the eigenvalues produced by
  calcEvals.

  Inputs:
    params: ParamType, used to dispatch to 2 or 3D method

  Inputs/Outputs:
    Lambda: vector of eigenvalues to be modified

  Aliasing restrictions: none
"""
function calcEntropyFix(params::ParamType{2}, Lambda::AbstractVector)
  
  # entropy fix parameters
  sat_Vn = 0.025
  sat_Vl = 0.05


  # this is dependent on the ordering of the eigenvalues produced
  # by calcEvals
  lambda3 = Lambda[2]  # Un
  lambda4 = Lambda[3]  # Un + a
  lambda5 = Lambda[4]  # Un - a


  # if any eigenvalue is zero, introduce dissipation that is a small
  # fraction of the maximum eigenvalue
  rhoA = max(absvalue(lambda4), absvalue(lambda5))  # absvalue(Un) + a
  lambda3 = max( absvalue(lambda3), sat_Vl*rhoA)
  lambda4 = max( absvalue(lambda4), sat_Vn*rhoA)
  lambda5 = max( absvalue(lambda5), sat_Vn*rhoA)

  Lambda[1] = lambda3
  Lambda[2] = lambda3
  Lambda[3] = lambda4
  Lambda[4] = lambda5
  
  return nothing
end

function calcEntropyFix(params::ParamType{3}, Lambda::AbstractVector)
  
  # entropy fix parameters
  sat_Vn = 0.025
  sat_Vl = 0.05


  # this is dependent on the ordering of the eigenvalues produced
  # by calcEvals
  lambda3 = Lambda[3]  # Un
  lambda4 = Lambda[4]  # Un + a
  lambda5 = Lambda[5]  # Un - a


  # if any eigenvalue is zero, introduce dissipation that is a small
  # fraction of the maximum eigenvalue
  rhoA = max(absvalue(lambda4), absvalue(lambda5))  # absvalue(Un) + a
  lambda3 = max( absvalue(lambda3), sat_Vl*rhoA)
  lambda4 = max( absvalue(lambda4), sat_Vn*rhoA)
  lambda5 = max( absvalue(lambda5), sat_Vn*rhoA)

  Lambda[1] = lambda3
  Lambda[2] = lambda3
  Lambda[3] = lambda3
  Lambda[4] = lambda4
  Lambda[5] = lambda5
  
  return nothing
end


#------------------------------------------------------------------------------
# Create separate kernel functions for each entropy penatly (LF, LW, etc)


"""
  Applies a Lax-Wendroff type dissipation kernel.  The intend is to apply

  Y^T |Lambda| Y delta_w

  **Inputs**

   * obj: an [`AbstractEntropyKernel`](@ref)
   * params: a `ParamType`
   * q_avg: the state at which to calculate the dissipation (conservative
            variables)
   * delta_w: vector to multiply the dissipation matrix against
   * nrm_in: normal vector in face-normal direction (scaled)

  **Inputs/Outputs**

   * flux: vector to overwrite with the result
"""
function applyEntropyKernel(obj::LW2Kernel, params::ParamType, 
                            q_avg::AbstractVector, delta_w::AbstractVector,
                            nrm_in::AbstractVector, flux::AbstractVector)

  # unpack fields
  nrm = obj.nrm
  P = obj.P
  Y = obj.Y
  Lambda = obj.Lambda
  S2 = obj.S2
  q_tmp = obj.q_tmp
  tmp1 = obj.tmp1
  tmp2 = obj.tmp2

  Tdim = length(nrm_in)
  numDofPerNode = length(q_avg)

  # normalize direction vector
  len_fac = calcLength(params, nrm_in)
  for dim=1:Tdim
    nrm[dim] = nrm_in[dim]/len_fac
  end

  # project q into n-t coordinate system
  #TODO: verify this is equivalent to computing the eigensystem in the
  #      face normal direction (including a non-unit direction vector)
  getProjectionMatrix(params, nrm, P)
  projectToNT(params, P, q_avg, q_tmp)  # q_tmp is qprime

  # get eigensystem in the normal direction, which is equivalent to
  # the x direction now that q has been rotated
  calcEvecsx(params, q_tmp, Y)
  calcEvalsx(params, q_tmp, Lambda)
  calcEScalingx(params, q_tmp, S2)

#    calcEntropyFix(params, Lambda)

  # compute LF term in n-t coordinates, then rotate back to x-y
  projectToNT(params, P, delta_w, tmp1)
  smallmatTvec!(Y, tmp1, tmp2)
  # multiply by diagonal Lambda and S2, also include the scalar
  # wface and len_fac components
  for j=1:length(tmp2)
    tmp2[j] *= len_fac*absvalue(Lambda[j])*S2[j]
  end
  smallmatvec!(Y, tmp2, tmp1)
  projectToXY(params, P, tmp1, flux)

  return nothing
end



"""
  Applies a Lax-Friedrich type entropy dissipation operation, ie.

  |lambda_max| * Y * Y^T * delta_w

  where Y are the eigenvalues of the flux jacobian and Y * Y^T = A0, ie.
  du/dw, where u are the conservative variables and are the IR entropy variables

"""
function applyEntropyKernel(obj::LFKernel, params::ParamType, 
                            q_avg::AbstractVector, delta_w::AbstractVector,
                            nrm::AbstractVector, flux::AbstractVector)


  A0 = obj.A0
  getIRA0(params, q_avg, A0)

  lambda_max = getLambdaMax(params, q_avg, nrm)
  # lambda_max * A0 * delta w
  smallmatvec!(A0, delta_w, flux)
  fastscale!(flux, lambda_max)

end


"""
  Use the identity matrix, ie. flux = delta_w
"""
function applyEntropyKernel(obj::IdentityKernel, params::ParamType, 
                            q_avg::AbstractVector, delta_w::AbstractVector,
                            nrm::AbstractVector, flux::AbstractVector)

  for i=1:length(flux)
    flux[i] = delta_w[i]
  end

  return nothing
end



#------------------------------------------------------------------------------
# Functions to apply entropy kernels for diagonal E operators (ie. as part of
# a regular flux function

"""
  This function applies any [`AbstractEntropyKernel`](@ref) when defining
  a type 1 face integral (the normal type) for an entropy-stable scheme
  using a diagonal E operator.

  **Inputs**

   * params: ParamType
   * kernel: the `AbstractEntropyKernel` to apply
   * qL: solution at left state
   * qR: solution at right state
   * aux_vars: auxiliary varialbes
   * dir: normal vector

  **Inputs/Outputs**

   * F: flux vector to have the entropy kernel contribution added to (well,
        subtracted because the contribution is negative).
"""
function applyEntropyKernel_diagE(
                      params::ParamType{Tdim, :conservative},
                      kernel::AbstractEntropyKernel,
                      qL::AbstractArray{Tsol,1}, qR::AbstractArray{Tsol, 1},
                      aux_vars::AbstractArray{Tres},
                      dir::AbstractArray{Tmsh},  F::AbstractArray{Tres,1}) where {Tmsh, Tsol, Tres, Tdim}

   q_avg = params.apply_entropy_kernel_diagE_data.q_avg
  for i=1:length(q_avg)
    q_avg[i] = 0.5*(qL[i] + qR[i])
  end

  applyEntropyKernel_diagE_inner(params, kernel, qL, qR, q_avg, aux_vars, dir, F)

  return nothing
end



"""
  Applies the specified [`AbstractEntropyKernel`](@ref)

  **Inputs**

   * params
   * kernel: the kernel to apply
   * qL: left state
   * qR: right state
   * q_avg: the state at which to evaluate the kernel
   * aux_vars
   * dir: normal vector
 
  **Inputs/Outputs**

   * F: flux vector to update with contribtion
"""
function applyEntropyKernel_diagE_inner(
                      params::ParamType{Tdim, :conservative}, 
                      kernel::AbstractEntropyKernel,
                      qL::AbstractArray{Tsol,1}, qR::AbstractArray{Tsol, 1},
                      q_avg::AbstractArray{Tsol}, aux_vars::AbstractArray{Tres},
                      dir::AbstractArray{Tmsh},
                      F::AbstractArray{Tres,1}) where {Tmsh, Tsol, Tres, Tdim}
#  println("entered getEntropyLFStab_inner")

  @unpack params.apply_entropy_kernel_diagE_data vL vR F_tmp
  gamma = params.gamma
  gamma_1inv = 1/params.gamma_1
#  p = calcPressure(params, q_avg)

  convertToIR(params, qL, vL)
  convertToIR(params, qR, vR)

  for i=1:length(vL)
    vL[i] = vL[i] - vR[i]
  end

#  F_tmp = zeros(Tres, length(F))
  applyEntropyKernel(kernel, params, q_avg, vL, dir, F_tmp)

  for i=1:length(F_tmp)
    F[i] += F_tmp[i]
  end

  return nothing
end



#-----------------------------------------------------------------------------
# do the functor song and dance


"""
  Entropy conservative term only
"""
mutable struct ECFaceIntegral <: FaceElementIntegralType
end

function ECFaceIntegral(mesh::AbstractMesh, eqn::EulerData)
  return ECFaceIntegral()
end

function calcFaceElementIntegral(obj::ECFaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}


  calcECFaceIntegral(params, sbpface, iface, qL, qR, aux_vars, nrm_face, 
                      functor, resL, resR)

end


"""
  Entropy conservative integral + Lax-Friedrich penalty
"""
mutable struct ESLFFaceIntegral{Tsol, Tres, Tmsh} <: FaceElementIntegralType
  kernel::LFKernel{Tsol, Tres, Tmsh}
end

function ESLFFaceIntegral(mesh::AbstractMesh{Tmsh}, eqn::EulerData{Tsol, Tres}) where {Tsol, Tres, Tmsh}
  return ESLFFaceIntegral{Tsol, Tres, Tmsh}(LFKernel{Tsol, Tres, Tmsh}(mesh.numDofPerNode, 2*mesh.numDofPerNode))
end

function calcFaceElementIntegral(obj::ESLFFaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}


  calcESFaceIntegral(params, sbpface, iface, obj.kernel, qL, qR, aux_vars, nrm_face, functor, resL, resR)

end

"""
  Lax-Friedrich entropy penalty term only
"""
mutable struct ELFPenaltyFaceIntegral{Tsol, Tres, Tmsh} <: FaceElementIntegralType
  kernel::LFKernel{Tsol, Tres, Tmsh}
end

function ELFPenaltyFaceIntegral(mesh::AbstractMesh{Tmsh}, eqn::EulerData{Tsol, Tres}) where {Tsol, Tres, Tmsh}
  return ELFPenaltyFaceIntegral{Tsol, Tres, Tmsh}(LFKernel{Tsol, Tres, Tmsh}(mesh.numDofPerNode, 2*mesh.numDofPerNode))
end

function calcFaceElementIntegral(obj::ELFPenaltyFaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}


  calcEntropyPenaltyIntegral(params, sbpface, iface, obj.kernel, qL, qR, aux_vars, nrm_face, resL, resR)

end


"""
  Entropy conservative integral + Lax-Wendroff penalty
"""
mutable struct ESLW2FaceIntegral{Tsol, Tres, Tmsh} <: FaceElementIntegralType
  kernel::LW2Kernel{Tsol, Tres, Tmsh}

end

function ESLW2FaceIntegral(mesh::AbstractMesh{Tmsh}, eqn::EulerData{Tsol, Tres}) where {Tsol, Tres, Tmsh}
  kernel = LW2Kernel{Tsol, Tres, Tmsh}(mesh.numDofPerNode, mesh.dim)
  return ESLW2FaceIntegral{Tsol, Tres, Tmsh}(kernel)
end

function calcFaceElementIntegral(obj::ESLW2FaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}

  calcESFaceIntegral(params, sbpface, iface, obj.kernel, qL, qR, aux_vars, nrm_face, functor, resL, resR)

end

"""
  Lax-Wendroff entropy penalty term only
"""
mutable struct ELW2PenaltyFaceIntegral{Tsol, Tres, Tmsh} <: FaceElementIntegralType
  kernel::LW2Kernel{Tsol, Tres, Tmsh}

end

function ELW2PenaltyFaceIntegral(mesh::AbstractMesh{Tmsh}, eqn::EulerData{Tsol, Tres}) where {Tsol, Tres, Tmsh}

  kernel = LW2Kernel{Tsol, Tres, Tmsh}(mesh.numDofPerNode, mesh.dim)
  return ELW2PenaltyFaceIntegral{Tsol, Tres, Tmsh}(kernel)
end

function calcFaceElementIntegral(obj::ELW2PenaltyFaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}


  calcEntropyPenaltyIntegral(params, sbpface, iface, obj.kernel, qL, qR, aux_vars, nrm_face, resL, resR)

end


mutable struct EntropyJumpPenaltyFaceIntegral{Tsol, Tres, Tmsh} <: FaceElementIntegralType
  kernel::IdentityKernel{Tsol, Tres, Tmsh}

end

function EntropyJumpPenaltyFaceIntegral(mesh::AbstractMesh{Tmsh}, eqn::EulerData{Tsol, Tres}) where {Tsol, Tres, Tmsh}
  kernel = IdentityKernel{Tsol, Tres, Tmsh}()
  return EntropyJumpPenaltyFaceIntegral{Tsol, Tres, Tmsh}(kernel)
end

function calcFaceElementIntegral(obj::EntropyJumpPenaltyFaceIntegral,
              params::AbstractParamType{Tdim}, 
              sbpface::AbstractFace, iface::Interface,
              qL::AbstractMatrix{Tsol}, qR::AbstractMatrix{Tsol}, 
              aux_vars::AbstractMatrix{Tres}, nrm_face::AbstractMatrix{Tmsh},
              functor::FluxType, 
              resL::AbstractMatrix{Tres}, resR::AbstractMatrix{Tres}) where {Tsol, Tres, Tmsh, Tdim}


  calcEntropyPenaltyIntegral(params, sbpface, iface, obj.kernel, qL, qR, aux_vars, nrm_face, resL, resR)

end



global const FaceElementDict = Dict{String, Type{T} where T <: FaceElementIntegralType}(
"ECFaceIntegral" => ECFaceIntegral,
"ELFPenaltyFaceIntegral" => ELFPenaltyFaceIntegral,
"ESLFFaceIntegral" => ESLFFaceIntegral,
"ELW2PenaltyFaceIntegral" => ELW2PenaltyFaceIntegral,
"ESLW2FaceIntegral" => ESLW2FaceIntegral,
"EntropyJumpPenaltyFaceIntegral" => EntropyJumpPenaltyFaceIntegral,
)

"""
  Populates the field(s) of the EulerData object with
  [`FaceElementIntegralType`](@ref) functors as specified by the options
  dictionary

  **Inputs**

   * mesh: an AbstractMesh
   * sbp: an SBP operator
   * opts: the options dictionary

  **Inputs/Outputs**

   * eqn: the EulerData object
"""
function getFaceElementFunctors(mesh::AbstractMesh{Tmsh}, sbp, eqn::AbstractEulerData{Tsol, Tres}, opts) where {Tsol, Tres, Tmsh}

  objname = opts["FaceElementIntegral_name"]
  Tobj = FaceElementDict[objname]
  eqn.face_element_integral_func = Tobj(mesh, eqn)

  assertFieldsConcrete(eqn.face_element_integral_func)

  return nothing
end


include("IR_stab.jl")  # stabilization for the IR flux
include("faceElementIntegrals_diff.jl")


