# types used for preconditioning
# The type definitions and the functions that use them need to be in separate
# files because they need to be included in a particular order

"""
  This type holds all the data needed to calculate a preconditioner based only
  on the volume integrals.  For DG methods, this matrix is block diagonal and
  thus easily invertible.  This preconditioner is applied matrix-free.

  jac_size is numDofPerNode * numNodesPerElememnt (the total number of unknowns
  on an element).

  **Fields**

   * volume_jac: jacobian of the volume integrals of each element, 
                 jac_size x jac_size x numEl
   * ipiv: permutation information, jac_size x numEl
   * is_factored: if true, volume_jac has been factored (LU with partial
                  pivoting), false otherwise
"""
type VolumePreconditioner
  volume_jac::Array{Float64, 3}
  ipiv::Array{BlasInt, 2}
  is_factored::Bool

  """
    Regular constructor

    **Inputs**

     * mesh: the mesh
     * sbp: the SBP operator
     * eqn: AbstractSolutionData
     * opts: options dictionary
  """
  function VolumePreconditioner(mesh::AbstractMesh, sbp, eqn::AbstractSolutionData, opts)

    jac_size = mesh.numDofPerNode*mesh.numNodesPerElement
    numEl = mesh.numEl

    volume_jac = Array(Float64, jac_size, jac_size, numEl)
    ipiv = Array(BlasInt, jac_size, numEl)
    is_factored = false

    return new(volume_jac, ipiv, is_factored)
  end

  """
    Default constructor (think synthesized default constructor in C++.
    Returns an object where all arrays have size zero

    **Inputs**

      none
  """
  function VolumePreconditioner()

    volume_jac = Array(Float64, 0, 0, 0)
    ipiv = Array(BlasInt, 0, 0)
    is_factored = false

    return new(volume_jac, ipiv, is_factored)
  end

end  # end type definition
