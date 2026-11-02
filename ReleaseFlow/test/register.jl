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
          "api repos/"*"/comments")
            if [ "$GH_TOKEN" = "refused" ]; then
              echo "gh: Resource not accessible by integration (HTTP 403)" >&2
              exit 1
            fi
            echo "https://github.com/Example/Toy.jl/commit/abc#comment";;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    log = joinpath(directory, "log")
    work = mkpath(joinpath(directory, "work", "lib", "Toy"))
    write(joinpath(work, "Project.toml"), project("1.2.0"))
    # The step runs with what its caller gives, its secrets, inputs and the outputs of the registration job, and the workflow's own token, repository and commit.
    function step(name, contexts::Pair...)
        script = joinpath(directory, "step.sh")
        write(script, workflow_step("register.yml", name))
        write(log, "")
        summary = joinpath(directory, "summary")
        write(summary, "")
        given = Dict("github.token" => "token", "github.repository" => "Example/Toy.jl", "github.sha" => "abc", contexts...)
        environment = merge(workflow_environment("register.yml", name, given), Dict("PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "GITHUB_STEP_SUMMARY" => summary))
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = joinpath(directory, "work"), ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), log = read(log, String), summary = read(summary, String))
    end

    # The register job takes the caller's permissions, since a called job that asks for more than its caller grants doesn't start.
    @testset "permissions" begin
        @test !any(line -> occursin("permissions", line), workflow_jobs("register.yml")["register"])
        @test !any(line -> startswith(line, "permissions"), readlines(normpath(joinpath(@__DIR__, "..", "..", ".github", "workflows", "register.yml"))))
    end

    @testset "comment" begin
        comment(contexts::Pair...) = step("Comment for Registrator", "needs.registration.outputs.version" => "1.2.0", contexts...)
        result = comment("secrets.REGISTRATOR_TOKEN" => "token", "inputs.project" => "lib/Toy/", "needs.registration.outputs.notes" => "- A feature.")
        @test result.code == 0
        @test startswith(result.log, "gh api repos/Example/Toy.jl/commits/abc/comments -f body=@JuliaRegistrator register subdir=lib/Toy\n\nRelease notes:\n\n- A feature.")
        # A package at the root names no subdirectory, and a release without notes has none.
        result = comment("secrets.REGISTRATOR_TOKEN" => "token")
        @test occursin("-f body=@JuliaRegistrator register --jq", result.log)
        # The version and notes of the registration job that ran from the checked-out commit, under `local-action`.
        result = step("Comment for Registrator", "needs.registration-local.outputs.version" => "1.2.0", "needs.registration-local.outputs.notes" => "- A feature.")
        @test result.code == 0 && occursin("Release notes:\n\n- A feature.", result.log) && occursin("for 1.2.0", result.output)
        # Without REGISTRATOR_TOKEN, the workflow's own token comments.
        result = comment()
        @test result.code == 0 && occursin("-f body=@JuliaRegistrator register --jq", result.log)
        # The workflow's own token, refused without contents: write: the error gives GitHub's message and the permission, and the summary the comment to make by hand.
        result = comment("github.token" => "refused", "inputs.project" => "lib/Toy", "needs.registration.outputs.notes" => "- A feature.")
        @test result.code == 1
        @test occursin("::error title=Register::", result.output) && occursin("Resource not accessible by integration (HTTP 403)", result.output)
        @test occursin("contents: write", result.output)
        @test occursin("comment `@JuliaRegistrator register subdir=lib/Toy` on abc by hand", result.output)
        @test occursin("## Register 1.2.0", result.summary)
        @test occursin("```\n@JuliaRegistrator register subdir=lib/Toy\n\nRelease notes:\n\n- A feature.\n```", result.summary)
        # A REGISTRATOR_TOKEN that GitHub refuses: the error says what the token must be.
        result = comment("secrets.REGISTRATOR_TOKEN" => "refused")
        @test result.code == 1
        @test occursin("REGISTRATOR_TOKEN", result.output) && occursin("Resource not accessible", result.output)
        @test occursin("write access to Example/Toy.jl", result.output)
        # Given neither token, there's nothing to comment with.
        result = comment("github.token" => "")
        @test result.code == 1 && occursin("REGISTRATOR_TOKEN", result.output) && occursin("GITHUB_TOKEN", result.output) && isempty(result.log)
    end
end
