# Breaking changes
# ----------------

# The listing of a package's public API, which runs in the package's own project.
const SURFACE = joinpath(@__DIR__, "..", "surface.jl")


# The changes to the compat bounds of Julia and of the package's dependencies, which users of the package resolve against.
# A bound that no longer admits every version that it did drops versions that users of the base may have, so it's breaking; a widened, added or removed bound isn't.
# Bounds of packages that only the tests or docs use don't concern users, and are left out.
function compat_changes(base_project, head_project)
    narrowed = String[]
    other = String[]
    relevant(project) = union(["julia"], keys(get(project, "deps", Dict())), keys(get(project, "weakdeps", Dict())))
    base_compat = get(base_project, "compat", Dict())
    head_compat = get(head_project, "compat", Dict())
    for name in sort(collect(intersect(relevant(base_project), keys(base_compat))))
        base_spec = Pkg.Types.semver_spec(base_compat[name])
        if !haskey(head_compat, name)
            push!(other, "$(name): \"$(base_compat[name])\" → no bound")
        else
            head_spec = Pkg.Types.semver_spec(head_compat[name])
            if intersect(base_spec, head_spec) != base_spec
                push!(narrowed, "$(name): \"$(base_compat[name])\" → \"$(head_compat[name])\", which no longer admits $(base_spec)")
            elseif head_spec != base_spec
                push!(other, "$(name): \"$(base_compat[name])\" → \"$(head_compat[name])\"")
            end
        end
    end
    for name in sort(collect(setdiff(intersect(relevant(head_project), keys(head_compat)), keys(base_compat))))
        push!(other, "$(name): added \"$(head_compat[name])\"")
    end
    return narrowed, other
end

# The environment of the package's own processes: the check's, without its inputs and outputs, which the package's tests may read or pass on, as ReleaseFlow's own do.
# Nor do they take the check's load path, such as the sandbox of a `Pkg.test` that runs the check, which lacks the standard library; each names its project.
package_environment() = filter(((key, _),) -> !startswith(key, "RELEASEFLOW_") && !(key in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "JULIA_LOAD_PATH")), ENV)

# Run Julia with `arguments`, a script or `-e` with code, in a fresh process in the project `directory`, and return whether it succeeded and what it wrote.
function julia_in(directory, arguments::Cmd)
    output = IOBuffer()
    errors = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(directory) $(arguments)`
    process = run(pipeline(ignorestatus(Cmd(command; dir = directory, env = package_environment())); stdout = output, stderr = errors))
    return success(process), String(take!(output)), String(take!(errors))
end

# Run `f` on a copy of the repository at `ref`, in a temporary directory.
function with_checkout(f, settings::Settings, ref)
    directory = mktempdir()
    run(pipeline(`git -C $(settings.root) worktree add --detach $(directory) $(ref)`; stdout = devnull, stderr = devnull))
    try
        return f(directory)
    finally
        run(pipeline(ignorestatus(`git -C $(settings.root) worktree remove --force $(directory)`); stdout = devnull, stderr = devnull))
    end
end

# The entries of the last release's public API that the head no longer provides.
function api_removals(settings::Settings, release::LastRelease, directory, name)
    listing = joinpath(mktempdir(), "base.txt")
    ok, output, errors = julia_in(package_directory(settings, directory), `$(SURFACE) $(name) list`)
    ok || (failure(settings, "Breaking changes", "The public API of $(label(release)) couldn't be listed:\n$(last(errors, 2000))"); return String[])
    write(listing, output)
    ok, output, errors = julia_in(package_directory(settings), `$(SURFACE) $(name) against $(listing)`)
    ok || (failure(settings, "Breaking changes", "The public API of $(head_label(settings)) couldn't be compared:\n$(last(errors, 2000))"); return String[])
    return filter(!isempty, split(output, '\n'))
end

# Run the last release's tests against the head: a copy of the head with the release's `test/` directory.
function old_tests(settings::Settings, release_checkout)
    directory = mktempdir()
    head = package_directory(settings)
    release_directory = package_directory(settings, release_checkout)
    # Without the manifest, which Pkg resolves afresh for the head's dependencies.
    for entry in readdir(head)
        entry in (".git", "test") || startswith(entry, "Manifest") || cp(joinpath(head, entry), joinpath(directory, entry))
    end
    isdir(joinpath(release_directory, "test")) || return true, "the base has no tests"
    cp(joinpath(release_directory, "test"), joinpath(directory, "test"))
    # A release from before the tests were a project of the workspace keeps the head's test project, which the head's workspace names.
    head_test_project = joinpath(head, "test", "Project.toml")
    test_project = joinpath(directory, "test", "Project.toml")
    isfile(test_project) || !isfile(head_test_project) || cp(head_test_project, test_project)
    ok, output, errors = julia_in(directory, `-e "using Pkg; Pkg.test()"`)
    failing = filter(line -> occursin(r"Test Failed at|Error During Test at|Got exception outside of a @test", line), split(output * errors, '\n'))
    # A failure without failing tests, such as one of Pkg, is reported by the end of its output.
    ok || !isempty(failing) || push!(failing, last(errors, 3000))
    return ok, join(failing, "\n")
end

# A breaking change takes a breaking version, which a hotfix can't.
function check_breaking_version(settings::Settings, ::Branch, head, base)
    head in breaking_steps(base) || failure(settings, "Breaking changes", "The changes are breaking for users of $(base), so the version must be $(join(breaking_steps(base), " or ")), not $(head); see the job summary.")
    return
end

check_breaking_version(settings::Settings, ::Branch{Hotfix}, head, base) = failure(settings, "Breaking changes", "A hotfix may not make breaking changes to $(base); release the change from a release branch with a breaking version.")

check(::BreakingCheck, settings::Settings) = check_breaking(settings, last_release(settings))

check_breaking(settings::Settings, ::InitialRelease) = note("This is the initial release, so there's nothing to break.")

function check_breaking(settings::Settings, release::LastRelease)
    head = head_version(settings)
    name = head_project(settings)["name"]
    narrowed, widened = compat_changes(TOML.parse(file_at(settings, release.ref, package_path(settings, "Project.toml"))), head_project(settings))
    removed, (tests_pass, failing) = with_checkout(settings, release.ref) do directory
        api_removals(settings, release, directory, name), old_tests(settings, directory)
    end

    base = label(release)
    report = ["## Breaking changes from $(release.version) to $(head)", ""]
    if isempty(removed)
        push!(report, "The public API of $(base) is still provided.")
    else
        push!(report, "The public API of $(base) that $(head_label(settings)) no longer provides:", "", "```", replace.(removed, '\t' => ' ')..., "```")
    end
    push!(report, "")
    if isempty(narrowed)
        push!(report, "The compat bounds of $(base) are still admitted.")
    else
        push!(report, "The compat bounds that no longer admit every version that $(base) did:", "", "```", narrowed..., "```")
    end
    isempty(widened) || push!(report, "", "Other changes to compat bounds, which aren't breaking:", "", "```", widened..., "```")
    push!(report, "")
    push!(report, tests_pass ? "The tests of $(base) pass." : "The tests of $(base) fail against $(head_label(settings)):\n\n```\n$(failing)\n```")
    summary(settings, join(report, '\n'))
    println(join(report, '\n'))
    isempty(removed) && tests_pass && isempty(narrowed) && return

    check_breaking_version(settings, head_branch(settings), head, release.version)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> is_version(section, head), parsed)
    if index === nothing || subsection_entries(parsed[index], "Breaking") == 0
        failure(settings, "Breaking changes", "The changes are breaking for users of $(release.version), so the section of $(head) in CHANGELOG.md needs a `### Breaking` subsection that describes them; see the job summary.")
    end
    return
end
