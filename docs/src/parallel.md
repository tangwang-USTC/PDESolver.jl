# Parallel Overview

This document describes how PDEs are solved in parallel.

In general, the mesh is partitioned and each part is assigned to a different
MPI process. Each element is owned by exactly one process.  During 
initialization, the mesh constructor on each process figures out which other
processes have elements that share a face (edge in 2D) with local elements.
It counts how many faces and elements are shared (a single element could have
multiple faces on the parallel boundary), and assigns local number to both the
elements and the degrees of freedom on the elements.  The non-local elements 
are given numbers greater than `numEl`, the number of local elements.  
The degrees of freedom are re-numbered such that newly assigned dof number plus the `dof_offset`
for the current process equals the global dof number, which is defined by
the local dof number assigned by the process that owns the element.  As a 
result, dof numbers for elements that live on processes with lower ranks
will be negative.

As part of counting the number of shared faces and elements, 3 arrays are
formed: `bndries_local`, `bndries_remote`, and `shared_interfaces` which 
describe the shared faces from the local side, the remote side, and a 
unified view of the interface, respectively.  This allows treating the
shared faces like either a special kind of boundary condition or a proper 
interface, similar to the interior interfaces.

There are 2 modes of parallel operation, one for explicit time marching and
the other for Newton's method.

## Explicit Time Marching

In this mode, each process each process sends the solution values at the 
shared faces to the other processes.  Each process then evaluates the residual
using the received values and updates the solution.

The function `exchangeFaceData` is designed to perform the sending and 
receiving of data.  Non-blocking communications are used, and the function
does not wait for the communication to finish before returning.  The 
MPI_Requests for the sends and receives are stored in the appropriate fields
of the mesh.  It is the responsibility of each physics module call 
`exchangeFaceData` and to wait for the communication to finish before using
the data.  Because the receives could be completed in any order, it is 
recommended to use `MPI_Waitany` to wait for the first receive to complete, 
do as many computations as possible on the data, and then call `MPI_Waitany`
again for the next receive.

## Newton's Method

For Newton's method, each process sends the solution values for all the 
elements on the shared interface at the beginning of a Jacobian calculation. 
Each process is then responsible for perturbing the solutions values of both 
the local and non-local elements.  The benefit of this is that parallel 
communication is required once per Jacobian calculation, rather than once 
per residual evaluation as with the explicit time marching mode.

The function `exchangeElementData` copies the data from the shared elements
into the send buffer and sends it, and also posts the corresponding receives.
It does not wait for the communications to finish before returning.  
The function is called by Newton's method after a new solution is calculated,
so the physics module does not have to do it, but the physics module does 
have to wait for the receives to finish before using the data.  This is 
necessary to allow overlap of the communication with computation.  As 
with the explicit time marching mode, use of `MPI_Waitany` is recommended. 
