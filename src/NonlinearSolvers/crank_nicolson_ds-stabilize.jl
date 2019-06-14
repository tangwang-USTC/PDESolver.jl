
# Note: passed in for the eqn argument is 'eqn_nextstep'
function stabilizeCNDSLO(lo_ds, mesh, sbp, eqn, opts, ctx_residual, t)

  # ctx_residual = (f, eqn, h, newton_data, stab_A, stab_assembler, clipJacData)
  f =               ctx_residual[1]
  eqn_old =         ctx_residual[2]
  h =               ctx_residual[3]
  newton_data =     ctx_residual[4]
  stab_A =          ctx_residual[5]
  stab_assembler =  ctx_residual[6]
  clipJacData =     ctx_residual[7]
  v_vec =           ctx_residual[8]

  # println(BSTDOUT, "        stabilizeCNDSLO called")

  # get i from t
  i = round(Int, t/h + 2)
  lo_ds_innermost = getBaseLO(lo_ds)

  # Note: attempting to print eigenvalues of lo_ds_innermost.A here 
  #   with eigvals(full(lo_ds_innermost.A)) takes TOO MUCH MEMORY & TIME

  # We have to zero out the DiagJac, as assembleElement inside evalJacobianStrong accumulates.
  MatZeroEntries(stab_assembler.A)

  if opts["stabilize_on_which_dFdq"] == "Minv"
  elseif opts["stabilize_on_which_dFdq"] == "noMinv"
    eqn.params.use_Minv = 0
  end

  # stores the strong Jacobian (volume Jacobian) into stab_assembler.A
  evalJacobianStrong(mesh, sbp, eqn, opts, stab_assembler, t)

  # eigenvalue plotting, strong Jac, before any filtering
  #=
  eigs_strongJac_before_stab = eigvals(stab_assembler.A)
  filename = string("i", i,"_2-eigs_strongJac_before_stab.dat")
  writedlm(filename, eigs_strongJac_before_stab)
  =#

  # filterDiagJac
  #   location: jacobian_diag.jl
  #
  #   The third argument is q_vec in the fn signature.
  #   It is used as part of computing the quadprog stabilization (findStablePerturbation!).
  #   It is not used when opts["stabilization_method"] is "clipJac" or "clipJacFast".
  #   For the explicit stabilization what was passed in was 'real(tmp_imag)'.
  #   For implicit: It should be v_vec. Of the previous time step.
  #     See the AFOSR report's section on quadprog; it uses the adjoint.
  #     I suppose it could be the next time step, but that would require some implicit solving 
  #     and KSP iterations? Maybe room for investigation later. (future work)
  #     Because right after this stabilizeCNDSLO is called, 
  #     linearSolve is called to find v_vec^(n+1)
  eigs_to_remove = opts["eigs_to_remove"]
  numEigChgsAllEls = filterDiagJac(mesh, eqn, opts, v_vec, clipJacData, 
                                   stab_A, eigs_to_remove=eigs_to_remove)
  println(BSTDOUT, " numEigChgsAllEls: ", numEigChgsAllEls)

  # eigenvalue plotting, strong Jac, after filtering
  #=
  eigs_strongJac_after_stab = eigvals(stab_assembler.A)
  filename = string("i", i,"_3-eigs_strongJac_after_stab.dat")
  writedlm(filename, eigs_strongJac_after_stab)
  =#

  # Now add each block of the stabilized strong jacobian to the full Jacobian
  # We are converting between the 2D element Jacobian in each block of the DiagJac
  #   to the 4D form required by assembleElement.
  # DiagJac dims: (blocksize, blocksize, numEl)
  # res_jac dims: (numDofPerNode, numDofPerNode, numNodesPerElement, numNodesPerElement)
  assembler = _AssembleElementData(lo_ds_innermost.A, mesh, sbp, eqn, opts)
  blocksize = mesh.numDofPerNode*mesh.numNodesPerElement
  this_res_jac = zeros(Complex{Float64}, mesh.numDofPerNode, mesh.numDofPerNode, 
                       mesh.numNodesPerElement, mesh.numNodesPerElement)

  if opts["stabilize_on_which_dFdq"] == "noMinv"
    eqn.params.use_Minv = 1
  end

  for el_ix = 1:mesh.numEl

    for q = 1:mesh.numNodesPerElement
      for p = 1:mesh.numNodesPerElement

        if opts["stabilize_on_which_dFdq"] == "noMinv"
          # Minv_val = mesh.jac[p, el_ix]/sbp.w[p]  # entry in Minv
          Minv_val = 1.0        # TODO TODO why does this work, and not the proper Minv?
          # 20190612
          # mistakenly using i (timestep index) instead of el_ix caused some stabilization
        end
        @simd for j = 1:mesh.numDofPerNode
          @simd for i = 1:mesh.numDofPerNode

            # Within each DiagJac block, it is indexed along one dimension as:
            #   all the dofs on node 1, all the dofs on node 2, etc. 
            # This permits the following conversion:
            i1 = i + (p-1)*mesh.numDofPerNode
            j1 = j + (q-1)*mesh.numDofPerNode

            #=
            println(BSTDOUT, "---\n el_ix: $el_ix  q: $q  p: $p  i: $i  j: $j")
            println(BSTDOUT, " i1: $i1  j1: $j1")
            println(BSTDOUT, " this_res_jac[i, j, p, q]: ", this_res_jac[i, j, p, q])
            println(BSTDOUT, " stab_A.A[i1, j1, el_ix]: ", stab_A.A[i1, j1, el_ix])
            println(BSTDOUT, " typeof(stab_A.A[i1,j1,el_ix]): ", typeof(stab_A.A[i1,j1,el_ix]))
            println(BSTDOUT, " typeof(this_res_jac[i,j,p,q]): ", typeof(this_res_jac[i,j,p,q]))
            =#
            this_res_jac[i, j, p, q] = stab_A.A[i1, j1, el_ix]
            #=
            println(BSTDOUT, " after this_res_jac assign")
            println(BSTDOUT, " this_res_jac[i, j, p, q]: ", this_res_jac[i, j, p, q])
            println(BSTDOUT, " stab_A.A[i1, j1, el_ix]: ", stab_A.A[i1, j1, el_ix])
            println(BSTDOUT, " typeof(stab_A.A[i1,j1,el_ix]): ", typeof(stab_A.A[i1,j1,el_ix]))
            println(BSTDOUT, " typeof(this_res_jac[i,j,p,q]): ", typeof(this_res_jac[i,j,p,q]))
            =#

            if opts["stabilize_on_which_dFdq"] == "noMinv"
              this_res_jac[i, j, p, q] *= Minv_val
            end

          end
        end

      end   # end loop over p
    end   # end loop over q


    # this_res_jac should contain all the positive eigs, so if we subtract, 
    #   we are left with only negative and zero eigenvalues.
    if opts["stabilization_method"] != "quadprog"
      scale!(this_res_jac, -1.0)
    end

    assembleElement(assembler, mesh, el_ix, this_res_jac)
    # This is calling function assembleElement(helper::_AssembleElementData{PetscMat}, 
    #                                          mesh::AbstractMesh,
    #                                          elnum::Integer, jac::AbstractArray{T, 4}) where T
    # in jacobian.jl. Line 888 or so

  end   # end loop over elements
  
  # Note: attempting to print eigenvalues of lo_ds_innermost.A here 
  #   with eigvals(full(lo_ds_innermost.A)) takes TOO MUCH MEMORY & TIME

  return nothing

end

"""
  returns matrix `Jacpert` such that `u.'*sym(Jac + Jacpert)*u` is strictly
  positive

  **Inputs**

   * `u`: an given vector whose dimensions are consistent with `Jac`
   * `Jac`: matrix that needs to be perturbed
   * `A`: a work vector needed by this function (overwritten).  The
          element type should be the "maximum" type of the element types
          of `u` and `Jac`


  **Inputs/Outputs**

   * `Jacpert`: matrix perturbation
"""
function findStablePerturbation!(Jac::AbstractMatrix,
                                 u::AbstractVector,
                                 A::AbstractVector{T},
                                 eigs_to_remove::String) where T

  @assert( size(Jac,1) == size(Jac,2) == length(u) )

  if eigs_to_remove == "neg"
    scale!(Jac, -1.0)
  elseif eigs_to_remove == "pos"
    # do nothing
  elseif eigs_to_remove == "none"
    return
  else
    error("eigs_to_remove specified incorrectly.")
  end

  
  n = size(Jac,1)
  # compute baseline product, 0.5*u.'*(Jac^T + Jac)*u
  prod = zero(T)
  for i = 1:n
    for j = 1:n
      prod += 0.5*(Jac[i,j] + Jac[j,i])*u[i]*u[j]
    end
  end

  #TODO TODO: prod < 0 for eigs_to_remove == "neg"???
  if prod > 0
  # if prod < 0
    # nothing to do
    # println("prod > 0 check hit, not stabilizing")
    return
  end

  # println("prod <= 0, now stabilizing")

  # array A stores the entries in the contraint Jacobian
  # A = zeros(div(n*(n+1),2))
  for i = 1:n
    A[div(i*(i-1),2)+i] = u[i]*u[i]
    for j = 1:(i-1)
      A[div(i*(i-1),2)+j] = 2.0*u[i]*u[j]
    end
  end

  # A *= -prod/dot(A,A)
  scale!(A, -prod/dot(A, A))        # divide by zero! root of NaN.

  # fill!(Jacpert, 0.0)

  #=
  for i = 1:n
    Jacpert[i,i] += A[div(i*(i-1),2)+i]
    for j = 1:(i-1)
      Jacpert[i,j] += A[div(i*(i-1),2)+j]
      Jacpert[j,i] += A[div(i*(i-1),2)+j]
    end
  end
  =#

  for i = 1:n
    Jac[i,i] += A[div(i*(i-1),2)+i]
    for j = 1:(i-1)
      Jac[i,j] += A[div(i*(i-1),2)+j]
      Jac[j,i] += A[div(i*(i-1),2)+j]
    end
  end

  if eigs_to_remove == "neg"    # TODO ???
    scale!(Jac, -1.0)
  end

end     # end function findStablePerturbation!


#=
# This is the old, incorrect way of applying the stabilization. 
# It was in crank_nicolson_ds.jl.
        if opts["stabilize_v"]

          # NOTE: we are now stabilizing inside calcLinearOperator
          error("no evalJacobianStrong call. remove this error only when derivation vs implementation is complete.")

          # Recalculate dRdq
          # filterDiagJac(mesh, opts, real(tmp_imag), clipJacData, stab_A, eigs_to_remove="neg")
          # filterDiagJac(mesh, opts, real(tmp_imag), clipJacData, stab_A, eigs_to_remove="pos")

          # loop over blocks
          # blocksize is set above (during DiagJac init) as mesh.numDofPerNode*mesh.numNodesPerElement
          nblocks = size(stab_A.A, 3)       # third dimension of our block diag Jac is the block index
          ix_petsc_row = zeros(PetscInt, blocksize)
          ix_petsc_col = zeros(PetscInt, blocksize)
          block_to_add = zeros(PetscScalar, blocksize, blocksize)
          for block_ix = 1:nblocks

            # TODO: no offsets present: this may not be correct in parallel
            for row_ix = 1:length(ix_petsc_row)
              # set the row indicies that we will insert into
              ix_petsc_row[row_ix] = blocksize*(block_ix-1)+row_ix
            end
            for col_ix = 1:length(ix_petsc_col)
              ix_petsc_col[col_ix] = blocksize*(block_ix-1)+col_ix
            end

            # println(BSTDOUT, "\n ix_petsc_row: ", ix_petsc_row)
            # println(BSTDOUT, " ix_petsc_col: ", ix_petsc_col)

            for row_ix = 1:length(ix_petsc_row)
              for col_ix = 1:length(ix_petsc_col)
                block_to_add[row_ix, col_ix] = stab_A.A[row_ix, col_ix, block_ix]
              end
            end

            # We should be subtracting, so we should scale block_to_add by -1.0
            scale!(block_to_add, -1.0)

            # now subtract the filtered DiagJac to the actual Jacobian, which will remove the positive eigenvalues of
            #   the strong Jacobian from the actual Jacobian
        
            # Add the negated block to the existing Jac inside the ls_ds LO object
            set_values1!(lo_ds_innermost.A, ix_petsc_row, ix_petsc_col, block_to_add, ADD_VALUES)

          end

          MatAssemblyBegin(lo_ds_innermost.A, MAT_FINAL_ASSEMBLY)
          MatAssemblyEnd(lo_ds_innermost.A, MAT_FINAL_ASSEMBLY)

        end   # end if opts["stabilize_v"]
=#