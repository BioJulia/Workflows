# Registering a release
# ---------------------

@testset "Register" begin
    @testset "registration" begin
        directory, released, feature = gitflow_repository()
        release!(directory, "release/v0.2.0", feature, "0.2.0")
        on(variables...) = (path = tempname(); result = check(directory, "registration"; GITHUB_OUTPUT = path, variables...); (; result, outputs = outputs(path)))
        registration = on()
        @test passes(registration.result)
        @test registration.outputs["version"] == "0.2.0" && registration.outputs["register"] == "true"
        @test registration.outputs["notes"] == "- A feature."
        registration = on(:RELEASEFLOW_REGISTRY => registry("0.2.0" => tree(directory, "release/v0.2.0")))
        @test registration.outputs["register"] == "false"
        @test occursin("already records 0.2.0, so there's nothing to register", registration.result.output)
        # A registry that doesn't know the package: its first release is registered by hand, which the check says how.
        unknown = mktempdir()
        write(joinpath(unknown, "Registry.toml"), "name = \"Scratch\"\nuuid = \"6d8a9f4e-0000-4000-8000-000000000000\"\nrepo = \"https://example.invalid/Scratch.git\"\n\n[packages]\n")
        registration = on(:RELEASEFLOW_REGISTRY => unknown)
        @test passes(registration.result) && registration.outputs["register"] == "false"
        @test occursin("::warning title=Registration::Scratch doesn't know Toy yet, so its first release, 0.2.0, is registered by hand: comment `@JuliaRegistrator register` on the commit $(git(directory, "rev-parse", "release/v0.2.0")).", registration.result.output)
        @test occursin("A new package's first version must be 0.0.1, 0.1.0 or X.0.0, which 0.2.0 isn't.", registration.result.output)
        release!(directory, "release/v0.1.0", feature, "0.1.0")
        registration = on(:RELEASEFLOW_REGISTRY => unknown)
        @test registration.outputs["register"] == "false" && !occursin("first version must be", registration.result.output)
        # A registry that can't be read: whether to register is unknown, so the check fails and doesn't register.
        registration = on(:RELEASEFLOW_REGISTRY => mktempdir())
        @test fails(registration.result, "couldn't be read, so whether it records 0.1.0 is unknown") && registration.outputs["register"] == "false"
    end

    # The shell of a step of the register workflow, run in `work` with a stand-in for `gh` that logs its calls.
    directory = mktempdir()
    bin = mkpath(joinpath(directory, "bin"))
    write(
        joinpath(bin, "gh"), raw"""
        #!/bin/bash
        echo "gh $*" >> "$LOG"
        case "$1 $2" in
          "api repos/"*"/comments") echo "https://github.com/Example/Toy.jl/commit/abc#comment";;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    log = joinpath(directory, "log")
    work = mkpath(joinpath(directory, "work", "lib", "Toy"))
    write(joinpath(work, "Project.toml"), project("1.2.0"))
    function step(name; variables...)
        script = joinpath(directory, "step.sh")
        write(script, workflow_step("register.yml", name))
        write(log, "")
        environment = Dict("PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "REPOSITORY" => "Example/Toy.jl", "SHA" => "abc")
        for (key, value) in variables
            environment[string(key)] = string(value)
        end
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = joinpath(directory, "work"), ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), log = read(log, String))
    end

    @testset "comment" begin
        result = step("Comment for Registrator"; GH_TOKEN = "token", RELEASEFLOW_PROJECT = "lib/Toy/", VERSION = "1.2.0", NOTES = "- A feature.")
        @test result.code == 0
        @test startswith(result.log, "gh api repos/Example/Toy.jl/commits/abc/comments -f body=@JuliaRegistrator register subdir=lib/Toy\n\nRelease notes:\n\n- A feature.")
        # A package at the root names no subdirectory, and a release without notes has none.
        result = step("Comment for Registrator"; GH_TOKEN = "token", RELEASEFLOW_PROJECT = "", VERSION = "1.2.0", NOTES = "")
        @test occursin("-f body=@JuliaRegistrator register --jq", result.log)
        # Without the machine user's token, Registrator wouldn't act.
        result = step("Comment for Registrator"; GH_TOKEN = "", RELEASEFLOW_PROJECT = "", VERSION = "1.2.0", NOTES = "")
        @test result.code == 1 && occursin("needs REGISTRATOR_TOKEN", result.output) && isempty(result.log)
    end
end
