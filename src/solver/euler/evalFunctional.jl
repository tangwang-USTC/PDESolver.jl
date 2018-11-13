# evaluating EntropyPenaltyFunctionals

#------------------------------------------------------------------------------
# API functions

import PDESolver._evalFunctionalDeriv_m

"""
  Evaluates [`EntropyPenaltyFunctional`](@ref)s

  Note that this function may overwrite eqn.res.
"""
function _evalFunctional(mesh::AbstractMesh{Tmsh},
            sbp::AbstractSBP, eqn::EulerData{Tsol, Tres}, opts,
            functionalData::EntropyPenaltyFunctional) where {Tmsh, Tsol, Tres}

  val = calcFunctional(mesh, sbp, eqn, opts, functionalData)
  val = MPI.Allreduce(val, MPI.SUM, eqn.comm)

  return val
end


# derivative of functional wrt q
function _evalFunctionalDeriv_q(mesh::AbstractDGMesh{Tmsh}, 
                           sbp::AbstractSBP,
                           eqn::EulerData{Tsol, Tres}, opts,
                           functionalData::EntropyPenaltyFunctional,
                           func_deriv_arr::Abstract3DArray) where {Tmsh, Tsol, Tres}

  @assert eqn.commsize == 1

  # this is a trick to populate eqn.res (the forward sweep of reverse mode)
  calcFunctional(mesh, sbp, eqn, opts, functionalData)

  # compute reverse mode of the contraction, take val_bar = 1
  w_j = zeros(Tsol, mesh.numDofPerNode)
  w_bar_j = zeros(Tres, mesh.numDofPerNode)
  fill!(eqn.res_bar, 0); fill!(eqn.q_bar, 0)
  A0inv = zeros(Tsol, mesh.numDofPerNode, mesh.numDofPerNode)

  for i=1:mesh.numEl
    for j=1:mesh.numNodesPerElement
      q_j = sview(eqn.q, :, j, i)
      q_bar_j = sview(eqn.q_bar, :, j, i)
      fill!(w_bar_j, 0)
      convertToIR(eqn.params, q_j, w_j)
      for k=1:mesh.numDofPerNode
        #val += w_j[k]*eqn.res[k, j, i]
        #-----------------------------
        # reverse sweep
        w_bar_j[k] += eqn.res[k, j, i]
        eqn.res_bar[k, j, i] += w_j[k]
      end

      getIRA0inv(eqn.params, q_j, A0inv)
      smallmatTvec_kernel!(A0inv, w_bar_j, q_bar_j, 1, 1)
    end
  end


  # do reverse mode of the face integrals
  if typeof(mesh.sbpface) <: DenseFace
    @assert opts["parallel_data"] == "element"

    # local part
    face_integral_functor = functionalData.func
    flux_functor = ErrorFlux_revq()  # not used, but required by the interface
    getFaceElementIntegral_revq(mesh, sbp, eqn, face_integral_functor, flux_functor, mesh.sbpface, mesh.interfaces)
 
    #TODO: parallel part
  else # SparseFace
    flux_functor_revq = functionalData.func_sparseface_revq
    calcFaceIntegral_nopre_revq(mesh, sbp, eqn, opts, flux_functor_revq,
                                mesh.interfaces)
    #TODO: parallel part
  end

  copy!(func_deriv_arr, eqn.q_bar)

  return nothing
end



function _evalFunctionalDeriv_m(mesh::AbstractDGMesh{Tmsh}, 
                           sbp::AbstractSBP,
                           eqn::AbstractSolutionData{Tsol}, opts,
                           functionalData::EntropyPenaltyFunctional
                           ) where {Tmsh, Tsol}

  @assert eqn.commsize == 1

  # compute reverse mode of the contraction, take val_bar = 1
  w_j = zeros(Tsol, mesh.numDofPerNode)
  fill!(eqn.res_bar, 0);

  for i=1:mesh.numEl
    for j=1:mesh.numNodesPerElement
      q_j = sview(eqn.q, :, j, i)
      convertToIR(eqn.params, q_j, w_j)
      for k=1:mesh.numDofPerNode
        #val += w_j[k]*eqn.res[k, j, i]
        #-----------------------------
        # reverse sweep
        eqn.res_bar[k, j, i] += w_j[k]
      end
    end
  end


  # do reverse mode of the face integrals
  if typeof(mesh.sbpface) <: DenseFace
    @assert opts["parallel_data"] == "element"

    # local part
    face_integral_functor = functionalData.func
    flux_functor = ErrorFlux()  # not used, but required by the interface
    getFaceElementIntegral_revm(mesh, sbp, eqn, face_integral_functor, flux_functor, mesh.sbpface, mesh.interfaces)
 
    #TODO: parallel part
  else # SparseFace
    flux_functor_revm = functionalData.func_sparseface_revm
    calcFaceIntegral_nopre_revm(mesh, sbp, eqn, opts, flux_functor_revm,
                                mesh.interfaces)
    #TODO: parallel part
  end

  return nothing
end


#------------------------------------------------------------------------------
# Implementation for each functional

function calcFunctional(mesh::AbstractMesh{Tmsh},
            sbp::AbstractSBP, eqn::EulerData{Tsol, Tres}, opts,
            functionalData::EntropyPenaltyFunctional) where {Tmsh, Tsol, Tres}


  fill!(eqn.res, 0.0)
  # use functions called from evalResidual to compute the dissipation, then
  # contract it with the entropy variables afterwards

  if typeof(mesh.sbpface) <: DenseFace
    @assert opts["parallel_data"] == "element"

    # local part
    face_integral_functor = functionalData.func
    flux_functor = ErrorFlux()  # not used, but required by the interface
    getFaceElementIntegral(mesh, sbp, eqn, face_integral_functor, flux_functor, mesh.sbpface, mesh.interfaces)
 
    # parallel part

    # temporarily change the face integral functor
    face_integral_functor_orig = eqn.face_element_integral_func
    eqn.face_element_integral_func = face_integral_functor

    # finish data exchange/do the shared face integrals
    # this works even if the receives have already been waited on
    finishExchangeData(mesh, sbp, eqn, opts, eqn.shared_data, calcSharedFaceElementIntegrals_element)

    # restore eqn object to original state
    eqn.face_element_integral_func = face_integral_functor_orig
  else  # SparseFace
    flux_functor = functionalData.func_sparseface
    calcFaceIntegral_nopre(mesh, sbp, eqn, opts, flux_functor, mesh.interfaces)

    # parallel part

    # figure out which paralle function to call
    if opts["parallel_data"] == "face"
      pfunc = (mesh, sbp, eqn, opts, data) -> calcSharedFaceIntegrals_nopre_inner(mesh, sbp, eqn, opts, data, flux_functor)
    elseif opts["paralle_data"] == "element"
      pfunc = (mesh, sbp, eqn, opts, data) -> calcSharedFaceIntegrals_nopre_elemen_inner(mesh, sbp, eqn, opts, data, flux_functor)
    else
      error("unregonized parallel data: $(opts["parallel_data"])")
    end

    # do shared face integrals
    finishExchangeData(mesh, sbp, eqn, opts, eqn.shared_data, pfunc)
  end

  # compute the contraction
  val = zero(Tres)
  w_j = zeros(Tsol, mesh.numDofPerNode)
  for i=1:mesh.numEl
    for j=1:mesh.numNodesPerElement
      q_j = sview(eqn.q, :, j, i)
      convertToIR(eqn.params, q_j, w_j)
      for k=1:mesh.numDofPerNode
        val += w_j[k]*eqn.res[k, j, i]
      end
    end
  end


  return val
end
