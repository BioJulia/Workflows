# Preparing a release
# -------------------

# The outputs that a check wrote, from the file of GitHub Actions' outputs.
function outputs(path)
    result = Dict{String, String}()
    lines = readlines(path)
    index = 1
    while index <= length(lines)
        line = lines[index]
        m = match(r"^([\w-]+)<<(.+)$", line)
        if m === nothing
            name, value = split(line, '='; limit = 2)
            result[name] = value
        else
            stop = findnext(==(m[2]), lines, index + 1)
            result[m[1]] = join(lines[(index + 1):(stop - 1)], '\n')
            index = stop
        end
        index += 1
    end
    return result
end

# Prepare a release in a checkout of `from`, commit it on the branch that it names, and return its outputs and result.
function prepare!(directory, from; variables...)
    git(directory, "checkout", "-q", "--detach", from)
    path = tempname()
    result = check(directory, "prepare"; GITHUB_OUTPUT = path, RELEASEFLOW_DATE = "2026-10-20", variables...)
    prepared = isfile(path) ? outputs(path) : Dict{String, String}()
    if result.code == 0
        git(directory, "checkout", "-q", "-B", prepared["branch"])
        git(directory, "commit", "-q", "-am", "Prepare $(prepared["version"])")
    end
    return (; result, prepared)
end

@testset "Prepare" begin
    @testset "units" begin
        R = ReleaseFlow
        settings(step) = R.Settings(Dict("RELEASEFLOW_STEP" => step))
        log(entries...) = only(filter(section -> section isa R.Section{R.Unreleased}, R.sections(join(["## [Unreleased]", "", entries...], '\n'))))
        @test R.auto_step(log("- A fix.")) == "patch"
        @test R.auto_step(log("### Added", "", "- A feature.")) == "minor"
        @test R.auto_step(log("### Breaking", "", "- A removal.", "", "### Added", "", "- A feature.")) == "breaking"
        @test R.auto_step(nothing) == "patch"
        last(version) = R.LastRelease{R.MainBranch}(version, "origin/master")
        @test R.next_version(settings("auto"), R.Release(), last(v"0.1.3"), log("### Breaking", "", "- x")) == v"0.2.0"
        @test R.next_version(settings("auto"), R.Release(), last(v"1.2.3"), log("### Breaking", "", "- x")) == v"2.0.0"
        @test R.next_version(settings("auto"), R.Release(), last(v"1.2.3"), log("### Added", "", "- x")) == v"1.3.0"
        @test R.next_version(settings("major"), R.Release(), last(v"1.2.3"), nothing) == v"2.0.0"
        @test R.next_version(settings("minor"), R.Hotfix(), last(v"1.2.3"), nothing) == v"1.2.4"
        @test R.next_version(settings("auto"), R.Release(), R.InitialRelease(), nothing) == v"0.1.0"
        @test R.next_version(settings("major"), R.Release(), R.InitialRelease(), nothing) == v"1.0.0"
        @test R.next_version(settings("patch"), R.Release(), R.InitialRelease(), nothing) == v"0.0.1"
    end

    @testset "gitflow" begin
        directory, released, feature = gitflow_repository()
        # A release from develop: the next patch, as the unreleased entries add nothing, and break nothing.
        prepared = prepare!(directory, feature)
        @test passes(prepared.result)
        @test prepared.prepared["version"] == "0.1.1" && prepared.prepared["branch"] == "release/v0.1.1" && prepared.prepared["base"] == "master"
        @test prepared.prepared["notes"] == "- A feature."
        for check_name in ("source", "version", "changelog")
            @test passes(check(directory, check_name; RELEASEFLOW_BASE_BRANCH = "master", RELEASEFLOW_HEAD_REF = "release/v0.1.1", RELEASEFLOW_HEAD_SHA = "release/v0.1.1"))
        end
        text = read(joinpath(directory, "CHANGELOG.md"), String)
        @test occursin("## [Unreleased]\n\n## [0.1.1] - 2026-10-20\n\n- A feature.", text)
        @test occursin("[Unreleased]: $(URL)/compare/v0.1.1...HEAD\n[0.1.1]: $(URL)/compare/v0.1.0...v0.1.1\n[0.1.0]: $(URL)/releases/tag/v0.1.0", text)
        @test occursin("version = \"0.1.1\"", read(joinpath(directory, "Project.toml"), String))
        # `### Added` takes the next minor version, and a step can be asked for.
        branch!(directory, "develop", feature)
        added = commit!(directory, "Added", "CHANGELOG.md" => replace(changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]]), "## [Unreleased]\n\n" => "## [Unreleased]\n\n### Added\n\n"))
        @test prepare!(directory, added).prepared["version"] == "0.2.0"
        @test prepare!(directory, feature; RELEASEFLOW_STEP = "major").prepared["version"] == "1.0.0"
        # A hotfix from master, the next patch, whose empty section waits for the fix's entry.
        hotfix = prepare!(directory, released; RELEASEFLOW_KIND = "hotfix")
        @test passes(hotfix.result) && hotfix.prepared["branch"] == "hotfix/v0.1.1"
        @test passes(check(directory, "version"; RELEASEFLOW_HEAD_REF = "hotfix/v0.1.1", RELEASEFLOW_HEAD_SHA = "hotfix/v0.1.1"))
        @test fails(check(directory, "changelog"; RELEASEFLOW_HEAD_REF = "hotfix/v0.1.1"), "The section of 0.1.1 in CHANGELOG.md has no entries")
        # A wrong kind or step is an error.
        @test fails(prepare!(directory, feature; RELEASEFLOW_KIND = "feature").result, "RELEASEFLOW_KIND is `release` or `hotfix`")
        @test fails(prepare!(directory, feature; RELEASEFLOW_STEP = "huge").result, "RELEASEFLOW_STEP is `auto`, `patch`, `minor` or `major`")
    end

    @testset "pins" begin
        directory, released, feature = gitflow_repository()
        branch!(directory, "develop", feature)
        pinned = commit!(
            directory, "Workflows", ".github/workflows/a.yml" => "jobs:\n  a:\n    steps:\n      - uses: Example/Toy.jl@v0.1.0\n      - uses: Example/Toy.jl/.github/workflows/b.yml@v0.1.0\n",
            ".github/workflows/c.yml" => "jobs:\n  c:\n    uses: Example/Toy.jl/.github/workflows/b.yml@v1\n    steps:\n      - uses: Other/Action@v0.1.0\n",
        )
        @test passes(prepare!(directory, pinned; RELEASEFLOW_PIN_ACTION = "Example/Toy.jl").result)
        @test read(joinpath(directory, ".github", "workflows", "a.yml"), String) == "jobs:\n  a:\n    steps:\n      - uses: Example/Toy.jl@v0.1.1\n      - uses: Example/Toy.jl/.github/workflows/b.yml@v0.1.1\n"
        # A major tag, and other actions, stay.
        @test read(joinpath(directory, ".github", "workflows", "c.yml"), String) == "jobs:\n  c:\n    uses: Example/Toy.jl/.github/workflows/b.yml@v1\n    steps:\n      - uses: Other/Action@v0.1.0\n"
    end

    @testset "initial release" begin
        directory, start, package = initial_repository()
        prepared = prepare!(directory, package)
        @test prepared.prepared["version"] == "0.1.0"
        for check_name in ("version", "changelog")
            @test passes(check(directory, check_name; RELEASEFLOW_HEAD_REF = "release/v0.1.0", RELEASEFLOW_HEAD_SHA = "release/v0.1.0"))
        end
        @test occursin("[0.1.0]: $(URL)/releases/tag/v0.1.0", read(joinpath(directory, "CHANGELOG.md"), String))
        @test fails(prepare!(directory, package; RELEASEFLOW_KIND = "hotfix").result, "a hotfix can't be the initial release")
    end

    @testset "OneFlow and trunk" begin
        directory, released, feature, scratch = oneflow_repository()
        model = (RELEASEFLOW_MODEL = "oneflow", RELEASEFLOW_MAIN_BRANCH = "main", RELEASEFLOW_BASE_BRANCH = "main", RELEASEFLOW_REGISTRY = scratch)
        @test prepare!(directory, feature; model...).prepared["branch"] == "release/v0.1.1"
        for check_name in ("source", "version", "changelog")
            @test passes(check(directory, check_name; model..., RELEASEFLOW_HEAD_REF = "release/v0.1.1", RELEASEFLOW_HEAD_SHA = "release/v0.1.1"))
        end
        # A OneFlow hotfix starts from the last release's tag.
        @test prepare!(directory, "v0.1.0"; model..., RELEASEFLOW_KIND = "hotfix").prepared["branch"] == "hotfix/v0.1.1"
        @test passes(check(directory, "source"; model..., RELEASEFLOW_HEAD_REF = "hotfix/v0.1.1", RELEASEFLOW_HEAD_SHA = "hotfix/v0.1.1"))
        trunk = (RELEASEFLOW_MODEL = "trunk", RELEASEFLOW_MAIN_BRANCH = "main", RELEASEFLOW_BASE_BRANCH = "main", RELEASEFLOW_REGISTRY = scratch)
        @test prepare!(directory, feature; trunk...).prepared["branch"] == "release/v0.1.1"
        @test fails(prepare!(directory, feature; trunk..., RELEASEFLOW_KIND = "hotfix").result, "The trunk model has no hotfixes")
        # A changelog without an unreleased section, as FASTX.jl keeps it, takes the new section before the newest version's.
        branch!(directory, "plain", released)
        plain = commit!(directory, "Plain", "CHANGELOG.md" => changelog(released = ["0.1.0" => ["First."]], heading = nothing, bullet = "*", links = false))
        @test passes(prepare!(directory, plain; trunk..., RELEASEFLOW_CHECK_LINKS = false).result)
        @test startswith(read(joinpath(directory, "CHANGELOG.md"), String), "# Changelog\n\n## [0.1.1] - 2026-10-20\n\n## [0.1.0]")
    end
end
