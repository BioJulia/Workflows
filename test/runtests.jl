# Tests of the checks
# ===================
#
# Each test builds a git repository of a toy package, `Toy`, in a temporary directory, and runs `checks/checks.jl` in it, as the workflows do.
# The registry is a scratch one, a directory, so that the tests need no network.

using Test

const SCRIPT = normpath(joinpath(@__DIR__, "..", "checks", "checks.jl"))
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
        "MODEL" => "gitflow", "REGISTRY" => EMPTY, "GITHUB_REPOSITORY" => "Example/Toy.jl",
        "GITHUB_OUTPUT" => "", "GITHUB_STEP_SUMMARY" => "", "SKIP_CHANGELOG" => "false",
    )
    for (key, value) in variables
        environment[string(key)] = string(value)
    end
    output = IOBuffer()
    command = Cmd(addenv(`$(Base.julia_cmd()) --startup-file=no $(SCRIPT) $(name)`, environment); dir = directory, ignorestatus = true)
    process = run(pipeline(command; stdout = output, stderr = output))
    return (code = process.exitcode, output = String(take!(output)))
end

passes(result) = result.code == 0
fails(result, message) = result.code == 1 && occursin(message, result.output)

# Gitflow
# -------

# master holds the release 0.1.0, tagged; develop adds a feature, with an entry.
function gitflow_repository(; main = "master", develop = "develop")
    directory = repository(; branch = main)
    released = commit!(directory, "Release 0.1.0", "Project.toml" => project("0.1.0"), "src/Toy.jl" => SOURCE, "test/runtests.jl" => TESTS, "CHANGELOG.md" => changelog(released = ["0.1.0" => ["First."]]))
    git(directory, "tag", "v0.1.0")
    branch!(directory, develop, released)
    feature = commit!(directory, "Feature", "feature.txt" => "feature", "CHANGELOG.md" => changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]]))
    origin!(directory, main, released)
    origin!(directory, develop, feature)
    return directory, released, feature
end

# A release branch `name` from `from`, at `version`, with its changelog.
function release!(directory, name, from, version; entries = ["A feature."], files = Pair[], log = nothing)
    branch!(directory, name, from)
    text = something(log, changelog(released = [version => entries, "0.1.0" => ["First."]]))
    return commit!(directory, "Release $(version)", "Project.toml" => project(version), "CHANGELOG.md" => text, files...)
end

@testset "Gitflow" begin
    @testset "version" begin
        directory, released, feature = gitflow_repository()
        on(name; variables...) = (git(directory, "checkout", "-q", name); check(directory, "version"; HEAD_REF = name, HEAD_SHA = name, variables...))
        release!(directory, "release/v0.2.0", feature, "0.2.0")
        @test passes(on("release/v0.2.0"))
        # An empty input counts as missing, as GitHub Actions passes an input that it has no value for.
        @test passes(on("release/v0.2.0"; HEAD_SHA = "", BASE_REF = ""))
        release!(directory, "hotfix/v0.1.1", released, "0.1.1"; entries = ["A fix."])
        @test passes(on("hotfix/v0.1.1"))
        release!(directory, "release/v0.1.0", feature, "0.1.0")
        @test fails(on("release/v0.1.0"), "isn't a single step up")
        @test fails(on("release/v0.1.0"), "already tagged")
        release!(directory, "release/v0.3.0", feature, "0.3.0")
        @test fails(on("release/v0.3.0"), "isn't a single step up from 0.1.0")
        release!(directory, "hotfix/v0.2.0", released, "0.2.0")
        @test fails(on("hotfix/v0.2.0"), "A hotfix releases the next patch, 0.1.1")
        release!(directory, "release/v0.2.1", feature, "0.2.0")
        @test fails(on("release/v0.2.1"), "names 0.2.1, but Project.toml has 0.2.0")
        release!(directory, "release/v0.2.0-rc1", feature, "0.2.0-rc1")
        @test fails(on("release/v0.2.0-rc1"), "prerelease or build suffix")
        # A tag or a registered version of the new version must be of the head commit.
        git(directory, "tag", "v0.2.0", released)
        @test fails(on("release/v0.2.0"), "already tagged, v0.2.0, at another commit")
        git(directory, "tag", "-d", "v0.2.0")
        @test fails(on("release/v0.2.0"; REGISTRY = registry("0.2.0" => tree(directory, released))), "already records 0.2.0")
        @test passes(on("release/v0.2.0"; REGISTRY = registry("0.2.0" => tree(directory, "release/v0.2.0"))))
        # The first release, before master has a version.
        git(directory, "update-ref", "-d", "refs/remotes/origin/master")
        @test passes(on("release/v0.2.0"))
    end

    @testset "changelog" begin
        directory, released, feature = gitflow_repository()
        on(name; variables...) = check(directory, "changelog"; HEAD_REF = name, variables...)
        release!(directory, "release/v0.2.0", feature, "0.2.0")
        @test passes(on("release/v0.2.0"))
        with(text) = (release!(directory, "release/v0.2.0", feature, "0.2.0"; log = text); on("release/v0.2.0"))
        @test fails(with(changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]])), "no section for 0.2.0")
        @test fails(with(changelog(released = ["0.2.0" => String[], "0.1.0" => ["First."]])), "has no entries")
        @test fails(with(changelog(unreleased = ["Left behind."], released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]])), "still has entries")
        @test fails(with(changelog(released = ["0.1.0" => ["First."], "0.2.0" => ["A feature."]], links = false)), "must come before that of 0.1.0")
        # The links: each version's, the unreleased changes', with `v` tags, and the repository's.
        @test fails(with(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]], links = false)), "no link for 0.2.0")
        @test fails(with(replace(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]]), "...v0.2.0" => "...0.2.0")), "should be $(URL)/compare/v0.1.0...v0.2.0")
        @test fails(with(replace(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]]), "v0.2.0...HEAD" => "v0.1.0...HEAD")), "link for the unreleased changes")
        @test fails(with(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]], heading = "## UNRELEASED")), "Head the unreleased section")
        @test fails(on("release/v0.2.0"; GITHUB_REPOSITORY = "Example/Other.jl"), "Example/Other.jl/compare")
        # A changelog begun after earlier releases may compare its oldest version with an earlier tag.
        @test passes(with(replace(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]]), "releases/tag/v0.1.0" => "compare/v0.0.9...v0.1.0")))
        release!(directory, "release/v0.2.0", feature, "0.2.0"; log = changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]], links = false))
        @test passes(on("release/v0.2.0"; CHECK_LINKS = false))
        # A section that the base already has isn't new.
        branch!(directory, "master", released)
        newer = commit!(directory, "Changelog", "CHANGELOG.md" => changelog(released = ["0.2.0" => ["Early."], "0.1.0" => ["First."]]))
        origin!(directory, "master", newer)
        @test fails(with(changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]])), "already in the changelog of origin/master")
    end

    @testset "entry" begin
        directory, released, feature = gitflow_repository()
        on(name; variables...) = check(directory, "entry"; BASE_REF = "origin/develop", HEAD_REF = name, variables...)
        entries(list...) = (branch!(directory, "feature/x", feature); commit!(directory, "Work", "CHANGELOG.md" => changelog(unreleased = collect(String, list), released = ["0.1.0" => ["First."]])); on("feature/x"))
        @test passes(entries("A feature.", "Another."))
        @test passes(entries("A feature, reworded."))
        @test fails(entries("A feature."), "no new entry")
        @test fails(entries(), "no new entry")
        branch!(directory, "feature/x", feature)
        commit!(directory, "Released only", "CHANGELOG.md" => changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First.", "Second."]]))
        @test fails(on("feature/x"), "no new entry")
        @test passes(on("feature/x"; SKIP_CHANGELOG = true))
        @test occursin("`skip changelog` label", on("feature/x"; SKIP_CHANGELOG = true).output)
        @test passes(on("master"))
        @test passes(on("back-merge/v0.1.0"))
        commit!(directory, "No changelog", "CHANGELOG.md" => nothing)
        @test fails(on("feature/x"), "There's no CHANGELOG.md")
    end

    @testset "source" begin
        directory, released, feature = gitflow_repository()
        on(base, name, sha = name) = check(directory, "source"; BASE_BRANCH = base, HEAD_REF = name, HEAD_SHA = sha)
        release!(directory, "release/v0.2.0", feature, "0.2.0")
        release!(directory, "hotfix/v0.1.1", released, "0.1.1")
        branch!(directory, "feature/x", feature)
        @test passes(on("master", "release/v0.2.0"))
        @test passes(on("master", "hotfix/v0.1.1"))
        @test fails(on("master", "feature/x"), "master takes merges only from release/* and hotfix/*")
        @test fails(on("develop", "release/v0.2.0"), "develop doesn't take merges from release/*")
        @test fails(on("develop", "hotfix/v0.1.1"), "develop doesn't take merges")
        @test passes(on("develop", "feature/x"))
        @test passes(on("develop", "master"))
        @test passes(on("main", "feature/x"))
        # Where the branch came from: a hotfix carries nothing unreleased of develop, and a release carries develop's work.
        release!(directory, "hotfix/v0.1.2", feature, "0.1.2")
        @test fails(on("master", "hotfix/v0.1.2"), "carries unreleased commits of develop")
        release!(directory, "release/v0.3.0", released, "0.3.0")
        @test fails(on("master", "release/v0.3.0"), "carries none of the unreleased commits of develop")
        # As in GitHub Actions: the merge commit is checked out, and the head commit, as of a fork, only reachable from it.
        branch!(directory, "merge", released)
        git(directory, "merge", "-q", "--no-ff", "--no-edit", "hotfix/v0.1.2")
        head = git(directory, "rev-parse", "HEAD^2")
        git(directory, "branch", "-q", "-D", "hotfix/v0.1.2")
        @test fails(on("master", "hotfix/v0.1.2", head), "carries unreleased commits of develop")
        # Without develop, the origin isn't checked.
        @test passes(check(directory, "source"; BASE_BRANCH = "master", HEAD_REF = "hotfix/v0.1.2", HEAD_SHA = head, DEVELOP_REF = "origin/none"))
    end

    @testset "branch names" begin
        directory, released, feature = gitflow_repository(; main = "main", develop = "dev")
        branch_names = (MAIN_BRANCH = "main", DEVELOP_BRANCH = "dev")
        release!(directory, "release/v0.2.0", feature, "0.2.0")
        branch!(directory, "feature/x", feature)
        @test passes(check(directory, "source"; branch_names..., BASE_BRANCH = "main", HEAD_REF = "release/v0.2.0", HEAD_SHA = "release/v0.2.0"))
        @test fails(check(directory, "source"; branch_names..., BASE_BRANCH = "main", HEAD_REF = "feature/x", HEAD_SHA = "feature/x"), "main takes merges only")
        @test fails(check(directory, "source"; branch_names..., BASE_BRANCH = "dev", HEAD_REF = "release/v0.2.0"), "dev doesn't take merges")
        git(directory, "checkout", "-q", "release/v0.2.0")
        @test passes(check(directory, "version"; branch_names..., HEAD_REF = "release/v0.2.0", HEAD_SHA = "release/v0.2.0"))
        @test passes(check(directory, "entry"; branch_names..., BASE_REF = "origin/dev", HEAD_REF = "main"))
    end

    @testset "breaking" begin
        directory, released, feature = gitflow_repository()
        on(name) = (git(directory, "checkout", "-q", name); check(directory, "breaking"; HEAD_REF = name, HEAD_SHA = name))
        added = replace(SOURCE, "triple(x) = 3x" => "triple(x) = 3x\nquadruple(x) = 4x")
        release!(directory, "hotfix/v0.1.1", released, "0.1.1"; files = ["src/Toy.jl" => added])
        @test passes(on("hotfix/v0.1.1"))
        removed = replace(SOURCE, "triple(x) = 3x" => "")
        release!(directory, "release/v0.1.1", feature, "0.1.1"; files = ["src/Toy.jl" => removed])
        result = on("release/v0.1.1")
        @test fails(result, "must be 0.2.0 or 1.0.0, not 0.1.1")
        @test fails(result, "needs a `### Breaking` subsection")
        @test occursin("Toy.triple", result.output)
        release!(directory, "release/v0.2.0", feature, "0.2.0"; files = ["src/Toy.jl" => removed], log = changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]], breaking = ["Remove `triple`."]))
        @test passes(on("release/v0.2.0"))
        release!(directory, "hotfix/v0.1.1", released, "0.1.1"; files = ["src/Toy.jl" => replace(SOURCE, "double(x; scale = 1) = 2x * scale" => "double(x) = 2x")])
        @test fails(on("hotfix/v0.1.1"), "A hotfix may not make breaking changes")
        release!(directory, "hotfix/v0.1.1", released, "0.1.1"; files = ["src/Toy.jl" => replace(SOURCE, "3x" => "3x + 1")])
        @test fails(on("hotfix/v0.1.1"), "The tests of origin/master fail")
        release!(directory, "hotfix/v0.1.1", released, "0.1.1"; files = ["Project.toml" => project("0.1.1"; julia = "1.11")])
        @test fails(on("hotfix/v0.1.1"), "no longer admits")
    end
end

# OneFlow
# -------

# main holds the release 0.1.0, tagged and registered, and then a feature, with an entry.
function oneflow_repository()
    directory = repository(; branch = "main")
    released = commit!(directory, "Release 0.1.0", "Project.toml" => project("0.1.0"), "src/Toy.jl" => SOURCE, "test/runtests.jl" => TESTS, "CHANGELOG.md" => changelog(released = ["0.1.0" => ["First."]]))
    git(directory, "tag", "v0.1.0")
    feature = commit!(directory, "Feature", "feature.txt" => "feature", "CHANGELOG.md" => changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]]))
    origin!(directory, "main", feature)
    return directory, released, feature, registry("0.1.0" => tree(directory, released))
end

@testset "OneFlow" begin
    directory, released, feature, scratch = oneflow_repository()
    model = (MODEL = "oneflow", MAIN_BRANCH = "main", BASE_BRANCH = "main", REGISTRY = scratch)
    on(name, check_name; variables...) = (git(directory, "checkout", "-q", name); check(directory, check_name; merge(merge(model, (HEAD_REF = name, HEAD_SHA = name)), variables)...))
    release!(directory, "release/v0.2.0", feature, "0.2.0")
    release!(directory, "hotfix/v0.1.1", "v0.1.0", "0.1.1"; entries = ["A fix."])
    for name in ("release/v0.2.0", "hotfix/v0.1.1"), check_name in ("source", "version", "changelog")
        @test passes(on(name, check_name))
    end
    @test occursin("which Scratch records and v0.1.0 tags", on("release/v0.2.0", "version").output)
    # A hotfix branches from the last release's tag, not from main.
    release!(directory, "hotfix/v0.1.2", feature, "0.1.2")
    @test fails(on("hotfix/v0.1.2", "source"), "carries unreleased commits of main")
    # The release is registered and tagged before it merges back, at its head commit.
    git(directory, "tag", "v0.2.0", "release/v0.2.0")
    @test passes(on("release/v0.2.0", "version"))
    git(directory, "tag", "-f", "v0.2.0", feature)
    @test fails(on("release/v0.2.0", "version"), "already tagged, v0.2.0, at another commit")
    git(directory, "tag", "-d", "v0.2.0")
    # The checks look at the head commit, though main has moved on.
    branch!(directory, "main", feature)
    origin!(directory, "main", commit!(directory, "Another feature", "CHANGELOG.md" => changelog(unreleased = ["A feature.", "Another."], released = ["0.1.0" => ["First."]])))
    @test passes(on("release/v0.2.0", "changelog"))
    # Features need entries, releases don't.
    branch!(directory, "feature/x", "origin/main")
    commit!(directory, "Work", "work.txt" => "work")
    @test fails(on("feature/x", "entry"; BASE_REF = "origin/main"), "no new entry")
    @test passes(on("release/v0.2.0", "entry"))
    @test passes(on("feature/x", "source"))
    # The tag must be the registered release.
    git(directory, "tag", "-f", "v0.1.0", feature)
    @test fails(on("release/v0.2.0", "version"), "The tag v0.1.0 isn't the release of 0.1.0 that Scratch records")
    git(directory, "tag", "-f", "v0.1.0", released)
    # Without the registry, the tag is the last release, and without the tag, main.
    @test occursin("so the last release is the tag v0.1.0", on("release/v0.2.0", "version"; REGISTRY = EMPTY).output)
    git(directory, "tag", "-d", "v0.1.0")
    @test occursin("there's no tag v0.1.0, so the last release is origin/main", on("release/v0.2.0", "changelog"; REGISTRY = EMPTY).output)
    # The registered commit is the base of the breaking changes.
    removed = replace(SOURCE, "triple(x) = 3x" => "")
    release!(directory, "release/v0.2.0", feature, "0.2.0"; files = ["src/Toy.jl" => removed])
    @test fails(on("release/v0.2.0", "breaking"), "needs a `### Breaking` subsection")

    # A release with nothing new since the last release, from its tag.
    directory, released, feature, scratch = oneflow_repository()
    origin!(directory, "main", released)
    release!(directory, "release/v0.2.0", released, "0.2.0")
    @test fails(check(directory, "source"; merge(model, (REGISTRY = scratch, HEAD_REF = "release/v0.2.0", HEAD_SHA = "release/v0.2.0"))...), "carries none of the unreleased commits of main")
end

# Trunk
# -----

@testset "Trunk" begin
    directory, released, feature, scratch = oneflow_repository()
    model = (MODEL = "trunk", MAIN_BRANCH = "main", BASE_BRANCH = "main", REGISTRY = scratch)
    on(name, check_name; variables...) = (git(directory, "checkout", "-q", name); check(directory, check_name; merge(merge(model, (HEAD_REF = name, HEAD_SHA = name)), variables)...))
    output = tempname()
    branch!(directory, "feature/x", feature)
    commit!(directory, "Work", "CHANGELOG.md" => changelog(unreleased = ["A feature.", "Another."], released = ["0.1.0" => ["First."]]))
    @test passes(on("feature/x", "release"; GITHUB_OUTPUT = output))
    @test readchomp(output) == "release=false"
    @test passes(on("feature/x", "entry"))
    branch!(directory, "feature/y", feature)
    commit!(directory, "Work", "work.txt" => "work")
    @test fails(on("feature/y", "entry"), "no new entry")
    # A release changes the version.
    release!(directory, "bump", feature, "0.2.0")
    rm(output)
    @test passes(on("bump", "release"; GITHUB_OUTPUT = output))
    @test readchomp(output) == "release=true"
    for check_name in ("version", "changelog", "entry")
        @test passes(on("bump", check_name))
    end
    release!(directory, "bump", feature, "0.3.0")
    @test fails(on("bump", "version"), "isn't a single step up from 0.1.0")
    # A changelog as FASTX.jl keeps it: `*` entries, no unreleased section, and no links.
    plain = changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]], heading = nothing, bullet = "*", links = false)
    release!(directory, "bump", feature, "0.2.0"; log = plain)
    @test passes(on("bump", "changelog"; CHECK_LINKS = false))
    @test fails(on("bump", "changelog"), "no link for 0.2.0")
end
