# differentiated version of homotopy.jl
import PDESolver.evalHomotopyJacobian

function evalHomotopyJacobian(mesh::AbstractMesh, sbp::AbstractSBP,
                              eqn::EulerData, opts::Dict, 
                              assembler::AssembleElementData, lambda::Number)

  calcHomotopyDiss_jac(mesh, sbp, eqn, opts, assembler, lambda)
end

function calcHomotopyDiss_jac{Tsol, Tres, Tmsh}(mesh::AbstractDGMesh{Tmsh}, sbp, 
                          eqn::EulerData{Tsol, Tres}, opts, assembler, lambda)

  # some checks for when parallelism is enabled
  @assert opts["parallel_data"] == "element"
  for i=1:mesh.npeers
    @assert eqn.shared_data[i].recv_waited
  end

  params = eqn.params
  #----------------------------------------------------------------------------
  # volume dissipation

  # compute the D operator in each direction
  D = zeros(mesh.numNodesPerElement, mesh.numNodesPerElement, mesh.dim)
  for d=1:mesh.dim
    D[:, :, d] = inv(diagm(sbp.w))*sbp.Q[:, :, d]
  end

  res_jac = eqn.params.res_jacLL
  t2_dot = eqn.params.res_jacLR  # work array
  t1 = zeros(Tsol, mesh.numDofPerNode, mesh.numNodesPerElement)
  lambda_dot = zeros(Tres, mesh.numDofPerNode)

  nrm = zeros(Tmsh, mesh.dim)
  for el=1:mesh.numEl
    q_el = sview(eqn.q, :, :, el)
    fill!(res_jac, 0.0)
    for d1=1:mesh.dim
      fill!(t1, 0.0)
      fill!(t2_dot, 0.0)

      differentiateElement!(sbp, d1, q_el, t1)

      # t2 = t1*lambda_p
      # contribution t2_dot = lambda_p*t1_dot
      for p=1:mesh.numNodesPerElement
        q_p = sview(eqn.q, :, p, el)

        # get vector in xi direction defined by dim
        for k=1:mesh.dim
          nrm[k] = mesh.dxidx[d1, k, p, el]
        end

        lambda_max = getLambdaMax(eqn.params, q_p, nrm)

        for q=1:mesh.numNodesPerElement
          for j=1:mesh.numDofPerNode
#            for i=1:mesh.numDofPerNode
              t2_dot[j, j, p, q] += lambda_max*D[p, q, d1]
#            end
          end
        end
      end   # end loop p

      # contribution t2_dot += t1*lambda_p_dot
      for p=1:mesh.numNodesPerElement
        q_p = sview(eqn.q, :, p, el)

        # get vector in xi direction defined by dim
        for k=1:mesh.dim
          nrm[k] = mesh.dxidx[d1, k, p, el]
        end

        getLambdaMax_diff(eqn.params, q_p, nrm, lambda_dot)

        for j=1:mesh.numDofPerNode
          for i=1:mesh.numDofPerNode
            t2_dot[i, j, p, p] += t1[i, p]*lambda_dot[j]
          end
        end
      end  # end loop p


      # apply Q^T
#      for d2=1:mesh.dim
        for p=1:mesh.numNodesPerElement
          for q=1:mesh.numNodesPerElement
            for c=1:mesh.numNodesPerElement
              for j=1:mesh.numDofPerNode
                for i=1:mesh.numDofPerNode
                  res_jac[i, j, p, q] += sbp.Q[c, p, d1]*t2_dot[i, j, c, q]
                end
              end
            end
          end
        end
#      end  # end loop d2

    end  # end loop d1
 
    # negate res_jac for consistency with physics module
    for i=1:length(res_jac)
      res_jac[i] = -lambda*res_jac[i]
    end

     
    assembleElement(assembler, mesh, el, res_jac)
  end  # end loop el


  fill!(res_jac, 0.0)
  fill!(t2_dot, 0.0)


  #----------------------------------------------------------------------------
  # interface terms

  q_faceL = zeros(Tsol, mesh.numDofPerNode, mesh.numNodesPerFace)
  q_faceR = zeros(q_faceL)
#  nrm2 = eqn.params.nrm2
  flux_jacL = zeros(Tres, mesh.numDofPerNode, mesh.numDofPerNode, mesh.numNodesPerFace)
  flux_jacR = zeros(flux_jacL)

  res_jacLL = params.res_jacLL
  res_jacLR = params.res_jacLR
  res_jacRL = params.res_jacRL
  res_jacRR = params.res_jacRR

  lambda_dotL = zeros(Tres, mesh.numDofPerNode)
  lambda_dotR = zeros(Tres, mesh.numDofPerNode)

  for i=1:mesh.numInterfaces
    iface_i = mesh.interfaces[i]
    qL = sview(eqn.q, :, :, iface_i.elementL)
    qR = sview(eqn.q, :, :, iface_i.elementR)
    fill!(res_jacLL, 0.0)
    fill!(res_jacLR, 0.0)
    fill!(res_jacRL, 0.0)
    fill!(res_jacRR, 0.0)

    interiorFaceInterpolate!(mesh.sbpface, iface_i, qL, qR, q_faceL, q_faceR)

    # calculate the flux jacobian at each face node
    for j=1:mesh.numNodesPerFace
      qL_j = sview(q_faceL, :, j)
      qR_j = sview(q_faceR, :, j)

      # get the face normal
      nrm2 = sview(mesh.nrm_face, :, j, i)

      lambda_max = getLambdaMaxSimple_diff(eqn.params, qL_j, qR_j, nrm2,
                                           lambda_dotL, lambda_dotR)

      for k=1:mesh.numDofPerNode
        # flux[k, j] = 0.5*lambda_max*(qL_j[k] - qR_j[k])
        for m=1:mesh.numDofPerNode
          flux_jacL[m, k, j] = 0.5*lambda_dotL[k]*(qL_j[m] - qR_j[m])
          flux_jacR[m, k, j] = 0.5*lambda_dotR[k]*(qL_j[m] - qR_j[m])
        end
        flux_jacL[k, k, j] += 0.5*lambda_max
        flux_jacR[k, k, j] -= 0.5*lambda_max
      end
    end  # end loop j

    # multiply by lambda here and it will get carried through
    # interiorFaceIntegrate_jac
    scale!(flux_jacL, lambda)
    scale!(flux_jacR, lambda)

    # compute dR/dq
    interiorFaceIntegrate_jac!(mesh.sbpface, iface_i, flux_jacL, flux_jacR,
                             res_jacLL, res_jacLR, res_jacRL, res_jacRR,
                             SummationByParts.Subtract())
    # assemble into the Jacobian
    assembleInterface(assembler, mesh.sbpface, mesh, iface_i, res_jacLL, res_jacLR,
                                                res_jacRL, res_jacRR)

  end  # end loop i

  fill!(res_jacLL, 0.0)
  fill!(res_jacLR, 0.0)
  fill!(res_jacRL, 0.0)
  fill!(res_jacRR, 0.0)


  #----------------------------------------------------------------------------
  # skipping boundary integrals
  # use nrm2, flux_jfacL from interface terms above
  if opts["homotopy_addBoundaryIntegrals"]
    qg = eqn.params_complex.qg  # boundary state
    q_faceLc = eqn.params_complex.q_faceL
    h = 1e-20
    pert = Complex128(0, h)
    for i=1:mesh.numBoundaryFaces
      bndry_i = mesh.bndryfaces[i]
      qL = sview(eqn.q, :, :, bndry_i.element)
#      resL = sview(res, :, :, bndry_i.element)
      fill!(q_faceLc, 0.0)
      fill!(res_jac, 0.0)

      boundaryFaceInterpolate!(mesh.sbpface, bndry_i.face, qL, q_faceLc)

      # compute flux jacobian at each node
      for j=1:mesh.numNodesPerFace
        q_j = sview(q_faceLc, :, j)
        for m=1:mesh.numDofPerNode
          q_j[m] += pert
    #      dxidx_j = sview(mesh.dxidx_bndry, :, :, j, i)

          # calculate boundary state
          coords = sview(mesh.coords_bndry, :, j, i)
          calcFreeStream(eqn.params_complex, coords, qg)

          # calculate face normal
          nrm2 = sview(mesh.nrm_bndry, :, j, i)

          # calculate lambda_max
          lambda_max = getLambdaMaxSimple(eqn.params_complex, q_j, qg, nrm2)

          # calculate dissipation
          for k=1:mesh.numDofPerNode
            flux_jacL[k, m, j] = lambda*imag(0.5*lambda_max*(q_j[k] - qg[k]))/h
          end

          q_j[m] -= pert
        end  # end loop m
      end  # end loop j

      
      boundaryFaceIntegrate_jac!(mesh.sbpface, bndry_i.face, flux_jacL, res_jac,
                               SummationByParts.Subtract())

      assembleBoundary(assembler, mesh.sbpface, mesh, bndry_i, res_jac)
    end  # end loop i

    fill!(res_jac, 0.0)
  end


  #---------------------------------------------------------------------------- 
  # shared face integrals
  # use q_faceL, q_faceR, lambda_dotL, lambda_dotR, flux_jacL, flux_jacR
  # from above

  workarr = zeros(q_faceR)
  for peer=1:mesh.npeers
    # get data for this peer
    interfaces_peer = mesh.shared_interfaces[peer]

    qR_peer = eqn.shared_data[peer].q_recv
#    dxidx_peer = mesh.dxidx_sharedface[peer]
    nrm_peer = mesh.nrm_sharedface[peer]
    start_elnum = mesh.shared_element_offsets[peer]

    for i=1:length(interfaces_peer)
      iface_i = interfaces_peer[i]
      qL_i = sview(eqn.q, :, :, iface_i.elementL)
      qR_i = sview(qR_peer, :, :, iface_i.elementR - start_elnum + 1)
      fill!(res_jacLL, 0.0)
      fill!(res_jacLR, 0.0)

      # interpolate to face
      interiorFaceInterpolate!(mesh.sbpface, iface_i, qL_i, qR_i, q_faceL, q_faceR)
      # compute flux at every face node
      for j=1:mesh.numNodesPerFace
        qL_j = sview(q_faceL, :, j)
        qR_j = sview(q_faceR, :, j)
        nrm2 = sview(nrm_peer, :, j, i)

        # get max wave speed
        lambda_max = getLambdaMaxSimple_diff(eqn.params, qL_j, qR_j, nrm2,
                                             lambda_dotL, lambda_dotR)

        # calculate flux
        for k=1:mesh.numDofPerNode
          # flux[k, j] = 0.5*lambda_max*(qL_j[k] - qR_j[k])
          for m=1:mesh.numDofPerNode
            flux_jacL[m, k, j] = 0.5*lambda_dotL[k]*(qL_j[m] - qR_j[m])
            flux_jacR[m, k, j] = 0.5*lambda_dotR[k]*(qL_j[m] - qR_j[m])
          end
          flux_jacL[k, k, j] += 0.5*lambda_max
          flux_jacR[k, k, j] -= 0.5*lambda_max
        end
      end  # end loop j

      # multiply by lambda here and it will get carried through
      # interiorFaceIntegrate_jac
      scale!(flux_jacL, lambda)
      scale!(flux_jacR, lambda)

      # compute dR/dq
      interiorFaceIntegrate_jac!(mesh.sbpface, iface_i, flux_jacL, flux_jacR,
                                res_jacLL, res_jacLR, res_jacRL, res_jacRR,
                                SummationByParts.Subtract())


     assembleSharedFace(assembler, mesh.sbpface, mesh, iface_i, res_jacLL, res_jacLR)
    end  # end loop i
  end  # end loop peer
  
  fill!(res_jacLL, 0.0)
  fill!(res_jacLR, 0.0)
  fill!(res_jacRL, 0.0)
  fill!(res_jacRR, 0.0)




  return nothing
end


"""
  Differentiated version of [`getLambdaMax`](@ref)

  **Inputs**

   * params: ParamType
   * qL: vector of conservative variables at a node
   * dir: direction vector (can be scaled)

  **Inputs/Outputs**

   * qL_dot: derivative of lambda max wrt qL

  **Outputs**

   * lambda_max: maximum eigenvalue
"""
function getLambdaMax_diff{Tsol, Tres, Tmsh}(params::ParamType{2},
                      qL::AbstractVector{Tsol},
                      dir::AbstractVector{Tmsh},
                      lambda_dot::AbstractVector{Tres})

  gamma = params.gamma
  Un = zero(Tres)
  dA = zero(Tmsh)
  rhoLinv = 1/qL[1]
  rhoLinv_dotL1 = -rhoLinv*rhoLinv

  p_dot = params.p_dot
  pL = calcPressure_diff(params, qL, p_dot)
  aL = sqrt(gamma*pL*rhoLinv)  # speed of sound
  t1 = gamma*rhoLinv/(2*aL)
  t2 = gamma*pL/(2*aL)
  aL_dotL1 = t1*p_dot[1] + t2*rhoLinv_dotL1
  aL_dotL2 = t1*p_dot[2]
  aL_dotL3 = t1*p_dot[3]
  aL_dotL4 = t1*p_dot[4]


  Un_dotL1 = dir[1]*qL[2]*rhoLinv_dotL1
  Un_dotL2 = dir[1]*rhoLinv
  Un += dir[1]*qL[2]*rhoLinv

  Un_dotL1 += dir[2]*qL[3]*rhoLinv_dotL1
  Un_dotL3 = dir[2]*rhoLinv
  Un += dir[2]*qL[3]*rhoLinv

  for i=1:2
    dA += dir[i]*dir[i]
  end

  dA = sqrt(dA)

  lambda_max = absvalue(Un) + dA*aL
  lambda_dot[1] = dA*aL_dotL1
  lambda_dot[2] = dA*aL_dotL2
  lambda_dot[3] = dA*aL_dotL3
  lambda_dot[4] = dA*aL_dotL4

  if Un > 0
    lambda_dot[1] += Un_dotL1
    lambda_dot[2] += Un_dotL2
    lambda_dot[3] += Un_dotL3
  else
    lambda_dot[1] -= Un_dotL1
    lambda_dot[2] -= Un_dotL2
    lambda_dot[3] -= Un_dotL3
  end


  return lambda_max
end



function getLambdaMax_diff{Tsol, Tres, Tmsh}(params::ParamType{3},
                      qL::AbstractVector{Tsol},
                      dir::AbstractVector{Tmsh},
                      lambda_dot::AbstractVector{Tres})

  gamma = params.gamma
  Un = zero(Tres)
  dA = zero(Tmsh)
  rhoLinv = 1/qL[1]
  rhoLinv_dotL1 = -rhoLinv*rhoLinv

  p_dot = params.p_dot
  pL = calcPressure_diff(params, qL, p_dot)
  aL = sqrt(gamma*pL*rhoLinv)  # speed of sound
  t1 = gamma*rhoLinv/(2*aL)
  t2 = gamma*pL/(2*aL)
  aL_dotL1 = t1*p_dot[1] + t2*rhoLinv_dotL1
  aL_dotL2 = t1*p_dot[2]
  aL_dotL3 = t1*p_dot[3]
  aL_dotL4 = t1*p_dot[4]
  aL_dotL5 = t1*p_dot[5]


  Un_dotL1 = dir[1]*qL[2]*rhoLinv_dotL1
  Un_dotL2 = dir[1]*rhoLinv
  Un += dir[1]*qL[2]*rhoLinv

  Un_dotL1 += dir[2]*qL[3]*rhoLinv_dotL1
  Un_dotL3 = dir[2]*rhoLinv
  Un += dir[2]*qL[3]*rhoLinv

  Un_dotL1 += dir[3]*qL[4]*rhoLinv_dotL1
  Un_dotL4 = dir[3]*rhoLinv
  Un += dir[3]*qL[4]*rhoLinv


  for i=1:3
    dA += dir[i]*dir[i]
  end

  dA = sqrt(dA)

  lambda_max = absvalue(Un) + dA*aL
  lambda_dot[1] = dA*aL_dotL1
  lambda_dot[2] = dA*aL_dotL2
  lambda_dot[3] = dA*aL_dotL3
  lambda_dot[4] = dA*aL_dotL4
  lambda_dot[5] = dA*aL_dotL5

  if Un > 0
    lambda_dot[1] += Un_dotL1
    lambda_dot[2] += Un_dotL2
    lambda_dot[3] += Un_dotL3
    lambda_dot[4] += Un_dotL4
  else
    lambda_dot[1] -= Un_dotL1
    lambda_dot[2] -= Un_dotL2
    lambda_dot[3] -= Un_dotL3
    lambda_dot[4] -= Un_dotL4
  end


  return lambda_max
end

"""
  Differentiated version of [`getLambdaMaxSimple`](@ref)

  **Inputs**

   * params
   * qL
   * qR
   * dir

  **Inputs/Outputs**

   * lambda_dotL: derivative of lambda wrt. qL
   * lambda_dotR: derivative of lambda wrt. qR
"""
function getLambdaMaxSimple_diff{Tsol, Tmsh, Tdim}(params::ParamType{Tdim}, 
                      qL::AbstractVector{Tsol}, qR::AbstractVector{Tsol}, 
                      dir::AbstractVector{Tmsh},
                      lambda_dotL::AbstractVector{Tsol},
                      lambda_dotR::AbstractVector{Tsol})

  q_avg = params.q_vals3

  for i=1:length(q_avg)
    q_avg[i] = 0.5*(qL[i] + qR[i])
  end

  lambda_max = getLambdaMax_diff(params, q_avg, dir, lambda_dotL)

  for i=1:length(lambda_dotL)
    lambda_dotL[i] *= 0.5
    lambda_dotR[i] = lambda_dotL[i]
  end

  return lambda_max
end

