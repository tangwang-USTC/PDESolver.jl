arg_dict = Dict{String,Any}(
"physics" => "Advection",
"run_type" => 20,
"order" => 1,
"dimensions" => 2,
"smb_name" => "SRCMESHES/square_x0-2_y0-2_4x4_tri.smb",
"IC_name" => "ICsinwave",
"numBC" => 1,
"BC1" => [0, 1, 2, 3],
# "BC1" => [0],
"BC1_name" => "sinwaveBC",
"delta_t" => 0.5,
"t_max" => 1.0,
# "res_abstol" => -1.0,
# "res_reltol" => -1.0,
"use_DG" => true,
"operator_type" => "SBPGamma",
# "Flux_name" => "RoeFlux",
"Flux_name" => "LFFlux",
"output_freq" => 100,
"real_time" => true,
"vortex_x0" => 5.0,
"use_itermax" => true,
"itermax" => 1000,
"output_freq" => 1,
"jac_method" => 1,        # 1: FD
"jac_type" => 2,          # 1: dense matrix, 2: Julia sparse
"do_postproc" => true,
"exact_soln_func" => "ICsinwave",
"use_Minv" => true,
)
