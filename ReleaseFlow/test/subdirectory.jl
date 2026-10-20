# A package in a subdirectory
# ---------------------------

# The package in `lib/Toy`: its files there, and a README at the repository's root.
in_lib(files::Pair...) = ("lib/Toy/$(path)" => contents for (path, contents) in files)
# Its tests read the README, around the package, which the breaking check's run of the released tests still finds.
const LIB_TESTS = TESTS * "@test isfile(joinpath(@__DIR__, \"..\", \"..\", \"..\", \"README.md\"))\n"

@testset "Subdirectory" begin
    directory = repository(; branch = "main")
    released = commit!(directory, "Release 0.1.0", "README.md" => "Toy.", in_lib("Project.toml" => project("0.1.0"), "src/Toy.jl" => SOURCE, "test/runtests.jl" => LIB_TESTS, "CHANGELOG.md" => changelog(released = ["0.1.0" => ["First."]]))...)
    git(directory, "tag", "v0.1.0")
    feature = commit!(directory, "Feature", in_lib("feature.txt" => "feature", "CHANGELOG.md" => changelog(unreleased = ["A feature."], released = ["0.1.0" => ["First."]]))...)
    origin!(directory, "main", feature)
    # A registry records the tree of the package's subdirectory, not the repository's.
    package_tree = git(directory, "rev-parse", "$(released):lib/Toy")
    scratch = registry("0.1.0" => package_tree)
    model = (RELEASEFLOW_MODEL = "oneflow", RELEASEFLOW_MAIN_BRANCH = "main", RELEASEFLOW_BASE_BRANCH = "main", RELEASEFLOW_PROJECT = "lib/Toy", RELEASEFLOW_REGISTRY = scratch)
    on(name, check_name; variables...) = (git(directory, "checkout", "-q", name); check(directory, check_name; merge(merge(model, (RELEASEFLOW_HEAD_REF = name, RELEASEFLOW_HEAD_SHA = name)), variables)...))

    branch!(directory, "release/v0.2.0", feature)
    commit!(directory, "Release 0.2.0", in_lib("Project.toml" => project("0.2.0"), "CHANGELOG.md" => changelog(released = ["0.2.0" => ["A feature."], "0.1.0" => ["First."]]))...)
    for check_name in ("source", "version", "changelog", "breaking")
        @test passes(on("release/v0.2.0", check_name))
    end
    @test occursin("is the commit $(first(released, 7)), which Scratch records and v0.1.0 tags", on("release/v0.2.0", "version").output)
    # The tree of the repository isn't the package's.
    @test fails(on("release/v0.2.0", "version"; RELEASEFLOW_REGISTRY = registry("0.1.0" => tree(directory, released))), "no branch or tag has a commit with it")
    # The package's files are read from its directory.
    @test fails(on("release/v0.2.0", "version"; RELEASEFLOW_PROJECT = ""), "Project.toml")
    branch!(directory, "feature/x", feature)
    commit!(directory, "Work", in_lib("CHANGELOG.md" => changelog(unreleased = ["A feature.", "Another."], released = ["0.1.0" => ["First."]]))...)
    @test passes(on("feature/x", "entry"))
    branch!(directory, "feature/y", feature)
    commit!(directory, "Work", "README.md" => "Toy, documented.")
    @test fails(on("feature/y", "entry"), "no new entry")
    # A breaking change is found in the package's directory.
    branch!(directory, "release/v0.1.1", feature)
    commit!(directory, "Release 0.1.1", in_lib("Project.toml" => project("0.1.1"), "src/Toy.jl" => replace(SOURCE, "triple(x) = 3x" => ""), "CHANGELOG.md" => changelog(released = ["0.1.1" => ["A feature."], "0.1.0" => ["First."]]))...)
    @test fails(on("release/v0.1.1", "breaking"), "must be 0.2.0 or 1.0.0, not 0.1.1")
end
