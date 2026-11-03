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

# The package's processes resolve its dependencies in the check's depot, which on a fresh runner has no registry, and `Pkg.resolve` installs none.
# So the registry `settings.registry` is installed first, unless it's a path, or installed already.
function install_registry(settings::Settings)
    name = settings.registry
    isdir(name) || any(instance -> instance.name == name, Pkg.Registry.reachable_registries()) || registry(settings)
    return
end

# What a process of Julia wrote to stderr before its stack trace, such as Pkg's message, which names the cause; its end where that's long.
error_message(errors) = last(strip(first(split(errors, r"^\s*Stacktrace:"m))), 2000)

# The entries of the public API of the package `name` in the directory `from`, labelled `from_label`, that the package in `to`, labelled `to_label`, doesn't provide; a failure of the check `check_name` where either can't be loaded.
function api_missing(settings::Settings, check_name, name, (from, from_label), (to, to_label))
    install_registry(settings)
    listing = joinpath(mktempdir(), "listing.txt")
    ok, output, errors = julia_in(from, `$(SURFACE) $(name) list`)
    ok || (failure(settings, check_name, "The public API of $(from_label) couldn't be listed:\n$(error_message(errors))"); return String[])
    write(listing, output)
    ok, output, errors = julia_in(to, `$(SURFACE) $(name) against $(listing)`)
    ok || (failure(settings, check_name, "The public API of $(to_label) couldn't be compared:\n$(error_message(errors))"); return String[])
    return filter(!isempty, split(output, '\n'))
end

# The entries of the last release's public API that the head no longer provides.
api_removals(settings::Settings, release::LastRelease, directory, name) = api_missing(settings, "Breaking changes", name, (package_directory(settings, directory), label(release)), (package_directory(settings), head_label(settings)))

# The lines that start a failure in the output of Julia's tests.
const FAILURE_HEADER = r"Test Failed at|Error During Test at|Got exception outside of a @test"

# The failures in the output of Julia's tests, each from its first line, which names the test set, file and line, to its stack trace, which is left out: the expression, and what it evaluated to or the exception it threw.
# Paths in `directory`, the checkout that the tests ran in, are given relative to it.
function test_failures(output, directory)
    failures = Vector{String}[]
    current = nothing
    for line in split(output, '\n')
        if occursin(FAILURE_HEADER, line)
            current = String[line]
            push!(failures, current)
        elseif current !== nothing
            if isempty(strip(line)) || occursin(r"^\s*Stacktrace:", line) || startswith(line, "Test Summary:")
                current = nothing
            else
                push!(current, line)
            end
        end
    end
    prefixes = unique([joinpath(directory, ""), joinpath(realpath(directory), "")])
    return [replace(join(lines, '\n'), (prefix => "" for prefix in prefixes)...) for lines in failures]
end

# Run the last release's tests against the head: a checkout of the head's commit with the release's `test/` directory.
# The checkout is of the whole repository, so that tests that read the files around a package in a subdirectory still find them.
function old_tests(settings::Settings, release_checkout)
    release_directory = package_directory(settings, release_checkout)
    isdir(joinpath(release_directory, "test")) || return true, String[]
    install_registry(settings)
    return with_checkout(settings, "HEAD") do head_checkout
        directory = package_directory(settings, head_checkout)
        test_directory = joinpath(directory, "test")
        # A release from before the tests were a project of the workspace keeps the head's test project, which the head's workspace names.
        head_test_project = joinpath(test_directory, "Project.toml")
        head_project = isfile(head_test_project) ? read(head_test_project) : nothing
        rm(test_directory; recursive = true, force = true)
        cp(joinpath(release_directory, "test"), test_directory)
        test_project = joinpath(test_directory, "Project.toml")
        isfile(test_project) || head_project === nothing || write(test_project, head_project)
        # Without a committed manifest, which Pkg resolves afresh for the head's dependencies.
        foreach(entry -> startswith(entry, "Manifest") && rm(joinpath(directory, entry)), readdir(directory))
        ok, output, errors = julia_in(directory, `-e "using Pkg; Pkg.test()"`)
        failing = vcat(test_failures(output, head_checkout), test_failures(errors, head_checkout))
        # A failure without failing tests, such as one of Pkg, is reported by the end of its output.
        ok || !isempty(failing) || push!(failing, last(errors, 3000))
        return ok, failing
    end
end

# The file of the head's package that retires tests of earlier releases, whose failures then don't count.
const RETIRED = joinpath("test", "Retired.toml")

# The path and line of a failure, in the repository, from its first line; `nothing` for one without, such as an exception outside a `@test`.
function failure_location(failure)
    found = match(r"(?:Test Failed|Error During Test) at (.+):(\d+)$", first(split(failure, '\n')))
    return found === nothing ? nothing : (found[1], parse(Int, found[2]))
end

# Whether the entry `key` of the retired tests, a path in the package with an optional line, such as `test/register.jl:69`, retires a failure at `location`.
function retires(settings::Settings, key, location)
    location === nothing && return false
    found = match(r"^(.+?)(?::(\d+))?$", key)
    path, line = found[1], found[2]
    return package_path(settings, path) == location[1] && (line === nothing || parse(Int, line) == location[2])
end

# The head's retired tests of `release`, as entries and their reasons, warning of the tables of other releases, which no longer apply.
function retired_tests(settings::Settings, release::LastRelease)
    path = joinpath(package_directory(settings), RETIRED)
    isfile(path) || return Pair{String, String}[]
    tables = try
        TOML.parsefile(path)
    catch error
        failure(settings, "Breaking changes", "$(package_path(settings, RETIRED)) isn't valid TOML: $(sprint(showerror, error))")
        return Pair{String, String}[]
    end
    for version in sort(collect(keys(tables)))
        version == string(release.version) || warning("Breaking changes", "$(package_path(settings, RETIRED)) retires tests of $(version), which isn't the last release, $(release.version), so they no longer apply; remove them.")
    end
    entries = get(tables, string(release.version), Dict())
    if !(entries isa AbstractDict && all(reason -> reason isa String, values(entries)))
        failure(settings, "Breaking changes", "The table `[\"$(release.version)\"]` of $(package_path(settings, RETIRED)) must give each retired test, such as `\"test/runtests.jl:4\"`, its reason as a string.")
        return Pair{String, String}[]
    end
    return sort([key => reason for (key, reason) in entries])
end

# The failures that the entries retire, with the entry of each, and those they don't; warning of entries that retire none, such as a test that no longer fails.
function retire(settings::Settings, entries, failures)
    retired = Pair{String, String}[]
    remaining = String[]
    for failure in failures
        location = failure_location(failure)
        index = findfirst(((key, _),) -> retires(settings, key, location), entries)
        index === nothing ? push!(remaining, failure) : push!(retired, first(entries[index]) => failure)
    end
    for (key, _) in entries
        any(((used, _),) -> used == key, retired) || warning("Breaking changes", "$(package_path(settings, RETIRED)) retires $(key), but no test there fails; remove it.")
    end
    return retired, remaining
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
    removed, (tests_ok, failures) = with_checkout(settings, release.ref) do directory
        api_removals(settings, release, directory, name), old_tests(settings, directory)
    end
    entries = retired_tests(settings, release)
    retired, failing = retire(settings, entries, failures)
    # A failure without a location, such as one of Pkg, can't be retired, so the tests pass where every failure is retired.
    tests_pass = tests_ok || isempty(failing)

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
    push!(report, tests_pass ? "The tests of $(base) pass." : "The tests of $(base) fail against $(head_label(settings)):\n\n```\n$(join(failing, "\n\n"))\n```")
    if !isempty(retired)
        push!(report, "", "The tests of $(base) that $(package_path(settings, RETIRED)) retires, whose failures don't count:", "")
        for (key, reason) in entries
            any(((used, _),) -> used == key, retired) && push!(report, "- `$(key)`: $(reason)")
        end
        push!(report, "", "```", join(last.(retired), "\n\n"), "```")
    end
    summary(settings, join(report, '\n'))
    println(join(report, '\n'))
    isempty(removed) && tests_pass && isempty(narrowed) && return

    check_breaking_version(settings, head_branch(settings), head, release.version)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> is_version(section, head), parsed)
    if index === nothing || subsection_entries(parsed[index], "Breaking") == 0
        failure(settings, "Breaking changes", "The changes are breaking for users of $(release.version), so the section of $(head) in $(package_path(settings, "CHANGELOG.md")) needs a `### Breaking` subsection that describes them; see the job summary.")
    end
    return
end
