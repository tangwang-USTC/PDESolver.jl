# functions that populate the initial conditions
# List of functions:
#   ICZero (all zeros)
#   ICRho1E2 (all zeros, except rho = 1, E = 2)
#   ICLinear
#   ICsmoothHeavisideder
#   ICsmoothHeaviside
#   ICIsentropicVortex

export ICZero, ICRho1E2, ICLinear, ICsmoothHeavisideder, ICsmoothHeaviside, ICIsentropicVortex

function ICZero(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      # apply initial conditions here
      u0[dofnum_rho] = 0.0
      u0[dofnum_rhou] = 0.0
      u0[dofnum_rhov] = 0.0
      u0[dofnum_e] = 0.0
  end
end

return nothing

end  # end function

function ICRho1E2(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      # apply initial conditions here
      u0[dofnum_rho] = 1.0
      u0[dofnum_rhou] = 0.0
      u0[dofnum_rhov] = 0.0
      u0[dofnum_e] = 2.0
  end
end

return nothing

end  # end function


function ICRho1E2U3(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
sol = zeros(4)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      calcRho1Energy2U3(coords[:,j], eqn, sol)


      # apply initial conditions here
#      u0[dofnum_rho] = 1.0
#      u0[dofnum_rhou] = 3.0
#      u0[dofnum_rhov] = 0.0
#      u0[dofnum_e] = 2.0

      u0[dofnums_i[:,j]] = sol
  end
end

return nothing

end  # end function



function ICVortex(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
sol = zeros(4)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      calcVortex(coords[:,j], eqn, sol)


      # apply initial conditions here
#      u0[dofnum_rho] = 1.0
#      u0[dofnum_rhou] = 3.0
#      u0[dofnum_rhov] = 0.0
#      u0[dofnum_e] = 2.0

      u0[dofnums_i[:,j]] = sol
  end
end

return nothing

end  # end function




function ICLinear(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
dofnums_i = zeros(dofpernode)

cntr = 1
for i=1:mesh.numVert
  for j=1:dofpernode
    dofnums_i[j] = getNumberJ(mesh.dofnums_Nptr, mesh.verts[i], 0, j-1)
  end

      dofnum_rho = dofnums_i[1]
      dofnum_rhou = dofnums_i[2]
      dofnum_rhov = dofnums_i[3]
      dofnum_e = dofnums_i[4]


      # apply initial conditions here
      u0[dofnum_rho] = cntr
      u0[dofnum_rhou] = cntr+1
      u0[dofnum_rhov] = cntr+2
      u0[dofnum_e] = cntr+3

      cntr += 4
end

return nothing

end  # end function


function ICsmoothHeavisideder(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# calculate the value of the smooth heaviside function derivative at a location x
# x0 is specified within this function

# smooth heaviside  parameters
  x0 = 0
  L = 5
  k = 5



numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      # apply initial conditions here
      u0[dofnum_rho] = L*(2*k*e^(-2*k*x))/(e^(-2*k*x) +1 )^2
      u0[dofnum_rhou] = 0.0
      u0[dofnum_rhov] = 0.0
      u0[dofnum_e] = 0.0
  end
end

return nothing



end

function ICsmoothHeaviside(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# calculate the value of the smooth heaviside function at a location x
# x0 is specified within this function

# smooth heaviside  parameters
  x0 = 0
  L = 5
  k = 5



numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes
      # get dof numbers for each variable
      dofnum_rho = dofnums_i[1,j]
      dofnum_rhou = dofnums_i[2,j]
      dofnum_rhov = dofnums_i[3,j]
      dofnum_e = dofnums_i[4,j]

      # coordinates of this node (must be a vertex)
      x = coords[1,j]
      y = coords[2,j]
      z = coords[3,j]

      # apply initial conditions here
      u0[dofnum_rho] = L/(1 + e^(-k*(x-x0)))
      u0[dofnum_rhou] = 0.0
      u0[dofnum_rhov] = 0.0
      u0[dofnum_e] = 0.0
  end
end

return nothing



end

function ICIsentropicVortex(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
sol = zeros(4)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes

      # coordinates of this node (must be a vertex)
      coords_j = coords[:,j]
      calcIsentropicVortex(coords_j, eqn, sol)

      # apply initial conditions here
      u0[dofnums_i[:,j]] = sol
  end
end

return nothing

end  # end function

function ICIsentropicVortexWithNoise(mesh::AbstractMesh, operator::SBPOperator, eqn::EulerEquation, u0::AbstractVector)
# populate u0 with initial values
# this is a template for all other initial conditions

numEl = getNumEl(mesh)
nnodes = operator.numnodes
dofpernode = getNumDofPerNode(mesh)
sol = zeros(4)
for i=1:numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)  # get dof nums for this element
  coords = getElementVertCoords(mesh, [i])

  for j=1:nnodes

      # coordinates of this node (must be a vertex)
      coords_j = coords[:,j]
      calcIsentropicVortex(coords_j, eqn, sol)

      # apply initial conditions here
#       u0[dofnums_i[:,j]] = sol
      u0[dofnums_i[:,j]] = sol+0.1*rand(4)
  end
end

return nothing

end  # end function


