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
