# The initial release
# -------------------

# master holds only an initial commit, without a package; develop adds the package, at 0.1.0, with an unreleased entry.
function initial_repository(; branch = "master", develop = "develop")
    directory = repository(; branch)
    start = commit!(directory, "Initial commit", "README.md" => "Toy.")
    origin!(directory, branch, start)
    branch!(directory, develop, start)
    package = commit!(directory, "The package", "Project.toml" => project("0.1.0"), "src/Toy.jl" => SOURCE, "test/runtests.jl" => TESTS, "CHANGELOG.md" => changelog(unreleased = ["Toy."]))
    origin!(directory, develop, package)
    return directory, start, package
end

# A release branch `name` from `from`, at `version`, whose changelog has only its section, unless `log` is given.
initial!(directory, name, from, version; log = changelog(released = [version => ["Toy."]])) = (branch!(directory, name, from); commit!(directory, "Release $(version)", "Project.toml" => project(version), "CHANGELOG.md" => log))

@testset "Initial release" begin
    @testset "units" begin
        for version in (v"0.0.1", v"0.1.0", v"1.0.0", v"3.0.0")
            @test ReleaseFlow.is_first_version(version)
        end
        for version in (v"0.2.0", v"0.1.1", v"0.0.2", v"1.2.0", v"1.0.1")
            @test !ReleaseFlow.is_first_version(version)
        end
        @test ReleaseFlow.label(ReleaseFlow.InitialRelease()) == "no earlier release"
    end

    @testset "gitflow" begin
        directory, start, package = initial_repository()
        on(name, check_name; variables...) = (git(directory, "checkout", "-q", name); check(directory, check_name; RELEASEFLOW_BASE_BRANCH = "master", RELEASEFLOW_HEAD_REF = name, RELEASEFLOW_HEAD_SHA = name, variables...))
        initial!(directory, "release/v0.1.0", package, "0.1.0")
        for check_name in ("source", "version", "changelog", "breaking")
            @test passes(on("release/v0.1.0", check_name))
        end
        @test occursin("so 0.1.0 is the initial release", on("release/v0.1.0", "version").output)
        @test occursin("This is the initial release, so there's nothing to break", on("release/v0.1.0", "breaking").output)
        # A standard first version: 0.0.1, 0.1.0 or X.0.0.
        initial!(directory, "release/v1.0.0", package, "1.0.0")
        @test passes(on("release/v1.0.0", "version"))
        initial!(directory, "release/v0.3.2", package, "0.3.2")
        @test fails(on("release/v0.3.2", "version"), "takes a standard first version, 0.0.1, 0.1.0 or X.0.0")
        # There's no release to fix.
        initial!(directory, "hotfix/v0.1.0", start, "0.1.0")
        @test fails(on("hotfix/v0.1.0", "version"), "can't be the initial release")
        # The changelog describes only the initial release, linked to its own tag.
        initial!(directory, "release/v0.1.0", package, "0.1.0"; log = changelog(released = ["0.1.0" => ["Toy."], "0.0.9" => ["Earlier."]]))
        @test fails(on("release/v0.1.0", "changelog"), "has a section for 0.0.9, but 0.1.0 is the initial release")
        initial!(directory, "release/v0.1.0", package, "0.1.0"; log = replace(changelog(released = ["0.1.0" => ["Toy."]]), "releases/tag/v0.1.0" => "compare/v0.0.9...v0.1.0"))
        @test fails(on("release/v0.1.0", "changelog"), "should be $(URL)/releases/tag/v0.1.0")
        # Nothing released before: neither the registry nor the repository's tags.
        initial!(directory, "release/v0.1.0", package, "0.1.0")
        @test fails(on("release/v0.1.0", "version"; RELEASEFLOW_REGISTRY = registry("0.0.5" => tree(directory, start))), "already records 0.0.5 of the package, so 0.1.0 isn't its initial release")
        git(directory, "tag", "v0.0.1", start)
        @test fails(on("release/v0.1.0", "version"), "already has the version tags v0.0.1")
        git(directory, "tag", "-d", "v0.0.1")
        # Other tags aren't versions.
        git(directory, "tag", "ReleaseFlow-v0.0.1", start)
        @test passes(on("release/v0.1.0", "version"))
    end

    @testset "OneFlow" begin
        directory, start, package = initial_repository(; branch = "main")
        on(name, check_name) = (git(directory, "checkout", "-q", name); check(directory, check_name; RELEASEFLOW_MODEL = "oneflow", RELEASEFLOW_MAIN_BRANCH = "main", RELEASEFLOW_BASE_BRANCH = "main", RELEASEFLOW_HEAD_REF = name, RELEASEFLOW_HEAD_SHA = name))
        initial!(directory, "release/v0.1.0", package, "0.1.0")
        @test occursin("This is the initial release, so where release/v0.1.0 came from isn't checked", on("release/v0.1.0", "source").output)
        # OneFlow tags the release before it merges back; its own tag, at its commit, isn't an earlier release.
        git(directory, "tag", "v0.1.0", "release/v0.1.0")
        @test passes(on("release/v0.1.0", "version"))
    end

    @testset "trunk" begin
        directory, start, package = initial_repository(; branch = "main")
        on(name, check_name; variables...) = (git(directory, "checkout", "-q", name); check(directory, check_name; RELEASEFLOW_MODEL = "trunk", RELEASEFLOW_MAIN_BRANCH = "main", RELEASEFLOW_BASE_BRANCH = "main", RELEASEFLOW_HEAD_REF = name, RELEASEFLOW_HEAD_SHA = name, variables...))
        output = tempname()
        initial!(directory, "first", package, "0.1.0")
        @test passes(on("first", "is-release"; GITHUB_OUTPUT = output))
        @test readchomp(output) == "release=true"
        @test passes(on("first", "version"))
        initial!(directory, "first", package, "0.2.0")
        @test fails(on("first", "version"), "takes a standard first version")
    end
end
