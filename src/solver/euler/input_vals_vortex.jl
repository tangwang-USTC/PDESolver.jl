# this user supplied file creates a dictionary of arguments
# if a key is repeated, the last use of the key is used
# it is a little bit dangerous letting the user run arbitrary code
# as part of the solver
# now that this file is read inside a function, it is better encapsulated

arg_dict = Dict{Any, Any} (
"var1" => 1,
"var2" => "a",
"var3" => 3.5,
"var4" => [1,2,3],
"var3" => 4,
"run_type" => 5,
"jac_type" => 2,
"order" => 4,
"IC_name" => "ICIsentropicVortex",
"numBC" => 2,
"BC1" => [ 7, 13],
"BC1_name" => "isentropicVortexBC",
"BC2" => [4, 10],
#"BC2_name" => "noPenetrationBC",
"BC2_name" => "isentropicVortexBC",
"delta_t" => 0.005,
"t_max" => 500000.000,
"smb_name" => "src/mesh_files/vortex.smb",
"dmg_name" => "src/mesh_files/vortex.dmg",
"res_abstol" => 1e-10,
"res_reltol" => 1e-10,
"Relfunc_name" => "ICRho1E2U3",
"step_tol" => 1e-10,
"itermax" => 30,
"use_edgestab" => true,
"edgestab_gamma" => -2.0,
"use_filter" => false,
#"use_res_filter" => true,
#"filter_name" => "raisedCosineFilter",
"use_dissipation" => false,
"dissipation_name" => "damp1",
"dissipation_const" => 12.00,

"writeq" => true,
#"perturb_ic" => true,
#"perturb_mag" => 0.001,
#"write_sparsity" => true,
#"write_jac" => true,
"write_edge_vertnums" => true,
"write_face_vertnums" => true,
"write_qic" => true,
"writeboundary" => true,
"write_res" => true,
#"write_counts" => true,
"write_vis" => true,
"solve" => false,
)
