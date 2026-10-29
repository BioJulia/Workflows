# The release workflow
# --------------------

@testset "Release workflow" begin
    directory = mktempdir()
    script = joinpath(directory, "step.sh")
    write(script, workflow_step("release.yml", "Push the branch and open the pull request"))
    # A stand-in for `gh`: it logs its calls, and gives the app's bot an ID.
    bin = mkpath(joinpath(directory, "bin"))
    write(
        joinpath(bin, "gh"), raw"""
        #!/bin/bash
        echo "gh $*" >> "$LOG"
        case "$1 $2" in
          "api users/"*) echo 4242;;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    origin = joinpath(directory, "origin.git")
    run(pipeline(`git init -q --bare $(origin)`))
    work = repository()
    git(work, "remote", "set-url", "origin", origin)
    commit!(work, "Start", "Project.toml" => project("0.1.0"), "CHANGELOG.md" => changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]]))
    git(work, "push", "-q", "origin", "HEAD:develop")
    log = joinpath(directory, "log")

    # The prepared changes, uncommitted, as the action leaves them.
    function step(; kind = "release", version = "0.1.1", app = "toy-release", branch = "$(kind)/v$(version)")
        git(work, "checkout", "-q", "-f", "--detach", "origin/develop")
        write(joinpath(work, "Project.toml"), project(version))
        write(log, "")
        environment = Dict(
            "PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "GH_TOKEN" => "token", "APP_SLUG" => app, "REPOSITORY" => "Example/Toy.jl",
            "RELEASEFLOW_KIND" => kind, "VERSION" => version, "BRANCH" => branch, "BASE" => "master", "NOTES" => "- A feature.",
        )
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = work, ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), calls = readlines(log))
    end
    pushed(branch) = git(origin, "log", "-1", "--format=%an <%ae> %s", "refs/heads/$(branch)")

    # A release: the branch is pushed as the app's bot, and its pull request opened into the base.
    result = step()
    @test result.code == 0
    @test pushed("release/v0.1.1") == "toy-release[bot] <4242+toy-release[bot]@users.noreply.github.com> Release 0.1.1"
    create = only(filter(call -> startswith(call, "gh pr create"), result.calls))
    @test occursin("--base master --head release/v0.1.1 --title Release 0.1.1", create)
    # The body spans lines of the log, so the flag ends the last of them.
    @test endswith(rstrip(read(log, String)), "--draft=false")
    @test occursin("- A feature.", read(log, String))
    # A branch that exists is an earlier preparation, which isn't overwritten.
    result = step()
    @test result.code == 1 && occursin("The branch release/v0.1.1 exists already", result.output)
    # A hotfix's pull request is a draft, until the fix is pushed; with a personal token, the commit is GitHub Actions'.
    result = step(; kind = "hotfix", version = "0.1.2", app = "")
    @test result.code == 0
    @test pushed("hotfix/v0.1.2") == "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> Hotfix 0.1.2"
    @test endswith(rstrip(read(log, String)), "--draft=true")
end

# The action at its release, or, with `local-action`, at the checked-out commit, as this repository's own releases run it; both steps take the same inputs.
@testset "Local action" begin
    for (file, id) in ["release.yml" => "prepare", "register.yml" => "registration"]
        @test !isempty(step_inputs(file, id))
        @test step_inputs(file, id) == step_inputs(file, "$(id)-local")
    end
end

# A composite action passes on only the outputs that it declares, so every output that ReleaseFlow writes is declared in action.yml.
@testset "Action outputs" begin
    root = normpath(joinpath(@__DIR__, "..", ".."))
    written = Set{String}()
    for (directory, _, files) in walkdir(joinpath(root, "ReleaseFlow", "src")), file in files
        for m in eachmatch(r"output\(settings, \"([a-z-]+)\"", read(joinpath(directory, file), String))
            push!(written, m.captures[1])
        end
    end
    lines = readlines(joinpath(root, "action.yml"))
    start = findfirst(==("outputs:"), lines)
    declared = Set(m.captures[1] for m in filter(!isnothing, match.(r"^  ([a-z-]+):$", lines[(start + 1):findnext(==("runs:"), lines, start)])))
    @test !isempty(written)
    @test written ⊆ declared
end
