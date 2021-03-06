# 3D rk4 run

arg_dict = Dict{Any, Any}(
"physics" => "Euler",
"run_type" => 1,
"jac_type" => 2,
"order" => 1,
"use_DG" => true,
"Flux_name" => "RoeFlux",
"IC_name" => "ICExp",
"SRCname" => "SRCExp",
"dimensions" => 3,
"numBC" => 1,
"BC1" => [ 0, 1, 2, 3, 4, 5],
"BC1_name" => "ExpBC",
"delta_t" => 0.00005,
"t_max" => 500.000,
"smb_name" => "SRCMESHES/cube_benchmarksmall.smb",
"dmg_name" => ".null",
"res_abstol" => 1e-8,
"res_reltol" => 1e-20,
"step_tol" => 1e-10,
"itermax" => 3000,
"output_freq" => 100,
"step_tol" => -1.0,
"write_timing" => true,
"do_postproc" => true,
"exact_soln_func" => "ICExp",
"solve" => true,
)
