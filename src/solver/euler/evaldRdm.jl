function evaldRdm_transposeproduct(mesh::AbstractMesh, sbp::AbstractSBP, eqn::EulerData, 
                     opts::Dict, t=0.0, input_array::AbstractArray{Tsol, 1})

  disassembleSolution(mesh, sbp, eqn, opts, eqn.res_bar, input_array)

  time = eqn.params.time
  eqn.params.t = t  # record t to params
  myrank = mesh.myrank

#  println("entered evalResidual")
#  println("q1319-3 = ", eqn.q[:, 3, 1319])

  #=
  time.t_send += @elapsed if opts["parallel_type"] == 1
    println(eqn.params.f, "starting data exchange")

    startDataExchange(mesh, opts, eqn.q,  eqn.q_face_send, eqn.q_face_recv, eqn.params.f)
  end
   =#

  # !!!! MAKE SURE TO DO DATA EXCHANGE BEFORE !!!!

  # Forward sweep
  time.t_dataprep += @elapsed dataPrep(mesh, sbp, eqn, opts)


  time.t_volume += @elapsed if opts["addVolumeIntegrals"]
    evalVolumeIntegrals_dRdm(mesh, sbp, eqn, opts)
  end

  if opts["use_GLS"]
    println("adding boundary integrals")
    GLS(mesh,sbp,eqn)
  end
  
  time.t_bndry += @elapsed if opts["addBoundaryIntegrals"]
   evalBoundaryIntegrals_dRdm(mesh, sbp, eqn)
   #println("boundary integral @time printed above")
  end


  time.t_stab += @elapsed if opts["addStabilization"]
    addStabilization(mesh, sbp, eqn, opts)
  end

  time.t_face += @elapsed if mesh.isDG && opts["addFaceIntegrals"]
    evalFaceIntegrals(mesh, sbp, eqn, opts)
  end

  time.t_sharedface += @elapsed if mesh.commsize > 1
    evalSharedFaceIntegrals(mesh, sbp, eqn, opts)
  end

  time.t_source += @elapsed evalSourceTerm(mesh, sbp, eqn, opts)

  # apply inverse mass matrix to eqn.res, necessary for CN
  if opts["use_Minv"]
    applyMassMatrixInverse3D(mesh, sbp, eqn, opts, eqn.res)
  end

  # Reverse sweep

  return nothing
end  # end evalResidual

function evalVolumeIntegrals_dRdm{Tmsh,  Tsol, Tres, Tdim}(mesh::AbstractMesh{Tmsh}, 
                             sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim}, opts)
  integral_type = opts["volume_integral_type"]
  if integral_type == 1
    if opts["Q_transpose"] == true
      for i=1:Tdim
        # weakdifferentiate_rev!(sbp, i, sview(eqn.flux_parametric, :, :, :, i), eqn.res, trans=true)

        # Input: eqn.res_bar 
        # Output: flux_parametric_bar
        weakdifferentiate_rev!(sbp, i, sview(eqn.flux_parametric_bar, :, :, :, i), eqn.res_bar, trans=true)
      end
    else
      for i=1:Tdim
        weakdifferentiate_rev!(sbp, i, sview(eqn.flux_parametric_bar, :, :, :, i), eqn.res_bar, SummationByParts.Subtract(), trans=false)
      end
    end  # end if
  elseif integral_type == 2

    error("integral_type == 2 not supported")
    calcVolumeIntegralsSplitForm(mesh, sbp, eqn, opts, eqn.volume_flux_func)
  else
    throw(ErrorException("Unsupported volume integral type = $integral_type"))
  end


end  # end evalVolumeIntegrals

function evalBoundaryIntegrals_dRdm{Tmsh, Tsol, Tres, Tdim}(mesh::AbstractMesh{Tmsh}, 
                               sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim})

  #TODO: remove conditional
  if mesh.isDG
    boundaryintegrate_rev!(mesh.sbpface, mesh.bndryfaces, eqn.bndryflux_bar, eqn.res_bar, SummationByParts.Subtract())
  else
    boundaryintegrate_rev!(mesh.sbpface, mesh.bndryfaces, eqn.bndryflux_bar, eqn.res_bar, SummationByParts.Subtract())
  end


  return nothing

end  # end evalBoundaryIntegrals

function evalFaceIntegrals_dRdm{Tmsh, Tsol}(mesh::AbstractDGMesh{Tmsh}, 
                           sbp::AbstractSBP, eqn::EulerData{Tsol}, opts)

  face_integral_type = opts["face_integral_type"]
  if face_integral_type == 1
#    println("calculating regular face integrals")
    interiorfaceintegrate_rev!(mesh.sbpface, mesh.interfaces, eqn.flux_face_bar, eqn.res_bar, SummationByParts.Subtract())

  elseif face_integral_type == 2
    
    error("integral_type == 2 not supported")
    getFaceElementIntegral_rev(mesh, sbp, eqn, eqn.face_element_integral_func,  
                           eqn.flux_func, mesh.interfaces)

  else
    throw(ErrorException("Unsupported face integral type = $face_integral_type"))
  end

  # do some output here?
  return nothing
end

function evalSharedFaceIntegrals_dRdm(mesh::AbstractDGMesh, sbp, eqn, opts)

  face_integral_type = opts["face_integral_type"]
  if face_integral_type == 1

    if opts["parallel_data"] == "face"
      calcSharedFaceIntegrals_dRdm(mesh, sbp, eqn, opts, eqn.flux_func)
    elseif opts["parallel_data"] == "element"
      calcSharedFaceIntegrals_element_dRdm(mesh, sbp, eqn, opts, eqn.flux_func)
    else
      throw(ErrorException("unsupported parallel data type"))
    end

  elseif face_integral_type == 2

      error("integral_type == 2 not supported")
    getSharedFaceElementIntegrals_element(mesh, sbp, eqn, opts, eqn.face_element_integral_func,  eqn.flux_func)
  else
    throw(ErrorException("unsupported face integral type = $face_integral_type"))
  end

  return nothing
end

function calcSharedFaceIntegrals_dRdm{Tmsh, Tsol}( mesh::AbstractDGMesh{Tmsh},
                            sbp::AbstractSBP, eqn::EulerData{Tsol},
                            opts, functor_revm::FluxType)
# calculate the face flux and do the integration for the shared interfaces

  if opts["parallel_data"] != "face"
    throw(ErrorException("cannot use calcSharedFaceIntegrals without parallel face data"))
  end


  params = eqn.params

  npeers = mesh.npeers
  val = sum(mesh.recv_waited)
  if val !=  mesh.npeers && val != 0
    throw(ErrorException("Receive waits in inconsistent state: $val / $npeers already waited on"))
  end


  for i=1:mesh.npeers
    if val == 0
      params.time.t_wait += @elapsed idx, stat = MPI.Waitany!(mesh.recv_reqs)
      mesh.recv_stats[idx] = stat
      mesh.recv_reqs[idx] = MPI.REQUEST_NULL  # don't use this request again
      mesh.recv_waited[idx] = true
    else
      idx = i
    end

    # calculate the flux
    interfaces = mesh.shared_interfaces[idx]
    qL_arr = eqn.q_face_send[idx]
    qR_arr = eqn.q_face_recv[idx]
    aux_vars_arr = eqn.aux_vars_sharedface[idx]
    dxidx_arr = mesh.dxidx_sharedface[idx]
    flux_arr_bar = eqn.flux_sharedface_bar[idx]

    # permute the received nodes to be in the elementR orientation
    permuteinterface!(mesh.sbpface, interfaces, qR_arr)
    for j=1:length(interfaces)
      interface_i = interfaces[j]
      for k=1:mesh.numNodesPerFace
        eL = interface_i.elementL
        fL = interface_i.faceL

        qL = sview(qL_arr, :, k, j)
        qR = sview(qR_arr, :, k, j)
        dxidx = sview(dxidx_arr, :, :, k, j)
        aux_vars = sview(aux_vars_arr, :, k, j)
        nrm = sview(sbp.facenormal, :, fL)
        flux_j = sview(flux_arr_bar, :, k, j)
        functor_revm(params, qL, qR, aux_vars, dxidx, nrm, flux_j)
      end
    end
    # end flux calculation

    # do the integration
    boundaryintegrate_rev!(mesh.sbpface, mesh.bndries_local[idx], flux_arr_bar, eqn.res_bar, SummationByParts.Subtract())
  end  # end loop over npeers

  @debug1 sharedFaceLogging(mesh, sbp, eqn, opts, eqn.q_face_send, eqn.q_face_recv)

  return nothing
end



function evalSourceTerm_dRdm{Tmsh, Tsol, Tres, Tdim}(mesh::AbstractMesh{Tmsh},
                     sbp::AbstractSBP, eqn::EulerData{Tsol, Tres, Tdim}, 
                     opts)


  # placeholder for multiple source term functionality (similar to how
  # boundary conditions are done)
  if opts["use_src_term"]
    applySourceTerm(mesh, sbp, eqn, opts, eqn.src_func)
  end

  return nothing
end  # end function