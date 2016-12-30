arg_dict = Dict{ASCIIString,Any}(
"run_type" => 20,
"order" => 1,
"dimensions" => 2,
"smb_name" => "SRCMESHES/tri_3x3_x0-3_y0-3_mesh.smb",
# "IC_name" => "ICx2plust4",
# "IC_name" => "ICx2plust3",
# "IC_name" => "ICx2plust2",
# "IC_name" => "ICallOnes",
"IC_name" => "ICallzero",
"numBC" => 0,
# "BC1" => [0, 1, 2, 3],
# "BC1_name" => "unsteadyVortexBC",
"delta_t" => 0.01,
"t_max" => 4.0,
"res_abstol" => -1.0,
"res_reltol" => -1.0,
"use_DG" => true,
"operator_type" => "SBPGamma",
"Flux_name" => "RoeFlux",
"output_freq" => 100,
"real_time" => true,
"vortex_x0" => 5.0,
"use_itermax" => true,
"itermax" => 1000,
"output_freq" => 1,
"jac_method" => 1,        # 1: FD, 2: CS
"jac_type" => 2,          # 1: dense matrix, 2: Julia sparse
"simpleODE_eqn" => 4,
"use_Minv" => false,
# "write_rhs" => true,
# "write_qic" => true,
# "write_res" => true,
# "write_jac" => true
)
