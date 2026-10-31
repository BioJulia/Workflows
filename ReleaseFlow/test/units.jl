# Unit tests
# ----------

const R = ReleaseFlow

@testset "Units" begin
    @testset "changelog" begin
        parsed = R.sections(changelog(unreleased = ["A feature."], released = ["0.2.0" => ["Second."], "0.1.0" => ["First."]]))
        @test parsed[1] isa R.Section{R.Unreleased}
        @test R.versions(parsed) == [v"0.2.0", v"0.1.0"]
        @test R.unreleased_entries(parsed) == ["- A feature."]
        @test R.is_version(parsed[2], v"0.2.0") && !R.is_version(parsed[1], v"0.2.0")
        @test R.heading("## [0.3.0] - 2026-10-19") == R.Released(v"0.3.0")
        @test R.heading("## v0.3.0") == R.Released(v"0.3.0")
        @test R.heading("## UNRELEASED") isa R.Unreleased
        @test R.heading("## Added") isa R.Other
        @test R.is_entry("- x") && R.is_entry("* x") && R.is_entry("+ x") && !R.is_entry("x") && !R.is_entry("-x")
        breaking = R.sections(changelog(released = ["0.2.0" => ["Second."], "0.1.0" => ["First."]], breaking = ["Removed `triple`."]))
        @test R.subsection_entries(breaking[2], "Breaking") == 1
        @test R.subsection_entries(breaking[3], "Breaking") == 0
    end

    @testset "links" begin
        definitions = R.links("[0.1.0]: $(URL)/releases/tag/v0.1.0\n[Unreleased]: $(URL)/compare/v0.1.0...HEAD\n")
        @test definitions["0.1.0"] == "$(URL)/releases/tag/v0.1.0"
        @test definitions["unreleased"] == "$(URL)/compare/v0.1.0...HEAD"
        @test R.from_earlier("$(URL)/compare/v0.0.9...v0.1.0", URL, v"0.1.0")
        @test !R.from_earlier("$(URL)/compare/v0.2.0...v0.1.0", URL, v"0.1.0")
        @test !R.from_earlier("$(URL)/compare/v0.0.9...0.1.0", URL, v"0.1.0")
    end

    @testset "versions" begin
        @test R.single_steps(v"0.1.0") == (v"0.1.1", v"0.2.0", v"1.0.0")
        @test R.breaking_steps(v"0.1.3") == (v"0.2.0", v"1.0.0")
        @test R.breaking_steps(v"1.2.3") == (v"2.0.0",)
    end

    @testset "branches" begin
        branch(name; variables...) = R.head_branch(R.Settings(Dict("RELEASEFLOW_HEAD_REF" => name, (string(key) => string(value) for (key, value) in variables)...)))
        @test branch("hotfix/v0.1.1") == R.Branch{R.Hotfix}("hotfix/v0.1.1", v"0.1.1")
        @test branch("release/v0.2.0") == R.Branch{R.Release}("release/v0.2.0", v"0.2.0")
        @test branch("release/next") == R.Branch{R.Release}("release/next")
        @test branch("main") isa R.Branch{R.BackMerge}
        @test branch("back-merge/v0.1.0") isa R.Branch{R.BackMerge}
        @test branch("feature/x") isa R.Branch{R.Feature}
        @test branch("main"; RELEASEFLOW_MAIN_BRANCH = "master") isa R.Branch{R.Feature}
        @test R.kind_name(R.Branch{R.Hotfix}("hotfix/x")) == "hotfix"
        @test R.kind_name(R.Branch{R.Feature}("feature/x")) == "release"
    end

    @testset "models" begin
        settings(model) = R.Settings(Dict("RELEASEFLOW_MODEL" => model))
        @test settings("gitflow") isa R.Settings{R.Gitflow}
        @test settings("oneflow") isa R.Settings{R.OneFlow}
        @test settings("trunk") isa R.Settings{R.Trunk}
        @test R.title(R.OneFlow()) == "OneFlow"
        # Who needs no changelog entry depends on the model and the kind of branch.
        @test R.exemption(settings("gitflow"), R.Branch{R.BackMerge}("main")) == "main brings main back into develop"
        @test R.exemption(settings("gitflow"), R.Branch{R.Release}("release/v0.2.0")) === nothing
        @test R.exemption(settings("oneflow"), R.Branch{R.Release}("release/v0.2.0")) == "The pull request is a release"
        @test R.exemption(settings("oneflow"), R.Branch{R.BackMerge}("main")) === nothing
        @test R.exemption(settings("trunk"), R.Branch{R.Feature}("feature/x")) === nothing
    end

    @testset "last release" begin
        @test R.label(R.LastRelease{R.Registered}(v"0.1.0", "0123abc")) == "the release 0.1.0"
        @test R.label(R.LastRelease{R.Tagged}(v"0.1.0", "v0.1.0")) == "the release 0.1.0"
        @test R.label(R.LastRelease{R.MainBranch}(v"0.1.0", "origin/main")) == "origin/main"
    end

    @testset "compat" begin
        base = Dict("deps" => Dict("A" => "uuid"), "compat" => Dict("julia" => "1.10", "A" => "1"))
        narrowed, other = R.compat_changes(base, Dict("deps" => Dict("A" => "uuid"), "compat" => Dict("julia" => "1.11", "A" => "1, 2")))
        @test length(narrowed) == 1 && startswith(only(narrowed), "julia:")
        @test only(other) == "A: \"1\" → \"1, 2\""
        narrowed, other = R.compat_changes(base, Dict("deps" => Dict("A" => "uuid", "B" => "uuid"), "compat" => Dict("julia" => "1.10", "A" => "1", "B" => "0.3")))
        @test isempty(narrowed) && only(other) == "B: added \"0.3\""
        # The bounds of packages that only the tests use don't count.
        narrowed, other = R.compat_changes(Dict("compat" => Dict("Test" => "1")), Dict("compat" => Dict("Test" => "1.11")))
        @test isempty(narrowed) && isempty(other)
    end

    @testset "test failures" begin
        directory = mktempdir()
        file = joinpath(directory, "test", "runtests.jl")
        output = """
        Toy: Test Failed at $(file):4
          Expression: triple(2) == 6
           Evaluated: 7 == 6
          Stacktrace:
           [1] top-level scope
             @ $(file):4

        Toy: Error During Test at $(file):6
          Test threw exception
          Expression: error("boom")
          boom
          Stacktrace:
           [1] error(s::String)
        Test Summary: | Fail  Error  Total  Time
        Toy           |    1      1      2  0.1s
        """
        failures = R.test_failures(output, directory)
        @test failures[1] == "Toy: Test Failed at test/runtests.jl:4\n  Expression: triple(2) == 6\n   Evaluated: 7 == 6"
        @test failures[2] == "Toy: Error During Test at test/runtests.jl:6\n  Test threw exception\n  Expression: error(\"boom\")\n  boom"
        @test length(failures) == 2
        @test isempty(R.test_failures("Test Summary: | Pass  Total\n", directory))
    end

    @testset "main" begin
        @test redirect_stderr(() -> R.main(String[]), devnull) == 2
        @test redirect_stderr(() -> R.main(["nonsense"]), devnull) == 2
        @test redirect_stderr(() -> R.main(["source"]; environment = Dict("RELEASEFLOW_MODEL" => "kanban")), devnull) == 2
        @test isempty(Test.detect_ambiguities(ReleaseFlow))
    end
end
