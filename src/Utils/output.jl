# output functions


@doc """
### EulerEquationMod.printSolution

  This function prints the solution vector u to a file named solution.dat.
  Each line contains: element number, local node number, and the 4 conservative
  variable values.

  Inputs:
   * mesh :: PumiMesh2
   * u  : vector of values
"""->
function printSolution(mesh::AbstractMesh, u::AbstractVector)
# print solution to file
# format = for each element, node, print u rho*u rho*v E

println("entered printSolution")
f = open("solution.dat", "w")

for i=1:mesh.numEl
  dofnums_i = getGlobalNodeNumbers(mesh, i)

  for j=1:3
    u_vals = u[dofnums_i[:, j]]
    str = @sprintf("%d %d %16.15e %16.15e %16.15e %16.15e \n", i, j, u_vals[1], u_vals[2], u_vals[3], u_vals[4] )  # print element number

    print(f, str)
  end
#  print(f, "\n")
end

close(f)
return nothing

end

@doc """
### EulerEquationMod.printCoordinates

  This function prints the mesh vertex coordinates in the same format 
  as printSolution prints the solution vector.

  Inputs:
    * mesh :: PumiMesh2
"""->
function printCoordinates(mesh::AbstractMesh)
# print solution to file
# format = for each element, node, print u rho*u rho*v E

myrank = mesh.myrank
println("entered printCoordinates")
writedlm("coords_output_$myrank.dat", mesh.coords)

return nothing

end

@doc """
### EulerEquationMod.printSolution

  This function prints the solution vector to the file with the given name.
  The solution vector is printed one value per line.

  Inputs:
    * name : AbstractString naming file, including extension
    * u  : vector to print
"""->
function printSolution(name::AbstractString, u::AbstractVector)

  f = open(name, "a+")

  for i=1:length(u)
    write(f, string(u[i], "\n"))
  end

  close(f)

  return nothing
end


@doc """
### EulerEquationMod.printMatrix

  This function prints a 2D matrix of Float64s to a file with the given name

  Inputs:
    * name  : AbstractString naming file, including extension
    * u  : matrix to be printed
"""->
function printMatrix(name::AbstractString, u::AbstractArray{Float64, 2})
# print a matrix to a file, in a readable format

(m,n) = size(u)

f = open(name, "a+")

for i=1:m
  for j=1:n
    str = @sprintf("%16.15e", u[i,j])
    print(f, str)
    if j < n  # don't put space at end of line
      print(f, " ")
    end
  end

  print(f, "\n")
end

close(f)
return nothing

end

function printMatrix{T}(name::AbstractString, u::AbstractArray{T, 3})
# print a matrix to a file, in a quasireadable format

#println("printing 3d matrix")
(tmp, m,n) = size(u)
#println("numel = ", n)
#println("nnodes = ", m)

f = open(name, "a+")

for i=1:n  # loop over elements
  for j=1:m  # loop over nodes on element
#    str = @sprintf("%16.15e", u[i,j])
    println(f, "el ", i, " node ", j, " flux = ", u[:, j, i] )
#    if j < n  # don't put space at end of line
#      print(f, " ")
#    end
  end

#  print(f, "\n")
end

close(f)
return nothing

end
