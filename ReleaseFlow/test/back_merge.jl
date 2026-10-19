# Back-merge
# ----------

# The shell of the back-merge workflow's step, read from the workflow: the block after its `run: |`, without its indentation.
function back_merge_script()
    lines = readlines(normpath(joinpath(@__DIR__, "..", "..", ".github", "workflows", "back-merge.yml")))
    start = findfirst(line -> endswith(line, "run: |"), lines)
    indentation = length(match(r"^ *", lines[start + 1]).match)
    block = String[]
    for line in lines[(start + 1):end]
        !isempty(strip(line)) && length(match(r"^ *", line).match) < indentation && break
        push!(block, isempty(strip(line)) ? "" : line[(indentation + 1):end])
    end
    return join(block, '\n') * '\n'
end

@testset "Back-merge" begin
    directory = mktempdir()
    script = joinpath(directory, "step.sh")
    write(script, back_merge_script())
    # A stand-in for `gh`: it logs its calls, creates refs in the origin for `api`, and reports `OPEN_PRS` open pull requests.
    bin = mkpath(joinpath(directory, "bin"))
    write(
        joinpath(bin, "gh"), raw"""
        #!/bin/bash
        echo "gh $*" >> "$LOG"
        case "$1 $2" in
          "api repos/"*) for a in "$@"; do case "$a" in ref=*) ref=${a#ref=};; sha=*) sha=${a#sha=};; esac; done; git -C "$ORIGIN" update-ref "$ref" "$sha";;
          "pr list") echo "${OPEN_PRS:-0}";;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    origin = joinpath(directory, "origin.git")
    run(pipeline(`git init -q --bare $(origin)`))
    work = repository()
    git(work, "remote", "set-url", "origin", origin)
    commit!(work, "Start", "Project.toml" => project("0.1.0"))
    git(work, "push", "-q", "origin", "HEAD:master", "HEAD:develop")
    branch!(work, "develop", "master")
    commit!(work, "Feature", "feature.txt" => "feature")
    git(work, "push", "-q", "origin", "develop")
    branch!(work, "master", "master")
    commit!(work, "Release", "release.txt" => "release")
    git(work, "push", "-q", "origin", "master")
    git(work, "fetch", "-q", "origin")
    log = joinpath(directory, "log")

    function step(; has_token = "true", open = "0", project = "")
        write(log, "")
        environment = Dict(
            "PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "ORIGIN" => origin, "GH_TOKEN" => "token", "HAS_TOKEN" => has_token,
            "REPOSITORY" => "Example/Toy.jl", "RELEASEFLOW_MAIN_BRANCH" => "master", "RELEASEFLOW_DEVELOP_BRANCH" => "develop", "OPEN_PRS" => open, "RELEASEFLOW_PROJECT" => project,
        )
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = work, ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), calls = readlines(log))
    end

    # The first run creates the branch at master and opens the pull request, which says to reopen it without the token.
    result = step(; has_token = "false")
    @test result.code == 0
    @test git(origin, "rev-parse", "refs/heads/back-merge/v0.1.0") == git(work, "rev-parse", "master")
    @test any(call -> startswith(call, "gh pr create") && occursin("--base develop", call), result.calls)
    @test occursin("close and reopen it", read(log, String))
    # A rerun leaves the branch and the open pull request as they are.
    git(work, "fetch", "-q", "origin")
    result = step(; open = "1")
    @test result.code == 0 && occursin("is open already", result.output)
    @test !any(call -> startswith(call, "gh api") || startswith(call, "gh pr create"), result.calls)
    # Nothing to do once develop has master's commit.
    branch!(work, "develop", "origin/develop")
    git(work, "merge", "-q", "--no-edit", "master")
    git(work, "push", "-q", "origin", "develop")
    branch!(work, "master", "master")
    git(work, "fetch", "-q", "origin")
    result = step()
    @test result.code == 0 && occursin("there's nothing to bring back", result.output) && isempty(result.calls)
    # A package in a subdirectory names the branch from its own Project.toml.
    commit!(work, "Subdirectory", "lib/Toy/Project.toml" => project("0.3.0"), "subdirectory.txt" => "x")
    git(work, "push", "-q", "origin", "master")
    git(work, "fetch", "-q", "origin")
    result = step(; project = "lib/Toy/")
    @test result.code == 0 && occursin("back-merge/v0.3.0", result.output)
    # A version that can't name the branch is an error.
    commit!(work, "Bad version", "Project.toml" => replace(project("0.1.0"), "0.1.0" => "0.1"))
    result = step()
    @test result.code == 1 && occursin("Project.toml on master has no version of the form X.Y.Z", result.output)
end
