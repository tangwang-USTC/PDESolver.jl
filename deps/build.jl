# download and build all non metadata dependences
include("build_funcs.jl")

function installPDESolver()

  f = open("install.log", "a+")
  #------------------------------------------------------------------------------
  # these packages are always installed manually
  #-----------------------------------------------------------------------------
  # [pkg_name, git url, commit identified]
  std_pkgs = ["SummationByParts" "https://github.com/OptimalDesignLab/SummationByParts.jl.git" "c72ccc564d165e7e4fed5dba12da908fbb6dba27";
              "ODLCommonTools" "https://github.com/OptimalDesignLab/ODLCommonTools.jl.git" "HEAD";
              "PumiInterface" "https://github.com/OptimalDesignLab/PumiInterface.jl.git" "HEAD"
              "MPI" "git@github.com:JuliaParallel/MPI.jl.git" "909b61426dc802a332109d729b8540f730377499"
              ]


  # manually install MPI until the package matures
  # handle Petsc specially until we are using the new version
  petsc_git = "git@github.com:JaredCrean2/Petsc.git"

  pkg_dict = Pkg.installed()  # get dictionary of installed package names to version numbers

  # force installation to a specific commit hash even if package is already present
  # or would normally be install via the REQUIRE file

  global const FORCE_INSTALL_ALL = haskey(ENV, "PDESOLVER_FORCE_DEP_INSTALL_ALL")


  println(f, "\n---Installing non METADATA packages---\n")
  for i=1:size(std_pkgs, 1)
    pkg_name = std_pkgs[i, 1]
    git_url = std_pkgs[i, 2]
    git_commit = std_pkgs[i, 3]

    install_pkg(pkg_name, git_url, git_commit, pkg_dict, f)
  end


  # now install PETSc
  pkg_name = "PETSc"
  git_url = petsc_git
  already_installed = haskey(pkg_dict, pkg_name) 
  force_specific = haskey(ENV, "PDESOLVER_FORCE_DEP_INSTALL_$pkg_name") 

  if !already_installed  || force_specific  || FORCE_INSTALL_ALL
    println(f, "Installing package $pkg_name")
    try 

      start_dir = pwd()
      cd(Pkg.dir() )
      run(`git clone $petsc_git`)
      mv("./Petsc", "./PETSc")
      Pkg.build("PETSc")
      cd(start_dir)
      println(f, "  Installation appears to have completed sucessfully")
    catch x
      println(f, "Error installing package $pkg_name")
      println(f, "Error is $x")
    end

  else
    println(f, "Skipping installation of package $pkg_name")
    println(f, "  already installed: ", already_installed, ", specifically forced: ", force_specific,
               ", force general: ", FORCE_INSTALL_ALL)
  end


  println(f, "\n---Finished installing non METADATA packages---\n")
  #------------------------------------------------------------------------------
  # these packages are not always installed manually
  # this section provides a backup mechanism if the regular version resolution
  # mechanism fails
  #------------------------------------------------------------------------------

  # array of [pkg_name, commit_hash]
  pkg_list = [ "Compat" "3bbd9536360ac0925b4535036b79d8eb547db977";
               "URIParser" "3c00f48119909eb105aff6f126611b39a7b16919";
               "FactCheck" "e3caf3143b13d4ce9bc576579d5ed9cd4aaefb11";
               "ArrayViews" "40439daf99155b751d53c6403a5bd35fa0340f7a";
               "SHA" "0e31e9d265eede8cafc9f0c04e928acf5b0fa4cf";
               "BinDeps" "d57430a7e55546b9545054cfb5c34724dbed1795";
               "NaNMath" "b2148ab8461d73563dd4b7033e9a6546ec355328";
               "Calculus" "4548c2204988c0d6551b0a7605ad3f4dee17b702";
               "DualNumbers" "a9a47656fb6b70e5788551696f133cbe7886ea7b";
               "ForwardDiff" "6da5f5204fd717a1417a8a4a6b9e2253799879c9";
               "Debug" "8c4801a6ca6368c6b5175c18a9d666a5694c1c3b"
               ]

    println(f, "\n---Considering manual package installations---\n")
    for i=1:size(pkg_list, 1)

      pkg_name = pkg_list[i, 1]
      git_commit = pkg_list[i, 2]

      if haskey(ENV, "PDESOLVER_INSTALL_DEPS_MANUAL") || haskey(ENV, "PDESOLVER_FORCE_DEP_INSTALL_$pkg_name") 

        install_pkg(pkg_name, pkg_name, git_commit, pkg_dict, f, force=true)
      end
    end

    println(f, "\n---Finished manual package installations---\n")

  close(f)

  # generate the known_keys dictonary
  start_dir = pwd()
  input_path = joinpath(Pkg.dir("PDESolver"), "src/input")
  cd(input_path)
  include(joinpath(input_path, "extract_keys.jl"))
  cd(start_dir)

end  # end function


# run the installation
installPDESolver()
