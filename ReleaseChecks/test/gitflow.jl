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
        # Without a version on master, the release would be the initial one, which the repository's tag v0.1.0 contradicts.
        git(directory, "update-ref", "-d", "refs/remotes/origin/master")
        @test fails(on("release/v0.2.0"), "already has the version tags v0.1.0")
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
