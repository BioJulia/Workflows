# Helpers of the end-to-end tests: git repositories of a toy package, `Toy`, in temporary directories, a scratch registry, and running `julia -m ReleaseFlow` in them, as the workflows do.

const PACKAGE = normpath(joinpath(@__DIR__, ".."))
const UUID = "6d8a9f4e-1b2c-4d3e-8f5a-0b1c2d3e4f5a"
const URL = "https://github.com/Example/Toy.jl"

# Git
# ---

git(directory, arguments...) = readchomp(Cmd(`git $(arguments)`; dir = directory))

function repository(; branch = "master")
    directory = mktempdir()
    git(directory, "init", "-q", "-b", branch)
    git(directory, "config", "user.name", "Test")
    git(directory, "config", "user.email", "test@example.invalid")
    git(directory, "config", "commit.gpgsign", "false")
    git(directory, "remote", "add", "origin", "git@github.com:Example/Toy.jl.git")
    # The breaking check resolves the package where it is, which writes a manifest.
    write(joinpath(directory, ".gitignore"), "Manifest*.toml\n")
    return directory
end

# Write `files`, each a path and its contents, or `nothing` to remove it, commit them, and return the commit.
function commit!(directory, message, files::Pair...)
    for (path, contents) in files
        full = joinpath(directory, path)
        if contents === nothing
            rm(full; force = true)
        else
            mkpath(dirname(full))
            write(full, contents)
        end
    end
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "--allow-empty", "-m", message)
    return git(directory, "rev-parse", "HEAD")
end

branch!(directory, name, from) = git(directory, "checkout", "-q", "-B", name, from)

origin!(directory, branch, commit) = git(directory, "update-ref", "refs/remotes/origin/$(branch)", commit)

tree(directory, ref) = git(directory, "rev-parse", "$(ref)^{tree}")

# The package
# -----------

function project(version; julia = "1.10")
    return """
    name = "Toy"
    uuid = "$(UUID)"
    version = "$(version)"

    [compat]
    julia = "$(julia)"

    [extras]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [targets]
    test = ["Test"]
    """
end

const SOURCE = """
module Toy
export double, triple
double(x; scale = 1) = 2x * scale
triple(x) = 3x
end
"""

const TESTS = """
using Test, Toy
@test double(2) == 4
@test double(2; scale = 2) == 8
@test triple(2) == 6
# The breaking check runs these tests without its own inputs.
@test !haskey(ENV, "RELEASEFLOW_HEAD_REF")
"""

# A changelog with `unreleased` entries and `released` sections, newest first, each a version and its entries, with comparison links.
function changelog(; unreleased = String[], released = Pair{String, Vector{String}}[], heading = "## [Unreleased]", bullet = "-", links = true, breaking = String[])
    lines = ["# Changelog", ""]
    heading === nothing || push!(lines, heading, "", ("$(bullet) $(entry)" for entry in unreleased)..., "")
    for (index, (version, entries)) in enumerate(released)
        push!(lines, "## [$(version)]", "")
        index == 1 && !isempty(breaking) && push!(lines, "### Breaking", "", ("$(bullet) $(entry)" for entry in breaking)..., "", "### Changed", "")
        push!(lines, ("$(bullet) $(entry)" for entry in entries)..., "")
    end
    if links
        versions = first.(released)
        heading === nothing || isempty(versions) || push!(lines, "[Unreleased]: $(URL)/compare/v$(first(versions))...HEAD")
        for (index, version) in enumerate(versions)
            push!(lines, index == length(versions) ? "[$(version)]: $(URL)/releases/tag/v$(version)" : "[$(version)]: $(URL)/compare/v$(versions[index + 1])...v$(version)")
        end
    end
    return join(lines, '\n') * '\n'
end

# The registry
# ------------

# A registry with Toy and the trees of its `versions`, each a version and a tree.
function registry(versions::Pair...)
    directory = mktempdir()
    write(
        joinpath(directory, "Registry.toml"), """
        name = "Scratch"
        uuid = "6d8a9f4e-0000-4000-8000-000000000000"
        repo = "https://example.invalid/Scratch.git"

        [packages]
        $(UUID) = { name = "Toy", path = "T/Toy" }
        """
    )
    mkpath(joinpath(directory, "T", "Toy"))
    write(joinpath(directory, "T", "Toy", "Package.toml"), "name = \"Toy\"\nuuid = \"$(UUID)\"\nrepo = \"$(URL).git\"\n")
    write(joinpath(directory, "T", "Toy", "Versions.toml"), join(("[\"$(version)\"]\ngit-tree-sha1 = \"$(tree)\"\n" for (version, tree) in versions), '\n'))
    return directory
end

const EMPTY = registry()

# Running the checks
# ------------------

# Run the check `name` in `directory`, with the environment `variables`, and return its exit code and output.
function check(directory, name; variables...)
    environment = Dict(
        "RELEASEFLOW_MODEL" => "gitflow", "RELEASEFLOW_MAIN_BRANCH" => "master", "RELEASEFLOW_REGISTRY" => EMPTY, "GITHUB_REPOSITORY" => "Example/Toy.jl",
        "GITHUB_OUTPUT" => "", "GITHUB_STEP_SUMMARY" => "", "RELEASEFLOW_SKIP_CHANGELOG" => "false",
    )
    for (key, value) in variables
        environment[string(key)] = string(value)
    end
    output = IOBuffer()
    command = Cmd(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$(PACKAGE) -m ReleaseFlow $(name)`, environment); dir = directory, ignorestatus = true)
    process = run(pipeline(command; stdout = output, stderr = output))
    return (code = process.exitcode, output = String(take!(output)))
end

passes(result) = result.code == 0
fails(result, message) = result.code == 1 && occursin(message, result.output)

# Workflows
# ---------

# The shell of the step `name` of the workflow `file`, in .github/workflows: the block after its `run: |`, without its indentation.
# The `with:` lines of the step `- id: <id>` in a workflow, which the steps that run the action at its release and at the checkout share.
function step_inputs(file, id)
    lines = readlines(normpath(joinpath(@__DIR__, "..", "..", ".github", "workflows", file)))
    start = findnext(line -> strip(line) == "with:", lines, findfirst(line -> strip(line) == "- id: $(id)", lines))
    indentation = length(match(r"^ *", lines[start]).match)
    stop = findnext(line -> length(match(r"^ *", line).match) <= indentation, lines, start + 1)
    return lines[(start + 1):(stop - 1)]
end

function workflow_step(file, name)
    lines = readlines(normpath(joinpath(@__DIR__, "..", "..", ".github", "workflows", file)))
    named = findfirst(line -> strip(line) == "- name: $(name)", lines)
    start = findnext(line -> endswith(line, "run: |"), lines, named)
    indentation = length(match(r"^ *", lines[start + 1]).match)
    block = String[]
    for line in lines[(start + 1):end]
        !isempty(strip(line)) && length(match(r"^ *", line).match) < indentation && break
        push!(block, isempty(strip(line)) ? "" : line[(indentation + 1):end])
    end
    return join(block, '\n') * '\n'
end
