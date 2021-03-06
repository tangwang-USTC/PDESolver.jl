include(joinpath(dirname(@__FILE__), "crank_nicolson_CS", "calc_line.jl"))

function test_CN()
  @testset "---- Crank-Nicolson Convergence Tests, Complex Step Jacobian -----" begin
    start_dir = pwd()

    cd(dirname(@__FILE__))
    resize!(ARGS, 1)

    # =================== CN, CS tests ===================
    cd("./crank_nicolson_CS/")
    println("======",pwd())

    cd("./m1")
    println("======", pwd())
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("../m2")
    println("======", pwd())
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

#    cd("../m3")
#    println("======", pwd())
#    fname = "input_vals1.jl"
#    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("..")
    println("======", pwd())
    fname = "calc_line.jl"  #???
#    mesh, sbp, eqn, opts = solvePDE(fname)

    slope = calc_line()
    # println("slope = ", slope)

    data = readdlm("err_data.dat")
    err_vals = data[:, 2]
    #println("err_vals = ", err_vals)

    slope_val = 2.00
    slope_margin = 0.1

    @test  slope  > slope_val - slope_margin
    @test  slope  < slope_val + slope_margin

    err_val = 0.09095728504176116 
    slope_fac = 1.25
    # println("err_vals[1] = ", err_vals[1])
    @test  err_vals[1]  > err_val/slope_fac
    @test  err_vals[1]  < err_val*slope_fac

    cd("../")
    # =================== CN, FD tests ===================
    cd("./crank_nicolson_FD/")

    cd("./m1")
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("../m2")
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

#    cd("../m3")
#    fname = "input_vals1.jl"
#    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("..")
    fname = "calc_line.jl"
#    mesh, sbp, eqn, opts = solvePDE(fname)  #???

    slope = calc_line()
    # println("slope = ", slope)

    data = readdlm("err_data.dat")
    err_vals = data[:, 2]
    #println("err_vals = ", err_vals)

    slope_val = 2.00
    slope_margin = 0.1

    @test  slope  > slope_val - slope_margin
    @test  slope  < slope_val + slope_margin

    err_val = 0.09095728504176116 
    slope_fac = 1.25
    # println("err_vals[1] = ", err_vals[1])
    @test  err_vals[1]  > err_val/slope_fac
    @test  err_vals[1]  < err_val*slope_fac

    cd("../")
    # =================== CN, PETSc CS tests =================== 
    cd("./crank_nicolson_PETSc_serial/")

    cd("./m1")
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("../m2")
    fname = "input_vals1.jl"
    mesh, sbp, eqn, opts = solvePDE(fname)

#    cd("../m3")
#    fname = "input_vals1.jl"
#    mesh, sbp, eqn, opts = solvePDE(fname)

    cd("..")
    fname = "calc_line.jl"
#    mesh, sbp, eqn, opts = solvePDE(fname) #???

    slope = calc_line()
    # println("slope = ", slope)

    data = readdlm("err_data.dat")
    err_vals = data[:, 2]
    #println("err_vals = ", err_vals)

    slope_val = 2.00
    slope_margin = 0.1

    @test  slope  > slope_val - slope_margin
    @test  slope  < slope_val + slope_margin

    err_val = 0.09095728504176116 
    slope_fac = 1.25
    # println("err_vals[1] = ", err_vals[1])
    @test  err_vals[1]  > err_val/slope_fac
    @test  err_vals[1]  < err_val*slope_fac

    cd(start_dir)
  end  # end facts block

end

add_func1!(AdvectionTests, test_CN, [TAG_SHORTTEST, TAG_CN])
