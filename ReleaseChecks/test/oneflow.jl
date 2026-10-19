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
