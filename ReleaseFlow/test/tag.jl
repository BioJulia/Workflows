# Moving the major tags
# ---------------------

# The tag workflow's step, run in a repository with version tags, with a stand-in for `gh` that logs its calls.
@testset "Tag" begin
    directory = mktempdir()
    bin = mkpath(joinpath(directory, "bin"))
    write(joinpath(bin, "gh"), "#!/bin/bash\necho \"gh \$*\" >> \"\$LOG\"\n")
    chmod(joinpath(bin, "gh"), 0o755)
    log = joinpath(directory, "log")
    script = joinpath(directory, "step.sh")
    write(script, workflow_step("tag.yml", "Move the major tags"))
    work = repository()
    git(work, "config", "tag.gpgsign", "false")
    commits = [commit!(work, "Commit $(i)", "file.txt" => string(i)) for i in 1:6]
    function step()
        write(log, "")
        environment = Dict("PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "REPOSITORY" => "Example/Toy.jl")
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = work, ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), log = read(log, String))
    end
    tag!(name, commit) = git(work, "tag", "-f", name, commit)
    created(major, commit) = "gh api repos/Example/Toy.jl/git/refs -f ref=refs/tags/$(major) -f sha=$(commit)"
    moved(major, commit) = "gh api --method PATCH repos/Example/Toy.jl/git/refs/tags/$(major) -f sha=$(commit) -F force=true"

    # Without version tags, there's nothing to move.
    result = step()
    @test result.code == 0 && occursin("There's no version tag vX.Y.Z", result.output) && isempty(result.log)
    # The newest release of a major version without its major tag: the major tag is made at its commit.
    tag!("v1.0.0", commits[1])
    tag!("v1.0.1", commits[2])
    result = step()
    @test result.code == 0 && result.log == created("v1", commits[2]) * "\n"
    # A major tag at an older release moves to the newest.
    tag!("v1", commits[1])
    result = step()
    @test result.log == moved("v1", commits[2]) * "\n"
    # A major tag at the newest release stays.
    tag!("v1", commits[2])
    result = step()
    @test isempty(result.log) && occursin("v1 is at v1.0.1, $(commits[2]), already.", result.output)
    # Each major version's tag follows its own newest release, by version rather than by date, and pre-releases are left out.
    tag!("v1.10.0", commits[3])
    tag!("v1.9.0", commits[4])
    tag!("v2.0.0", commits[5])
    tag!("v2.1.0-rc1", commits[6])
    result = step()
    @test result.log == moved("v1", commits[3]) * "\n" * created("v2", commits[5]) * "\n"
    # A version tag pushed by hand, older than the newest, moves nothing.
    tag!("v1", commits[3])
    tag!("v2", commits[5])
    tag!("v1.0.5", commits[6])
    @test isempty(step().log)
    # An annotated tag counts at its commit.
    git(work, "tag", "-a", "v2.2.0", "-m", "Release 2.2.0", commits[6])
    @test step().log == moved("v2", commits[6]) * "\n"
end
