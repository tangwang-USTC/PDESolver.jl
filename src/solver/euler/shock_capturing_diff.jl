# differentiated shock capturing functions

# main entry point
"""
  Main function for assembling the shock capturing terms into the Jacobian.

  **Inputs**

   * mesh
   * sbp
   * eqn
   * opts
   * sensor: an [`AbstractShockSensor`](@ref)
   * capture: an [`AbstractShockCapturing`](@ref)
   * assem: an [`AssembleElementData`](@ref)
"""
function applyShockCapturing_diff(mesh::AbstractMesh, sbp::AbstractOperator,
                             eqn::EulerData, opts, sensor::AbstractShockSensor,
                             capture::AbstractShockCapturing,
                             assem::AssembleElementData)


  data = eqn.params.calc_volume_integrals_data
  res_jac = data.res_jac
  fill!(res_jac, 0)

  for i=1:mesh.numEl
    q_i = sview(eqn.q, :, :, i)
    jac_i = sview(mesh.jac, :, i)

    nonzero_jac = applyShockCapturing_diff(eqn.params, sbp, sensor, capture,
                                            q_i, jac_i, res_jac)
  
    # assembling into a sparse matrix is non-trivially expensive, don't do
    # it unless this element has shock capturing active
    if nonzero_jac
      if eqn.params.use_Minv == 1
        applyMinvElement(jac_i, sbp.w, res_jac)
      end

      # assemble element level jacobian into the residual
      assembleElement(assem, mesh, i, res_jac)
      fill!(res_jac, 0)
    end  # if nonzero_jac
  
  end  # end i

  return nothing
end



#------------------------------------------------------------------------------

"""
  Differentiated version nof `getShockSensor` for [`ShockSensorPP`](@ref)
"""
function getShockSensor_diff(params::ParamType, sbp::AbstractOperator,
                      sensor::ShockSensorPP,
                      q::AbstractMatrix{Tsol},
                      jac::AbstractVector{Tmsh},
                      Se_jac::AbstractMatrix{Tres},
                      ee_jac::AbstractMatrix{Tres}) where {Tsol, Tmsh, Tres}
# computes the Jacobian of Se and ee wrt q. Does not take in q_dot because
# that would be way more expensive
# Se_jac and ee_jac are overwritten
# The third output argument tells if ee_jac is all zeros (hopefully a common
# case).

  numDofPerNode, numNodesPerElement = size(q)
  @unpack sensor up up_tilde up1_tilde s0 kappa e0 num_dot den_dot
  fill!(num_dot, 0); fill!(den_dot, 0)

  @simd for i=1:numNodesPerElement
    up[i] = q[1, i]
  end

  # for getFiltered solution, the matrix itself is the Jacobian
  getFilteredSolution(params, sensor.Vp, up, up_tilde)
  getFilteredSolution(params, sensor.Vp1, up, up1_tilde)
  up_tilde_dotT = sensor.Vp.filtT  # use transposed because of memory order
  up1_tilde_dotT = sensor.Vp1.filtT

  # compute the inner product
  num = zero(Tres)
  den = zero(Tres)

  @simd for i=1:numNodesPerElement
    fac = sbp.w[i]/jac[i]
    delta_u = up_tilde[i] - up1_tilde[i]


    num += delta_u*fac*delta_u
    @simd for j=1:numNodesPerElement
      delta_u_dot = up_tilde_dotT[j, i] - up1_tilde_dotT[j, i]
      num_dot[j] += 2*fac*delta_u*delta_u_dot
    end

    # use the filtered variables for (u, u).  This is a bit different than
    # finite element methods, where the original solution has a basis, and the
    # norm in any basis should be the same.  Here we use the filtered u rather
    # than the original because it is probably smoother.
    den += up_tilde[i]*fac*up_tilde[i]
    @simd for j=1:numNodesPerElement
      den_dot[j] += 2*fac*up_tilde[i]*up_tilde_dotT[j, i]
    end
  end

  Se = num/den
  fac2 = 1/(den*den)
  @simd for i=1:numNodesPerElement
    Se_jac[1, i] = (num_dot[i]*den - den_dot[i]*num)*fac2
  end


  se = log10(Se)
  eejac_zero = true
  
  if se < s0 - kappa
    ee = zero(Tres)
    fill!(ee_jac, 0)
  elseif se > s0 - kappa && se < s0 + kappa
    ee = 0.5*e0*(1 + sinpi( (se - s0)/(2*kappa)))

    # derivative of ee wrt Se (not se)
    fac3 = 0.5*e0*cospi( (se - s0)/(2*kappa) ) * (Float64(pi)/(2*kappa*log(10)*Se))
    fill!(ee_jac, 0)
    @simd for i=1:numNodesPerElement
      ee_jac[1, i] = fac3*Se_jac[1, i]
    end
    eejac_zero = false
  else
    ee = Tres(e0)
    fill!(ee_jac, 0)
  end

  return Se, ee, eejac_zero
end


#------------------------------------------------------------------------------


"""
  Differentiated version of `applyShockCapturing` for
  [`ProjectionShockCapturing`](@ref).
"""
function applyShockCapturing_diff(params::ParamType, sbp::AbstractOperator,
                                  sensor::AbstractShockSensor,
                                  capture::ProjectionShockCapturing,
                                  u::AbstractMatrix, jac::AbstractVector{Tmsh},
                                  res_jac::AbstractArray{Tres, 4}) where {Tmsh, Tres}

  numDofPerNode, numNodesPerElement = size(u)
  @unpack capture t1 t2 w Se_jac ee_jac A0inv

  #TODO: make shock capturing and shock sensing independent choices
  Se, ee = getShockSensor(params, sbp, sensor, u, jac)

  if ee > 0
    fill!(Se_jac, 0); fill!(ee_jac, 0)
    # only compute the derivative if there is a shock
    Se, ee, ee_constant = getShockSensor_diff(params, sbp, sensor, u, jac,
                                              Se_jac, ee_jac)

    # the operator (for a scalar equation) is A = P^T * M * P * v, so
    # dR[p]/v[q] = (P^T * M * P)[p, q].  It then needs to be converted back
    # to conservative variables

    # compute derivative contribution from v
    @simd for p=1:numNodesPerElement
      @simd for q=1:numNodesPerElement
        getIRA0inv(params, sview(u, :, q), A0inv)
        # calculate the A[p, q]
        Apq = zero(Tres)
        @simd for k=1:numNodesPerElement
          Apq += capture.filt[k, p]*(sbp.w[k]/jac[k])*capture.filt[k, q]
        end
        @simd for j=1:numDofPerNode
          @simd for i=1:numDofPerNode
            res_jac[i, j, p, q] = -ee*Apq*A0inv[i, j]
          end
        end
      end
    end

    # compute derivative contribution from ee
    if !ee_constant

      @simd for i=1:numNodesPerElement
        w_i = sview(w, :, i)
        q_i = sview(u, :, i)
        convertToIR(params, q_i, w_i)
      end

      # apply P
      smallmatmatT!(w, capture.filt, t1)


      # apply mass matrix
      @simd for i=1:numNodesPerElement
        fac = sbp.w[i]/jac[i]
        @simd for j=1:numDofPerNode
          t1[j, i] *= fac
        end
      end

      # apply P^T
      smallmatmat!(t1, capture.filt, t2)

      @simd for p=1:numNodesPerElement
        @simd for q=1:numNodesPerElement
          @simd for j=1:numDofPerNode
            @simd for i=1:numDofPerNode
              res_jac[i, j, p, q] -= ee_jac[j, q]*t2[i, p]
            end
          end
        end
      end

    end  # if ee_constant


  end  # end if

  return ee > 0
end


