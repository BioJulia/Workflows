# Checks of the pull requests of a Julia package, under one of three branching models.
#
# - gitflow: a main branch of releases and a develop branch of unreleased work.
#   Into the main branch come only release and hotfix branches; a hotfix carries no unreleased commit of develop, as it branches from the main branch, and a release carries develop's unreleased commits, as it branches from develop.
#   Into develop come any other branches, each with a new changelog entry.
# - oneflow: one main branch, from which release and hotfix branches are released, registered at their last commit, and merged back.
#   A hotfix branches from the last release's tag, and a release carries the main branch's work since then; any other branch adds a changelog entry.
# - trunk: one main branch, on which a release is a commit that changes the version; any other pull request adds a changelog entry.
#
# A release takes the next version, a changelog section that describes it, and, if it breaks the last release, a breaking version and a `### Breaking` subsection.
# A change is breaking if the last release's public API is no longer provided, if its tests fail, or if a compat bound no longer admits every version that it did.
# The last release is the main branch's version, at the commit that the registry records for it, cross-checked with its tag `vX.Y.Z`; gitflow compares with the main branch itself, which holds only releases.
# Git doesn't record which branch a branch was made from, only its commits, so the rules about origins look at the commits.
#
# Each check is a method of `check(::C, ::Settings{M})`; the rules that differ between models dispatch on the model `M`, those that differ between kinds of branch on the kind `K` of a `Branch{K}`, and those that differ by where the last release was found on the source `S` of a `LastRelease{S}`.
#
# Run from the root of the package's repository with `julia checks.jl source|version|changelog|breaking|entry|release`.
# Inputs are environment variables, so that branch names never reach a shell, and an empty one counts as missing:
# - `MODEL`, `gitflow`, `oneflow` or `trunk`, `gitflow` unless given;
# - `MAIN_BRANCH` and `DEVELOP_BRANCH`, `master` and `develop` unless given;
# - `HEAD_REF`, the source branch, such as `release/v0.2.0`;
# - `HEAD_SHA`, the pull request's head commit, `HEAD` unless given; in GitHub Actions, `HEAD` is the merge commit, which already contains the base;
# - `BASE_BRANCH`, the name of the branch that the pull request merges into, for `source`;
# - `BASE_REF`, what the pull request merges into, `origin/<MAIN_BRANCH>` unless given;
# - `DEVELOP_REF`, `origin/<DEVELOP_BRANCH>` unless given;
# - `SKIP_CHANGELOG`, `true` where the pull request has the label `SKIP_LABEL`, `skip changelog` unless given, for `entry`;
# - `CHECK_LINKS`, whether the changelog's comparison links are checked, `true` unless given;
# - `REGISTRY`, the name of an installed registry, or the path of a registry's directory, `General` unless given.
# The base's files are read with `git show`, and a base without them, as before the first release, has no version and no changelog.

using Pkg
using TOML
using UUIDs

# Models
# ------

abstract type Model end

"A main branch of releases and a develop branch of unreleased work."
struct Gitflow <: Model end

"One main branch, from which release and hotfix branches are released at their last commit, and merged back."
struct OneFlow <: Model end

"One main branch, on which a release is a commit that changes the version."
struct Trunk <: Model end

const MODELS = Dict("gitflow" => Gitflow(), "oneflow" => OneFlow(), "trunk" => Trunk())

title(model::Model) = string(nameof(typeof(model)))

# Settings
# --------

"The inputs of a run of the checks under the model `M`, and what the run has found, such as the registry and the last release."
struct Settings{M <: Model}
    model::M
    root::String
    main_branch::String
    develop_branch::String
    head_ref::String
    head_sha::String
    base_branch::String
    base_ref::String
    develop_ref::String
    skip_label::String
    skip_changelog::Bool
    check_links::Bool
    registry::String
    found::Dict{Symbol, Any}
end

# An input, or `default` where it's missing or empty, as GitHub Actions passes an input that it has no value for.
input(environment, name, default) = (value = get(environment, name, ""); isempty(value) ? default : value)

function Settings(environment = ENV; root = pwd())
    main_branch = input(environment, "MAIN_BRANCH", "master")
    develop_branch = input(environment, "DEVELOP_BRANCH", "develop")
    return Settings(
        MODELS[input(environment, "MODEL", "gitflow")],
        root,
        main_branch,
        develop_branch,
        input(environment, "HEAD_REF", ""),
        input(environment, "HEAD_SHA", "HEAD"),
        input(environment, "BASE_BRANCH", ""),
        input(environment, "BASE_REF", "origin/$(main_branch)"),
        input(environment, "DEVELOP_REF", "origin/$(develop_branch)"),
        input(environment, "SKIP_LABEL", "skip changelog"),
        lowercase(input(environment, "SKIP_CHANGELOG", "false")) == "true",
        lowercase(input(environment, "CHECK_LINKS", "true")) == "true",
        input(environment, "REGISTRY", "General"),
        Dict{Symbol, Any}(),
    )
end

# What `find` gives, found once per run.
found!(find, settings::Settings, key::Symbol) = get!(find, settings.found, key)

head_label(settings::Settings) = isempty(settings.head_ref) ? settings.head_sha : settings.head_ref

# Reporting
# ---------

const ERRORS = String[]

# Report a failure as an annotation of GitHub Actions, which a pull request shows, and remember it.
function failure(title, message)
    println("::error title=$(title)::", replace(message, "\n" => "%0A"))
    push!(ERRORS, message)
    return
end

note(message) = println("::notice::", replace(message, "\n" => "%0A"))

# Append Markdown to the job's summary, which GitHub Actions shows on the run's page.
function summary(text)
    path = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(path) || open(io -> println(io, text), path, "a")
    return
end

# Git
# ---

# The output of `git arguments...` in the repository, without its last newline, or `nothing` where git fails.
function git(settings::Settings, arguments...)
    output = IOBuffer()
    process = run(pipeline(ignorestatus(`git -C $(settings.root) $(arguments)`); stdout = output, stderr = devnull))
    return success(process) ? chomp(String(take!(output))) : nothing
end

# The contents of `path` at `ref`, or `nothing` where `ref` has no such file, or doesn't exist.
file_at(settings::Settings, ref, path) = git(settings, "show", "$(ref):$(path)")

base_file(settings::Settings, path) = file_at(settings, settings.base_ref, path)

has_ref(settings::Settings, ref) = git(settings, "rev-parse", "--verify", "--quiet", "$(ref)^{commit}") !== nothing

has_base(settings::Settings) = has_ref(settings, settings.base_ref)

has_tag(settings::Settings, tag) = has_ref(settings, "refs/tags/$(tag)")

# The commit where `a` and `b` last met, or `nothing` where they never did.
merge_base(settings::Settings, a, b) = git(settings, "merge-base", a, b)

is_ancestor(settings::Settings, a, b) = git(settings, "merge-base", "--is-ancestor", a, b) !== nothing

tree_of(settings::Settings, ref) = git(settings, "rev-parse", "$(ref)^{tree}")

# The first commit of any branch or tag whose tree is `tree`, or `nothing`.
function commit_with_tree(settings::Settings, tree)
    for line in split(something(git(settings, "log", "--all", "--format=%H %T"), ""), '\n')
        commit, commit_tree = (split(line, ' ')..., "", "")
        commit_tree == tree && return String(commit)
    end
    return nothing
end

# The package
# -----------

head_project(settings::Settings) = TOML.parsefile(joinpath(settings.root, "Project.toml"))

head_version(settings::Settings) = VersionNumber(head_project(settings)["version"])

function base_version(settings::Settings)
    project = base_file(settings, "Project.toml")
    project === nothing && return nothing
    version = get(TOML.parse(project), "version", nothing)
    return version === nothing ? nothing : VersionNumber(version)
end

# Branches
# --------

abstract type Kind end

"A branch that releases the next version of the unreleased work."
struct Release <: Kind end

"A branch that releases a fix to the last release."
struct Hotfix <: Kind end

"A branch of unreleased work."
struct Feature <: Kind end

"A branch that brings the main branch back into develop: the main branch itself, or a `back-merge/vX.Y.Z` branch at it."
struct BackMerge <: Kind end

"The branch that a pull request comes from, of the kind `K`, with the version that its name gives, if any."
struct Branch{K <: Kind}
    name::String
    version::Union{VersionNumber, Nothing}
end

Branch{K}(name) where {K} = Branch{K}(name, nothing)

const ReleaseOrHotfix = Union{Branch{Release}, Branch{Hotfix}}

kind_name(::Branch) = "release"
kind_name(::Branch{Hotfix}) = "hotfix"

# The branch of the pull request, from its name.
function head_branch(settings::Settings)
    name = settings.head_ref
    m = match(r"^(release|hotfix)/v?(\d+\.\d+\.\d+\S*)$", name)
    m === nothing || return (m[1] == "hotfix" ? Branch{Hotfix} : Branch{Release})(name, tryparse(VersionNumber, m[2]))
    startswith(name, "hotfix/") && return Branch{Hotfix}(name)
    startswith(name, "release/") && return Branch{Release}(name)
    (name == settings.main_branch || startswith(name, "back-merge/")) && return Branch{BackMerge}(name)
    return Branch{Feature}(name)
end

# Under trunk, a pull request that changes the version is a release, whatever its branch's name.
head_branch(settings::Settings{Trunk}) = (is_release(settings) ? Branch{Release} : Branch{Feature})(settings.head_ref)

# Whether the pull request is a release, which moves the changelog's entries rather than adding one.
is_release(settings::Settings) = head_branch(settings) isa ReleaseOrHotfix
is_release(settings::Settings{Trunk}) = found!(() -> base_version(settings) != head_version(settings), settings, :is_release)

# The registry
# ------------

# The registry `settings.registry`, updated, or `nothing` where it can't be had; a path is read as it is, as the tests do.
registry(settings::Settings) = found!(() -> open_registry(settings.registry), settings, :registry)

function open_registry(name)
    try
        isdir(name) && return Pkg.Registry.RegistryInstance(name)
        installed = any(instance -> instance.name == name, Pkg.Registry.reachable_registries())
        installed ? Pkg.Registry.update(name; io = devnull) : Pkg.Registry.add(name; io = devnull)
        return only(filter(instance -> instance.name == name, Pkg.Registry.reachable_registries()))
    catch exception
        note("The registry $(name) couldn't be read, so releases are found by their tags: $(sprint(showerror, exception))")
        return nothing
    end
end

# The registry's name, for messages.
registry_name(settings::Settings) = (instance = registry(settings); instance === nothing ? settings.registry : instance.name)

# The tree of the package's `version` that the registry records, or `nothing` where it records none.
function registered_tree(settings::Settings, version)
    instance = registry(settings)
    instance === nothing && return nothing
    entry = get(instance, UUID(head_project(settings)["uuid"]), nothing)
    entry === nothing && return nothing
    # Pkg's registry API changed in Julia 1.13, which passes the registry with the entry.
    info = applicable(Pkg.Registry.registry_info, instance, entry) ? Pkg.Registry.registry_info(instance, entry) : Pkg.Registry.registry_info(entry)
    version_info = get(info.version_info, version, nothing)
    return version_info === nothing ? nothing : string(version_info.git_tree_sha1)
end

# The last release
# ----------------

abstract type Source end

"A release whose commit the registry records."
struct Registered <: Source end

"A release that only its tag records."
struct Tagged <: Source end

"A release that is the main branch itself: under gitflow, or before a package is registered or tagged."
struct MainBranch <: Source end

"The last release, found from the source `S`: its version, and the commit to compare with."
struct LastRelease{S <: Source}
    version::VersionNumber
    ref::String
end

label(release::LastRelease) = "the release $(release.version)"
label(release::LastRelease{MainBranch}) = release.ref

# The last release, or `nothing` before the first.
last_release(settings::Settings) = found!(settings, :last_release) do
    has_base(settings) || return nothing
    version = base_version(settings)
    version === nothing ? nothing : find_last_release(settings, version)
end

# Gitflow compares with the main branch, which holds only releases.
find_last_release(settings::Settings{Gitflow}, version) = LastRelease{MainBranch}(version, settings.base_ref)

# Otherwise, the main branch's version, at the commit whose tree the registry records for it, which must agree with its tag; else at its tag, or at the main branch, for a package not yet registered.
function find_last_release(settings::Settings, version)
    tag = "v$(version)"
    tagged = has_tag(settings, tag)
    tree = registered_tree(settings, version)
    name = registry_name(settings)
    if tree !== nothing
        commit = commit_with_tree(settings, tree)
        if commit === nothing
            failure("Release", "$(name) records the tree $(tree) for $(version), but no branch or tag has a commit with it; fetch the whole history, or tag the release.")
            return nothing
        end
        if tagged && tree_of(settings, tag) != tree
            failure("Release", "The tag $(tag) isn't the release of $(version) that $(name) records: its tree is $(tree_of(settings, tag)), but the registered tree is $(tree), of the commit $(commit); move the tag.")
        end
        println("The last release, $(version), is the commit $(first(commit, 7)), which $(name) records$(tagged ? " and $(tag) tags" : "").")
        return LastRelease{Registered}(version, commit)
    elseif tagged
        note("$(name) doesn't record $(version), so the last release is the tag $(tag).")
        return LastRelease{Tagged}(version, tag)
    else
        note("$(name) doesn't record $(version), and there's no tag $(tag), so the last release is $(settings.base_ref).")
        return LastRelease{MainBranch}(version, settings.base_ref)
    end
end

# The checks
# ----------

abstract type Check end

struct SourceCheck <: Check end
struct VersionCheck <: Check end
struct ChangelogCheck <: Check end
struct BreakingCheck <: Check end
struct EntryCheck <: Check end
struct ReleaseCheck <: Check end

const CHECKS = Dict(
    "source" => SourceCheck(), "version" => VersionCheck(), "changelog" => ChangelogCheck(),
    "breaking" => BreakingCheck(), "entry" => EntryCheck(), "release" => ReleaseCheck(),
)

# Source branch
# -------------

function check(::SourceCheck, settings::Settings)
    if settings.base_branch == settings.main_branch
        into_main(settings, head_branch(settings))
    elseif settings.base_branch == settings.develop_branch
        into_develop(settings, head_branch(settings))
    else
        uncovered(settings)
    end
    return
end

check(::SourceCheck, ::Settings{Trunk}) = note("The trunk model has no rules about source branches.")

uncovered(settings::Settings) = note("The $(title(settings.model)) checks don't cover pull requests into $(isempty(settings.base_branch) ? "an unnamed branch; set BASE_BRANCH" : settings.base_branch).")

# Only gitflow has a develop branch.
into_develop(settings::Settings, ::Branch) = uncovered(settings)

# Gitflow: the main branch takes merges only from release and hotfix branches; develop takes them from any other branch, and release and hotfix branches reach it through the main branch.
function into_main(settings::Settings{Gitflow}, branch::ReleaseOrHotfix)
    println("$(settings.main_branch) takes the merge of $(branch.name), a release or hotfix branch.")
    check_origin(settings, branch, settings.develop_ref, settings.develop_branch, settings.base_ref, settings.main_branch)
    return
end

into_main(settings::Settings{Gitflow}, branch::Branch) = failure("Gitflow", "$(settings.main_branch) takes merges only from release/* and hotfix/* branches, as gitflow does, not from $(branch.name); merge features into $(settings.develop_branch).")

into_develop(settings::Settings{Gitflow}, branch::ReleaseOrHotfix) = failure("Gitflow", "$(settings.develop_branch) doesn't take merges from release/* and hotfix/* branches, such as $(branch.name); merge it into $(settings.main_branch), and then merge $(settings.main_branch) into $(settings.develop_branch).")

into_develop(settings::Settings{Gitflow}, branch::Branch) = println("$(settings.develop_branch) takes the merge of $(branch.name).")

# OneFlow: the main branch takes any branch; a hotfix branches from the last release's tag, and a release carries the main branch's work since then.
function into_main(settings::Settings{OneFlow}, branch::ReleaseOrHotfix)
    release = last_release(settings)
    if release === nothing || release isa LastRelease{MainBranch}
        note("There's no earlier release, so where $(branch.name) came from isn't checked.")
    else
        println("$(settings.main_branch) takes the merge of $(branch.name), a release or hotfix branch.")
        check_origin(settings, branch, settings.base_ref, settings.main_branch, release.ref, "the release $(release.version), v$(release.version)")
    end
    return
end

into_main(settings::Settings{OneFlow}, branch::Branch) = println("$(settings.main_branch) takes the merge of $(branch.name).")

# A hotfix branches from what's released, so the point where it last met the branch of unreleased work, `unreleased`, is already released; a release branches from that branch, so that point isn't released yet.
# The head commit is compared, not the merge commit that GitHub Actions checks out, and with this repository's branches, so a fork's own branches don't matter.
function check_origin(settings::Settings, branch::ReleaseOrHotfix, unreleased, unreleased_name, released, released_name)
    if !has_ref(settings, unreleased)
        note("There's no $(unreleased), so where $(branch.name) came from isn't checked.")
        return
    end
    fork = merge_base(settings, settings.head_sha, unreleased)
    is_released = fork === nothing || is_ancestor(settings, fork, released)
    origin(settings, branch, is_released, fork, unreleased_name, released, released_name)
    return
end

function origin(settings::Settings, branch::Branch{Hotfix}, is_released, fork, unreleased_name, released, released_name)
    if is_released
        println("$(branch.name) carries no unreleased commit of $(unreleased_name).")
    else
        commits = split(something(git(settings, "log", "--oneline", "-n", "5", "$(released)..$(fork)"), ""), '\n')
        failure(title(settings.model), "The hotfix $(branch.name) carries unreleased commits of $(unreleased_name), such as:\n$(join(commits, '\n'))\nBranch a hotfix from $(released_name).")
    end
    return
end

function origin(settings::Settings, branch::Branch{Release}, is_released, fork, unreleased_name, released, released_name)
    if is_released
        failure(title(settings.model), "The release $(branch.name) carries none of the unreleased commits of $(unreleased_name); branch a release from $(unreleased_name).")
    else
        println("$(branch.name) carries the unreleased commits of $(unreleased_name).")
    end
    return
end

# Versions
# --------

next_patch(v) = VersionNumber(v.major, v.minor, v.patch + 1)
next_minor(v) = VersionNumber(v.major, v.minor + 1, 0)
next_major(v) = VersionNumber(v.major + 1, 0, 0)

# The steps that a version may take from `base`.
single_steps(base) = (next_patch(base), next_minor(base), next_major(base))

# The steps that a breaking change may take from `base`: the next major version, or below 1.0 the next minor version, which Julia's compat treats as breaking.
breaking_steps(base) = base.major == 0 ? (next_minor(base), next_major(base)) : (next_major(base),)

# A release or hotfix branch's name gives its version; trunk names no versions.
check_name(::Settings, branch::Branch, head) = unnamed(branch, head)

function check_name(::Settings, branch::ReleaseOrHotfix, head)
    if branch.version === nothing
        unnamed(branch, head)
    elseif branch.version != head
        failure("Version", "The branch $(branch.name) names $(branch.version), but Project.toml has $(head); they must agree.")
    end
    return
end

check_name(::Settings{Trunk}, ::Branch, head) = nothing
check_name(::Settings{Trunk}, ::ReleaseOrHotfix, head) = nothing

unnamed(branch::Branch, head) = failure("Version", "The branch $(branch.name) doesn't name a version; name it $(kind_name(branch))/v$(head), after the version in Project.toml.")

# A version takes a single step up from the last release's, and a hotfix the next patch.
function check_step(::Branch, head, base)
    head in single_steps(base) || not_a_step(head, base)
    return
end

function check_step(::Branch{Hotfix}, head, base)
    head in single_steps(base) || return not_a_step(head, base)
    head == next_patch(base) || failure("Version", "A hotfix releases the next patch, $(next_patch(base)), not $(head).")
    return
end

not_a_step(head, base) = failure("Version", "The version $(head) isn't a single step up from $(base); the next is $(join(single_steps(base), ", ", " or ")).")

function check(::VersionCheck, settings::Settings)
    head = head_version(settings)
    base = base_version(settings)
    println("Version: $(head) on $(head_label(settings)); $(base === nothing ? "no version" : base) on $(settings.base_ref).")
    isempty(head.prerelease) && isempty(head.build) || failure("Version", "The version $(head) has a prerelease or build suffix; a release has neither.")
    branch = head_branch(settings)
    check_name(settings, branch, head)

    # A release may be registered and tagged before it merges, as OneFlow does, but only at this commit.
    head_tree = tree_of(settings, settings.head_sha)
    registered = registered_tree(settings, head)
    registered === nothing || registered == head_tree || failure("Version", "$(registry_name(settings)) already records $(head), with another tree; a release takes a new version.")
    tag = "v$(head)"
    has_tag(settings, tag) && tree_of(settings, tag) != head_tree && failure("Version", "The version $(head) is already tagged, $(tag), at another commit; a release takes a new version.")

    if base === nothing
        note("$(settings.base_ref) has no version, so $(head) is the first release.")
    else
        # Finding the last release checks that its tag agrees with the registry.
        last_release(settings)
        check_step(branch, head, base)
    end
    return
end

# Changelog
# ---------

abstract type Heading end

"The heading of the unreleased changes, `## [Unreleased]` or `## UNRELEASED`."
struct Unreleased <: Heading end

"The heading of a released version, such as `## [0.2.0] - 2026-10-19`."
struct Released <: Heading
    version::VersionNumber
end

"Any other heading of the second level."
struct Other <: Heading end

"A section of a changelog, under a heading of the kind `H`, and its lines."
struct Section{H <: Heading}
    heading::H
    lines::Vector{String}
end

Section(heading::Heading) = Section(heading, String[])

const UNRELEASED = r"^##\s+(UNRELEASED|\[Unreleased\])\s*$"i
const RELEASED = r"^##\s+\[?v?(\d+\.\d+\.\d+[^\]\s]*)\]?"

function heading(line)
    occursin(UNRELEASED, line) && return Unreleased()
    m = match(RELEASED, line)
    version = m === nothing ? nothing : tryparse(VersionNumber, m[1])
    return version === nothing ? Other() : Released(version)
end

# The sections of a changelog, in order.
function sections(text)
    result = Section[]
    for line in split(text, '\n')
        if startswith(line, "## ")
            push!(result, Section(heading(line)))
        elseif !isempty(result)
            push!(last(result).lines, line)
        end
    end
    return result
end

is_version(::Section, version) = false
is_version(section::Section{Released}, version) = section.heading.version == version

versions(sections) = VersionNumber[section.heading.version for section in sections if section isa Section{Released}]

unreleased_index(sections) = findfirst(section -> section isa Section{Unreleased}, sections)

# An entry is an item of a list, with any of Markdown's markers.
is_entry(line) = occursin(r"^[-*+]\s", line)

entries(section::Section) = filter(is_entry, section.lines)

unreleased_entries(sections) = (index = unreleased_index(sections); index === nothing ? String[] : entries(sections[index]))

# The entries of the subsection `title`, such as `### Breaking`, of `section`.
function subsection_entries(section::Section, title)
    inside = false
    found = 0
    for line in section.lines
        if startswith(line, "### ")
            inside = lowercase(strip(line[5:end])) == lowercase(title)
        elseif inside && is_entry(line)
            found += 1
        end
    end
    return found
end

function head_changelog(settings::Settings)
    path = joinpath(settings.root, "CHANGELOG.md")
    isfile(path) || (failure("Changelog", "There's no CHANGELOG.md."); return nothing)
    return read(path, String)
end

# The URL of the repository on GitHub, from `GITHUB_REPOSITORY` in GitHub Actions, or from the `origin` remote locally; `nothing` where neither gives one.
function repository_url(settings::Settings)
    repository = get(ENV, "GITHUB_REPOSITORY", "")
    if isempty(repository)
        remote = something(git(settings, "remote", "get-url", "origin"), "")
        m = match(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", remote)
        m === nothing && return nothing
        repository = m[1]
    end
    return "https://github.com/$(repository)"
end

# The link definitions of a changelog, such as `[0.2.0]: https://…`, from each label, in lower case, as Markdown matches labels, to its URL.
function links(text)
    result = Dict{String, String}()
    for line in split(text, '\n')
        m = match(r"^\[([^\]]+)\]:\s*(\S+)", line)
        m === nothing || (result[lowercase(m[1])] = m[2])
    end
    return result
end

# Whether `link` compares the tag of `version` with that of an earlier version, as the oldest section of a changelog begun after earlier releases may.
function from_earlier(link, url, version)
    prefix = "$(url)/compare/v"
    suffix = "...v$(version)"
    startswith(link, prefix) && endswith(link, suffix) || return false
    earlier = tryparse(VersionNumber, chopsuffix(chopprefix(link, prefix), suffix))
    return earlier !== nothing && earlier < version
end

# Each version's heading links to the comparison of its tag with the tag of the version below it, or for the oldest version to its own tag or a comparison with an earlier one, and the unreleased heading, `## [Unreleased]`, to the comparison of the newest version's tag with `HEAD`.
# Tags are spelled `vX.Y.Z`, as TagBot spells them.
function check_links(settings::Settings, text, parsed)
    url = repository_url(settings)
    url === nothing && (failure("Changelog", "The repository's URL is unknown, so the links of CHANGELOG.md can't be checked; set `GITHUB_REPOSITORY`, such as `owner/Package.jl`."); return)
    definitions = links(text)
    released = versions(parsed)
    for (index, version) in enumerate(released)
        expected = index == length(released) ? "$(url)/releases/tag/v$(version)" : "$(url)/compare/v$(released[index + 1])...v$(version)"
        actual = get(definitions, string(version), get(definitions, "v$(version)", nothing))
        if actual === nothing
            failure("Changelog", "CHANGELOG.md has no link for $(version); add `[$(version)]: $(expected)` at its end.")
        elseif actual != expected && !(index == length(released) && from_earlier(actual, url, version))
            failure("Changelog", "The link for $(version) in CHANGELOG.md is $(actual), but it should be $(expected).")
        end
    end
    if unreleased_index(parsed) !== nothing
        occursin(r"^##\s+\[Unreleased\]\s*$"im, text) || failure("Changelog", "Head the unreleased section of CHANGELOG.md `## [Unreleased]`, so that it links to the unreleased changes.")
        if !isempty(released)
            expected = "$(url)/compare/v$(first(released))...HEAD"
            actual = get(definitions, "unreleased", nothing)
            if actual === nothing
                failure("Changelog", "CHANGELOG.md has no link for the unreleased changes; add `[Unreleased]: $(expected)` at its end.")
            elseif actual != expected
                failure("Changelog", "The link for the unreleased changes in CHANGELOG.md is $(actual), but it should be $(expected).")
            end
        end
    end
    return
end

function check(::ChangelogCheck, settings::Settings)
    version = head_version(settings)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> is_version(section, version), parsed)
    if index === nothing
        failure("Changelog", "CHANGELOG.md has no section for $(version); move the unreleased entries under a heading `## [$(version)]`.")
        return
    end
    isempty(entries(parsed[index])) && failure("Changelog", "The section of $(version) in CHANGELOG.md has no entries.")

    unreleased = unreleased_index(parsed)
    if unreleased !== nothing
        isempty(entries(parsed[unreleased])) || failure("Changelog", "The unreleased section of CHANGELOG.md still has entries; a release moves them into the section of $(version).")
        unreleased < index || failure("Changelog", "The unreleased section of CHANGELOG.md must come before the section of $(version).")
    end
    # The newest version comes first: no version's section comes before the new one's, and none after it is newer.
    for earlier in versions(parsed[1:(index - 1)])
        failure("Changelog", "The section of $(version) in CHANGELOG.md must come before that of $(earlier).")
    end
    for later in versions(parsed[(index + 1):end])
        later >= version && failure("Changelog", "The section of $(later) in CHANGELOG.md must come after that of $(version), which is newer.")
    end

    release = last_release(settings)
    released = release === nothing ? nothing : file_at(settings, release.ref, "CHANGELOG.md")
    if released !== nothing && any(section -> is_version(section, version), sections(released))
        failure("Changelog", "The section of $(version) is already in the changelog of $(label(release)); a release adds a new section.")
    end
    settings.check_links && check_links(settings, text, parsed)
    println("Changelog: the section of $(version) has $(length(entries(parsed[index]))) entries.")
    return
end

# Changelog entry
# ---------------

# Why a pull request from `branch` needs no new changelog entry, or `nothing` where it needs one.
exemption(::Settings, ::Branch) = nothing
exemption(::Settings, ::ReleaseOrHotfix) = "The pull request is a release"
exemption(settings::Settings{Gitflow}, branch::Branch{BackMerge}) = "$(branch.name) brings $(settings.main_branch) back into $(settings.develop_branch)"
# Under gitflow, a release or hotfix branch doesn't merge into develop, which the source branch check reports.
exemption(::Settings{Gitflow}, ::ReleaseOrHotfix) = nothing

# A pull request of unreleased work adds an entry to the unreleased section of the changelog, or rewords one, unless it has the label `skip_label`.
function check(::EntryCheck, settings::Settings)
    reason = exemption(settings, head_branch(settings))
    reason === nothing && settings.skip_changelog && (reason = "The pull request has the `$(settings.skip_label)` label")
    if reason !== nothing
        note("$(reason), so it needs no new changelog entry.")
        return
    end
    text = head_changelog(settings)
    text === nothing && return
    base = base_file(settings, "CHANGELOG.md")
    known = Set(base === nothing ? String[] : unreleased_entries(sections(base)))
    added = filter(entry -> !(entry in known), unreleased_entries(sections(text)))
    if isempty(added)
        failure("Changelog entry", "CHANGELOG.md has no new entry under `## [Unreleased]`; describe the change there, or, for a change that users won't notice, a maintainer adds the `$(settings.skip_label)` label.")
    else
        println("Changelog entry: $(length(added)) new $(length(added) == 1 ? "entry" : "entries") under `## [Unreleased]`.")
    end
    return
end

# Release
# -------

# Whether the pull request is a release, written to the step's outputs as `release=true` or `release=false`, for the trunk workflow to choose its checks.
function check(::ReleaseCheck, settings::Settings)
    release = is_release(settings)
    println(release ? "The pull request changes the version to $(head_version(settings)), so it's a release." : "The pull request keeps the version, so it isn't a release.")
    path = get(ENV, "GITHUB_OUTPUT", "")
    isempty(path) || open(io -> println(io, "release=$(release)"), path, "a")
    return
end

# Breaking changes
# ----------------

# The Julia code that lists the public API of the package `name` to `output`: its public names and those of its public submodules, the methods of its public functions, with their keywords, and the supertypes, parameters and fields of its public types.
# With `against`, the listing of another version, it instead writes each entry of that listing that this version no longer provides.
const SURFACE = raw"""
using Pkg
# A manifest left over from another version would lack this version's dependencies, so they're resolved afresh.
Pkg.resolve(; io = devnull)
Pkg.instantiate(; io = devnull)
const NAME = Symbol(ARGS[1])
@eval import $(NAME)
const PACKAGE = getfield(Main, NAME)

# Whether a method belongs to the package, rather than to a package whose function it extends.
owned(method) = (m = method.module; while m !== parentmodule(m) && m !== PACKAGE; m = parentmodule(m); end; m === PACKAGE)
signature(method) = join(string.(Base.unwrap_unionall(method.sig).parameters[2:end]), ", ")

function listing!(lines, mod, prefix)
    for name in sort(names(mod))
        (name === nameof(mod) || !isdefined(mod, name)) && continue
        value = getfield(mod, name)
        label = "$(prefix).$(name)"
        if value isa Module
            parentmodule(value) === mod && value !== mod && (push!(lines, "module\t$(label)"); listing!(lines, value, label))
        elseif value isa Function
            push!(lines, "function\t$(label)")
            for method in methods(value)
                owned(method) || continue
                push!(lines, "method\t$(label)\t$(signature(method))")
                for keyword in Base.kwarg_decl(method)
                    push!(lines, "keyword\t$(label)\t$(signature(method))\t$(keyword)")
                end
            end
        elseif value isa Type
            type = Base.unwrap_unionall(value)
            push!(lines, "type\t$(label)")
            type isa DataType || continue
            push!(lines, "supertype\t$(label)\t$(supertype(type))")
            push!(lines, "parameters\t$(label)\t$(length(type.parameters))")
            isabstracttype(type) || foreach(field -> push!(lines, "field\t$(label)\t$(field)"), fieldnames(type))
        else
            push!(lines, "constant\t$(label)")
        end
    end
    return lines
end

resolve(label) = foldl((value, part) -> getfield(value, Symbol(part)), split(label, '.')[2:end]; init = PACKAGE)

# Whether the method of `label` with argument types `text` still applies, with `keyword` if given.
function provided(label, text, keyword = nothing)
    f = try resolve(label) catch; return false end
    types = try Core.eval(Main, Meta.parse("Tuple{$(text)}")) catch; nothing end
    if types === nothing
        # Types that this version can't express, such as those with type variables, are compared as text.
        return any(method -> signature(method) == text, methods(f))
    end
    keyword === nothing && return hasmethod(f, types)
    # A method that takes any keywords, `options...`, takes every keyword.
    name = endswith(keyword, "...") ? :__any_keyword_of_the_checks__ : Symbol(keyword)
    return hasmethod(f, types, (name,))
end

function missing_entries(lines)
    current = Set(listing!(String[], PACKAGE, string(NAME)))
    removed = String[]
    for line in lines
        line in current && continue
        fields = split(line, '\t')
        kind = fields[1]
        if kind == "method"
            provided(fields[2], fields[3]) || push!(removed, line)
        elseif kind == "keyword"
            provided(fields[2], fields[3], fields[4]) || push!(removed, line)
        else
            push!(removed, line)
        end
    end
    return removed
end

if length(ARGS) == 2
    foreach(println, listing!(String[], PACKAGE, string(NAME)))
else
    foreach(println, missing_entries(readlines(ARGS[3])))
end
"""

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

# Run `code` with `arguments` in a fresh Julia process in the project `directory`, and return whether it succeeded and what it wrote.
function julia_in(directory, code, arguments...)
    output = IOBuffer()
    errors = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(directory) -e $(code) $(arguments)`
    process = run(pipeline(ignorestatus(Cmd(command; dir = directory)); stdout = output, stderr = errors))
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
    ok, output, errors = julia_in(directory, SURFACE, name, "list")
    ok || (failure("Breaking changes", "The public API of $(label(release)) couldn't be listed:\n$(last(errors, 2000))"); return String[])
    write(listing, output)
    ok, output, errors = julia_in(settings.root, SURFACE, name, "against", listing)
    ok || (failure("Breaking changes", "The public API of $(head_label(settings)) couldn't be compared:\n$(last(errors, 2000))"); return String[])
    return filter(!isempty, split(output, '\n'))
end

# Run the last release's tests against the head: a copy of the head with the release's `test/` directory.
function old_tests(settings::Settings, release_directory)
    directory = mktempdir()
    # Without the manifest, which Pkg resolves afresh for the head's dependencies.
    for entry in readdir(settings.root)
        entry in (".git", "test") || startswith(entry, "Manifest") || cp(joinpath(settings.root, entry), joinpath(directory, entry))
    end
    isdir(joinpath(release_directory, "test")) || return true, "the base has no tests"
    cp(joinpath(release_directory, "test"), joinpath(directory, "test"))
    # A release from before the tests were a project of the workspace keeps the head's test project, which the head's workspace names.
    head_test_project = joinpath(settings.root, "test", "Project.toml")
    test_project = joinpath(directory, "test", "Project.toml")
    isfile(test_project) || !isfile(head_test_project) || cp(head_test_project, test_project)
    ok, output, errors = julia_in(directory, "using Pkg; Pkg.test()")
    failing = filter(line -> occursin(r"Test Failed at|Error During Test at|Got exception outside of a @test", line), split(output * errors, '\n'))
    # A failure without failing tests, such as one of Pkg, is reported by the end of its output.
    ok || !isempty(failing) || push!(failing, last(errors, 3000))
    return ok, join(failing, "\n")
end

# A breaking change takes a breaking version, which a hotfix can't.
function check_breaking_version(::Branch, head, base)
    head in breaking_steps(base) || failure("Breaking changes", "The changes are breaking for users of $(base), so the version must be $(join(breaking_steps(base), " or ")), not $(head); see the job summary.")
    return
end

check_breaking_version(::Branch{Hotfix}, head, base) = failure("Breaking changes", "A hotfix may not make breaking changes to $(base); release the change from a release branch with a breaking version.")

function check(::BreakingCheck, settings::Settings)
    release = last_release(settings)
    if release === nothing
        note("There's no earlier release, so there's nothing to break.")
        return
    end
    head = head_version(settings)
    name = head_project(settings)["name"]
    narrowed, widened = compat_changes(TOML.parse(file_at(settings, release.ref, "Project.toml")), head_project(settings))
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
    summary(join(report, '\n'))
    println(join(report, '\n'))
    isempty(removed) && tests_pass && isempty(narrowed) && return

    check_breaking_version(head_branch(settings), head, release.version)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> is_version(section, head), parsed)
    if index === nothing || subsection_entries(parsed[index], "Breaking") == 0
        failure("Breaking changes", "The changes are breaking for users of $(release.version), so the section of $(head) in CHANGELOG.md needs a `### Breaking` subsection that describes them; see the job summary.")
    end
    return
end

# Main
# ----

if length(ARGS) != 1 || !haskey(CHECKS, ARGS[1]) || !haskey(MODELS, input(ENV, "MODEL", "gitflow"))
    println(stderr, "usage: MODEL=$(join(sort(collect(keys(MODELS))), '|')) julia checks.jl $(join(sort(collect(keys(CHECKS))), '|'))")
    exit(2)
end
check(CHECKS[ARGS[1]], Settings())
isempty(ERRORS) || exit(1)
