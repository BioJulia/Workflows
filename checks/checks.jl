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
# Run from the root of the package's repository with `julia checks.jl source|version|changelog|breaking|entry|is-release`.
# Inputs are environment variables, so that branch names never reach a shell, and an empty one counts as missing:
# - `RELEASEFLOW_MODEL`, `gitflow`, `oneflow` or `trunk`, `gitflow` unless given;
# - `RELEASEFLOW_MAIN_BRANCH` and `RELEASEFLOW_DEVELOP_BRANCH`, `main` and `develop` unless given;
# - `RELEASEFLOW_HEAD_REF`, the source branch, such as `release/v0.2.0`;
# - `RELEASEFLOW_HEAD_SHA`, the pull request's head commit, `HEAD` unless given; in GitHub Actions, `HEAD` is the merge commit, which already contains the base;
# - `RELEASEFLOW_BASE_BRANCH`, the name of the branch that the pull request merges into, for `source`;
# - `RELEASEFLOW_BASE_REF`, what the pull request merges into, `origin/<RELEASEFLOW_MAIN_BRANCH>` unless given;
# - `RELEASEFLOW_DEVELOP_REF`, `origin/<RELEASEFLOW_DEVELOP_BRANCH>` unless given;
# - `RELEASEFLOW_SKIP_CHANGELOG`, `true` where the pull request has the label `RELEASEFLOW_SKIP_LABEL`, `skip changelog` unless given, for `entry`;
# - `RELEASEFLOW_CHECK_LINKS`, whether the changelog's comparison links are checked, `true` unless given;
# - `RELEASEFLOW_REGISTRY`, the name of an installed registry, or the path of a registry's directory, `General` unless given.
# The base's files are read with `git show`, and a base without them, as before the first release, has no version and no changelog.

using Pkg
using TOML
using UUIDs

const ROOT = pwd()

# An input, or `default` where it's missing or empty, as GitHub Actions passes an input that it has no value for.
input(name, default) = (value = get(ENV, name, ""); isempty(value) ? default : value)

const RELEASEFLOW_MODEL = input("RELEASEFLOW_MODEL", "gitflow")
const RELEASEFLOW_MAIN_BRANCH = input("RELEASEFLOW_MAIN_BRANCH", "master")
const RELEASEFLOW_DEVELOP_BRANCH = input("RELEASEFLOW_DEVELOP_BRANCH", "develop")
const RELEASEFLOW_HEAD_REF = input("RELEASEFLOW_HEAD_REF", "")
const RELEASEFLOW_HEAD_SHA = input("RELEASEFLOW_HEAD_SHA", "HEAD")
const RELEASEFLOW_BASE_BRANCH = input("RELEASEFLOW_BASE_BRANCH", "")
const RELEASEFLOW_BASE_REF = input("RELEASEFLOW_BASE_REF", "origin/$(RELEASEFLOW_MAIN_BRANCH)")
const RELEASEFLOW_DEVELOP_REF = input("RELEASEFLOW_DEVELOP_REF", "origin/$(RELEASEFLOW_DEVELOP_BRANCH)")
const RELEASEFLOW_SKIP_LABEL = input("RELEASEFLOW_SKIP_LABEL", "skip changelog")
const RELEASEFLOW_SKIP_CHANGELOG = lowercase(input("RELEASEFLOW_SKIP_CHANGELOG", "false")) == "true"
const RELEASEFLOW_CHECK_LINKS = lowercase(input("RELEASEFLOW_CHECK_LINKS", "true")) == "true"
const RELEASEFLOW_REGISTRY = input("RELEASEFLOW_REGISTRY", "General")

const MODELS = Dict("gitflow" => "Gitflow", "oneflow" => "OneFlow", "trunk" => "Trunk")

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
function git(arguments...)
    output = IOBuffer()
    process = run(pipeline(ignorestatus(`git -C $(ROOT) $(arguments)`); stdout = output, stderr = devnull))
    return success(process) ? chomp(String(take!(output))) : nothing
end

# The contents of `path` at `ref`, or `nothing` where `ref` has no such file, or doesn't exist.
file_at(ref, path) = git("show", "$(ref):$(path)")

base_file(path) = file_at(RELEASEFLOW_BASE_REF, path)

has_ref(ref) = git("rev-parse", "--verify", "--quiet", "$(ref)^{commit}") !== nothing

has_base() = has_ref(RELEASEFLOW_BASE_REF)

# The commit where `a` and `b` last met, or `nothing` where they never did.
merge_base(a, b) = git("merge-base", a, b)

is_ancestor(a, b) = git("merge-base", "--is-ancestor", a, b) !== nothing

tree_of(ref) = git("rev-parse", "$(ref)^{tree}")

# The first commit of any branch or tag whose tree is `tree`, or `nothing`.
function commit_with_tree(tree)
    for line in split(something(git("log", "--all", "--format=%H %T"), ""), '\n')
        commit, commit_tree = (split(line, ' ')..., "", "")
        commit_tree == tree && return String(commit)
    end
    return nothing
end

# The package
# -----------

head_project() = TOML.parsefile(joinpath(ROOT, "Project.toml"))

head_version() = VersionNumber(head_project()["version"])

function base_version()
    project = base_file("Project.toml")
    project === nothing && return nothing
    version = get(TOML.parse(project), "version", nothing)
    return version === nothing ? nothing : VersionNumber(version)
end

# The registry
# ------------

const REGISTRY_INSTANCE = Ref{Any}(missing)

# The registry `RELEASEFLOW_REGISTRY`, updated, or `nothing` where it can't be had; a path is read as it is, as the tests do.
function registry()
    REGISTRY_INSTANCE[] === missing || return REGISTRY_INSTANCE[]
    REGISTRY_INSTANCE[] = try
        if isdir(RELEASEFLOW_REGISTRY)
            Pkg.Registry.RegistryInstance(RELEASEFLOW_REGISTRY)
        else
            installed = any(instance -> instance.name == RELEASEFLOW_REGISTRY, Pkg.Registry.reachable_registries())
            installed ? Pkg.Registry.update(RELEASEFLOW_REGISTRY; io = devnull) : Pkg.Registry.add(RELEASEFLOW_REGISTRY; io = devnull)
            only(filter(instance -> instance.name == RELEASEFLOW_REGISTRY, Pkg.Registry.reachable_registries()))
        end
    catch exception
        note("The registry $(RELEASEFLOW_REGISTRY) couldn't be read, so releases are found by their tags: $(sprint(showerror, exception))")
        nothing
    end
    return REGISTRY_INSTANCE[]
end

# The registry's name, for messages.
registry_name() = (instance = registry(); instance === nothing ? RELEASEFLOW_REGISTRY : instance.name)

# The tree of the package's `version` that the registry records, or `nothing` where it records none.
function registered_tree(version)
    instance = registry()
    instance === nothing && return nothing
    entry = get(instance, UUID(head_project()["uuid"]), nothing)
    entry === nothing && return nothing
    # Pkg's registry API changed in Julia 1.13, which passes the registry with the entry.
    info = applicable(Pkg.Registry.registry_info, instance, entry) ? Pkg.Registry.registry_info(instance, entry) : Pkg.Registry.registry_info(entry)
    version_info = get(info.version_info, version, nothing)
    return version_info === nothing ? nothing : string(version_info.git_tree_sha1)
end

# The last release
# ----------------

const RELEASE_BASE = Ref{Any}(missing)

# The last release, as its version and the commit to compare with: the main branch's version, at the commit whose tree the registry records for it, which must agree with its tag; else at its tag, or at the main branch, for a package not yet registered.
# Gitflow compares with the main branch, which holds only releases.
function release_base()
    RELEASE_BASE[] === missing || return RELEASE_BASE[]
    RELEASE_BASE[] = has_base() ? find_release_base() : nothing
    return RELEASE_BASE[]
end

function find_release_base()
    version = base_version()
    version === nothing && return nothing
    RELEASEFLOW_MODEL == "gitflow" && return (; version, ref = RELEASEFLOW_BASE_REF, label = RELEASEFLOW_BASE_REF)
    tag = "v$(version)"
    tagged = has_ref("refs/tags/$(tag)")
    tree = registered_tree(version)
    if tree !== nothing
        commit = commit_with_tree(tree)
        if commit === nothing
            failure("Release", "$(registry_name()) records the tree $(tree) for $(version), but no branch or tag has a commit with it; fetch the whole history, or tag the release.")
            return nothing
        end
        if tagged && tree_of(tag) != tree
            failure("Release", "The tag $(tag) isn't the release of $(version) that $(registry_name()) records: its tree is $(tree_of(tag)), but the registered tree is $(tree), of the commit $(commit); move the tag.")
        end
        println("The last release, $(version), is the commit $(first(commit, 7)), which $(registry_name()) records$(tagged ? " and $(tag) tags" : "").")
        return (; version, ref = commit, label = "the release $(version)")
    elseif tagged
        note("$(registry_name()) doesn't record $(version), so the last release is the tag $(tag).")
        return (; version, ref = tag, label = "the release $(version)")
    else
        note("$(registry_name()) doesn't record $(version), and there's no tag $(tag), so the last release is $(RELEASEFLOW_BASE_REF).")
        return (; version, ref = RELEASEFLOW_BASE_REF, label = RELEASEFLOW_BASE_REF)
    end
end

# Source branch
# -------------

release_or_hotfix(ref) = startswith(ref, "release/") || startswith(ref, "hotfix/")

# Whether `ref` brings the main branch back into develop, carrying released changes rather than new ones: the main branch itself, or a `back-merge/vX.Y.Z` branch at it, which the back-merge workflow opens.
back_merge(ref) = ref == RELEASEFLOW_MAIN_BRANCH || startswith(ref, "back-merge/")

# A hotfix branches from what's released, so the point where it last met the branch of unreleased work, `unreleased`, is already released; a release branches from that branch, so that point isn't released yet.
# The head commit is compared, not the merge commit that GitHub Actions checks out, and with this repository's branches, so a fork's own branches don't matter.
function check_origin(unreleased, unreleased_name, released, released_name)
    if !has_ref(unreleased)
        note("There's no $(unreleased), so where $(RELEASEFLOW_HEAD_REF) came from isn't checked.")
        return
    end
    fork = merge_base(RELEASEFLOW_HEAD_SHA, unreleased)
    is_released = fork === nothing || is_ancestor(fork, released)
    if startswith(RELEASEFLOW_HEAD_REF, "hotfix/")
        if is_released
            println("$(RELEASEFLOW_HEAD_REF) carries no unreleased commit of $(unreleased_name).")
        else
            commits = split(something(git("log", "--oneline", "-n", "5", "$(released)..$(fork)"), ""), '\n')
            failure(MODELS[RELEASEFLOW_MODEL], "The hotfix $(RELEASEFLOW_HEAD_REF) carries unreleased commits of $(unreleased_name), such as:\n$(join(commits, '\n'))\nBranch a hotfix from $(released_name).")
        end
    elseif is_released
        failure(MODELS[RELEASEFLOW_MODEL], "The release $(RELEASEFLOW_HEAD_REF) carries none of the unreleased commits of $(unreleased_name); branch a release from $(unreleased_name).")
    else
        println("$(RELEASEFLOW_HEAD_REF) carries the unreleased commits of $(unreleased_name).")
    end
    return
end

function check_source()
    if RELEASEFLOW_MODEL == "gitflow"
        # The main branch takes merges only from release and hotfix branches; develop takes them from any other branch, and release and hotfix branches reach it through the main branch.
        if RELEASEFLOW_BASE_BRANCH == RELEASEFLOW_MAIN_BRANCH
            if release_or_hotfix(RELEASEFLOW_HEAD_REF)
                println("$(RELEASEFLOW_MAIN_BRANCH) takes the merge of $(RELEASEFLOW_HEAD_REF), a release or hotfix branch.")
                check_origin(RELEASEFLOW_DEVELOP_REF, RELEASEFLOW_DEVELOP_BRANCH, RELEASEFLOW_BASE_REF, RELEASEFLOW_MAIN_BRANCH)
            else
                failure("Gitflow", "$(RELEASEFLOW_MAIN_BRANCH) takes merges only from release/* and hotfix/* branches, as gitflow does, not from $(RELEASEFLOW_HEAD_REF); merge features into $(RELEASEFLOW_DEVELOP_BRANCH).")
            end
        elseif RELEASEFLOW_BASE_BRANCH == RELEASEFLOW_DEVELOP_BRANCH
            if release_or_hotfix(RELEASEFLOW_HEAD_REF)
                failure("Gitflow", "$(RELEASEFLOW_DEVELOP_BRANCH) doesn't take merges from release/* and hotfix/* branches, such as $(RELEASEFLOW_HEAD_REF); merge it into $(RELEASEFLOW_MAIN_BRANCH), and then merge $(RELEASEFLOW_MAIN_BRANCH) into $(RELEASEFLOW_DEVELOP_BRANCH).")
            else
                println("$(RELEASEFLOW_DEVELOP_BRANCH) takes the merge of $(RELEASEFLOW_HEAD_REF).")
            end
        else
            note("The Gitflow checks don't cover pull requests into $(isempty(RELEASEFLOW_BASE_BRANCH) ? "an unnamed branch; set RELEASEFLOW_BASE_BRANCH" : RELEASEFLOW_BASE_BRANCH).")
        end
    elseif RELEASEFLOW_MODEL == "oneflow"
        # The main branch takes any branch; a hotfix branches from the last release's tag, and a release carries the main branch's work since then.
        if RELEASEFLOW_BASE_BRANCH != RELEASEFLOW_MAIN_BRANCH
            note("The OneFlow checks don't cover pull requests into $(isempty(RELEASEFLOW_BASE_BRANCH) ? "an unnamed branch; set RELEASEFLOW_BASE_BRANCH" : RELEASEFLOW_BASE_BRANCH).")
        elseif release_or_hotfix(RELEASEFLOW_HEAD_REF)
            base = release_base()
            if base === nothing || base.ref == RELEASEFLOW_BASE_REF
                note("There's no earlier release, so where $(RELEASEFLOW_HEAD_REF) came from isn't checked.")
            else
                println("$(RELEASEFLOW_MAIN_BRANCH) takes the merge of $(RELEASEFLOW_HEAD_REF), a release or hotfix branch.")
                check_origin(RELEASEFLOW_BASE_REF, RELEASEFLOW_MAIN_BRANCH, base.ref, "the release $(base.version), v$(base.version)")
            end
        else
            println("$(RELEASEFLOW_MAIN_BRANCH) takes the merge of $(RELEASEFLOW_HEAD_REF).")
        end
    else
        note("The trunk model has no rules about source branches.")
    end
    return
end

# Versions
# --------

# The kind of branch, `"release"` or `"hotfix"`, and the version that its name gives, or `nothing` where it gives none.
function branch_version(ref)
    m = match(r"^(release|hotfix)/v?(\d+\.\d+\.\d+\S*)$", ref)
    m === nothing && return (startswith(ref, "hotfix/") ? "hotfix" : "release", nothing)
    return (m[1], tryparse(VersionNumber, m[2]))
end

# The kind of the release, `"hotfix"` or `"release"`; the trunk model has only releases.
release_kind() = RELEASEFLOW_MODEL == "trunk" ? "release" : first(branch_version(RELEASEFLOW_HEAD_REF))

next_patch(v) = VersionNumber(v.major, v.minor, v.patch + 1)
next_minor(v) = VersionNumber(v.major, v.minor + 1, 0)
next_major(v) = VersionNumber(v.major + 1, 0, 0)

# The steps that a version may take from `base`: a breaking change takes the next major version, or below 1.0 the next minor version, which Julia's compat treats as breaking.
breaking_steps(base) = base.major == 0 ? (next_minor(base), next_major(base)) : (next_major(base),)

function check_version()
    head = head_version()
    base = base_version()
    println("Version: $(head) on $(isempty(RELEASEFLOW_HEAD_REF) ? RELEASEFLOW_HEAD_SHA : RELEASEFLOW_HEAD_REF); $(base === nothing ? "no version" : base) on $(RELEASEFLOW_BASE_REF).")
    isempty(head.prerelease) && isempty(head.build) || failure("Version", "The version $(head) has a prerelease or build suffix; a release has neither.")

    kind = release_kind()
    if RELEASEFLOW_MODEL != "trunk"
        _, named = branch_version(RELEASEFLOW_HEAD_REF)
        if named === nothing
            failure("Version", "The branch $(RELEASEFLOW_HEAD_REF) doesn't name a version; name it $(kind)/v$(head), after the version in Project.toml.")
        elseif named != head
            failure("Version", "The branch $(RELEASEFLOW_HEAD_REF) names $(named), but Project.toml has $(head); they must agree.")
        end
    end

    # A release may be registered and tagged before it merges, as OneFlow does, but only at this commit.
    head_tree = tree_of(RELEASEFLOW_HEAD_SHA)
    registered = registered_tree(head)
    registered === nothing || registered == head_tree || failure("Version", "$(registry_name()) already records $(head), with another tree; a release takes a new version.")
    tag = "v$(head)"
    has_ref("refs/tags/$(tag)") && tree_of(tag) != head_tree && failure("Version", "The version $(head) is already tagged, $(tag), at another commit; a release takes a new version.")

    if base === nothing
        note("$(RELEASEFLOW_BASE_REF) has no version, so $(head) is the first release.")
    else
        RELEASEFLOW_MODEL == "gitflow" || release_base()
        steps = (next_patch(base), next_minor(base), next_major(base))
        if !(head in steps)
            failure("Version", "The version $(head) isn't a single step up from $(base); the next is $(join(steps, ", ", " or ")).")
        elseif kind == "hotfix" && head != next_patch(base)
            failure("Version", "A hotfix releases the next patch, $(next_patch(base)), not $(head).")
        end
    end
    return
end

# Changelog
# ---------

const UNRELEASED = r"^##\s+(UNRELEASED|\[Unreleased\])\s*$"i
const RELEASED = r"^##\s+\[?v?(\d+\.\d+\.\d+[^\]\s]*)\]?"

# The sections of a changelog, in order: each heading's version, `:unreleased`, or `nothing`, and its lines.
function sections(text)
    result = Pair{Any, Vector{String}}[]
    for line in split(text, '\n')
        if startswith(line, "## ")
            m = match(RELEASED, line)
            key = occursin(UNRELEASED, line) ? :unreleased : m === nothing ? nothing : tryparse(VersionNumber, m[1])
            push!(result, key => String[])
        elseif !isempty(result)
            push!(last(result[end]), line)
        end
    end
    return result
end

# An entry is an item of a list, with any of Markdown's markers.
is_entry(line) = occursin(r"^[-*+]\s", line)

entries(lines) = count(is_entry, lines)

# The entries of the subsection `title`, such as `### Breaking`, in `lines`.
function subsection_entries(lines, title)
    inside = false
    found = 0
    for line in lines
        if startswith(line, "### ")
            inside = lowercase(strip(line[5:end])) == lowercase(title)
        elseif inside && is_entry(line)
            found += 1
        end
    end
    return found
end

function head_changelog()
    path = joinpath(ROOT, "CHANGELOG.md")
    isfile(path) || (failure("Changelog", "There's no CHANGELOG.md."); return nothing)
    return read(path, String)
end

# The URL of the repository on GitHub, from `GITHUB_REPOSITORY` in GitHub Actions, or from the `origin` remote locally; `nothing` where neither gives one.
function repository_url()
    repository = get(ENV, "GITHUB_REPOSITORY", "")
    if isempty(repository)
        remote = something(git("remote", "get-url", "origin"), "")
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
function check_links(text, parsed)
    url = repository_url()
    url === nothing && (failure("Changelog", "The repository's URL is unknown, so the links of CHANGELOG.md can't be checked; set `GITHUB_REPOSITORY`, such as `owner/Package.jl`."); return)
    definitions = links(text)
    versions = VersionNumber[key for (key, _) in parsed if key isa VersionNumber]
    for (index, version) in enumerate(versions)
        expected = index == length(versions) ? "$(url)/releases/tag/v$(version)" : "$(url)/compare/v$(versions[index + 1])...v$(version)"
        actual = get(definitions, string(version), get(definitions, "v$(version)", nothing))
        if actual === nothing
            failure("Changelog", "CHANGELOG.md has no link for $(version); add `[$(version)]: $(expected)` at its end.")
        elseif actual != expected && !(index == length(versions) && from_earlier(actual, url, version))
            failure("Changelog", "The link for $(version) in CHANGELOG.md is $(actual), but it should be $(expected).")
        end
    end
    if any(section -> first(section) === :unreleased, parsed)
        occursin(r"^##\s+\[Unreleased\]\s*$"im, text) || failure("Changelog", "Head the unreleased section of CHANGELOG.md `## [Unreleased]`, so that it links to the unreleased changes.")
        if !isempty(versions)
            expected = "$(url)/compare/v$(first(versions))...HEAD"
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

function check_changelog()
    version = head_version()
    text = head_changelog()
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> first(section) == version, parsed)
    if index === nothing
        failure("Changelog", "CHANGELOG.md has no section for $(version); move the unreleased entries under a heading `## [$(version)]`.")
        return
    end
    entries(last(parsed[index])) > 0 || failure("Changelog", "The section of $(version) in CHANGELOG.md has no entries.")

    unreleased = findfirst(section -> first(section) === :unreleased, parsed)
    if unreleased !== nothing
        entries(last(parsed[unreleased])) == 0 || failure("Changelog", "The unreleased section of CHANGELOG.md still has entries; a release moves them into the section of $(version).")
        unreleased < index || failure("Changelog", "The unreleased section of CHANGELOG.md must come before the section of $(version).")
    end
    # The newest version comes first: no version's section comes before the new one's, and none after it is newer.
    for (key, _) in parsed[1:(index - 1)]
        key isa VersionNumber && failure("Changelog", "The section of $(version) in CHANGELOG.md must come before that of $(key).")
    end
    for (key, _) in parsed[(index + 1):end]
        key isa VersionNumber && key >= version && failure("Changelog", "The section of $(key) in CHANGELOG.md must come after that of $(version), which is newer.")
    end

    base = release_base()
    base_changelog = base === nothing ? nothing : file_at(base.ref, "CHANGELOG.md")
    if base_changelog !== nothing && any(section -> first(section) == version, sections(base_changelog))
        failure("Changelog", "The section of $(version) is already in the changelog of $(base.label); a release adds a new section.")
    end
    RELEASEFLOW_CHECK_LINKS && check_links(text, parsed)
    println("Changelog: the section of $(version) has $(entries(last(parsed[index]))) entries.")
    return
end

# Changelog entry
# ---------------

# The entries of the unreleased section of a changelog's `parsed` sections.
function unreleased_entries(parsed)
    index = findfirst(section -> first(section) === :unreleased, parsed)
    return index === nothing ? String[] : filter(is_entry, last(parsed[index]))
end

# Whether the pull request is a release, which moves the changelog's entries rather than adding one.
function is_release()
    RELEASEFLOW_MODEL == "trunk" && return base_version() != head_version()
    return release_or_hotfix(RELEASEFLOW_HEAD_REF)
end

# A pull request of unreleased work adds an entry to the unreleased section of the changelog, or rewords one, unless it has the label `RELEASEFLOW_SKIP_LABEL`.
function check_entry()
    if RELEASEFLOW_MODEL == "gitflow" && back_merge(RELEASEFLOW_HEAD_REF)
        note("$(RELEASEFLOW_HEAD_REF) brings $(RELEASEFLOW_MAIN_BRANCH) back into $(RELEASEFLOW_DEVELOP_BRANCH), so it needs no new changelog entry.")
        return
    elseif RELEASEFLOW_MODEL != "gitflow" && is_release()
        note("The pull request is a release, so it needs no new changelog entry.")
        return
    elseif RELEASEFLOW_SKIP_CHANGELOG
        note("The pull request has the `$(RELEASEFLOW_SKIP_LABEL)` label, so it needs no new changelog entry.")
        return
    end
    text = head_changelog()
    text === nothing && return
    base = base_file("CHANGELOG.md")
    known = Set(base === nothing ? String[] : unreleased_entries(sections(base)))
    added = filter(entry -> !(entry in known), unreleased_entries(sections(text)))
    if isempty(added)
        failure("Changelog entry", "CHANGELOG.md has no new entry under `## [Unreleased]`; describe the change there, or, for a change that users won't notice, a maintainer adds the `$(RELEASEFLOW_SKIP_LABEL)` label.")
    else
        println("Changelog entry: $(length(added)) new $(length(added) == 1 ? "entry" : "entries") under `## [Unreleased]`.")
    end
    return
end

# Release
# -------

# Whether the pull request is a release of the trunk model, which changes the version, written to the step's outputs as `release=true` or `release=false`.
function check_release()
    release = is_release()
    println(release ? "The pull request changes the version to $(head_version()), so it's a release." : "The pull request keeps the version, so it isn't a release.")
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

# A copy of the repository at `ref`, in a temporary directory.
function checkout(ref)
    directory = mktempdir()
    run(pipeline(`git -C $(ROOT) worktree add --detach $(directory) $(ref)`; stdout = devnull, stderr = devnull))
    return directory
end

remove_checkout(directory) = run(pipeline(ignorestatus(`git -C $(ROOT) worktree remove --force $(directory)`); stdout = devnull, stderr = devnull))

# The entries of the base's public API that the head no longer provides.
function api_removals(base_directory, name, label)
    listing = joinpath(mktempdir(), "base.txt")
    ok, output, errors = julia_in(base_directory, SURFACE, name, "list")
    ok || (failure("Breaking changes", "The public API of $(label) couldn't be listed:\n$(last(errors, 2000))"); return String[])
    write(listing, output)
    ok, output, errors = julia_in(ROOT, SURFACE, name, "against", listing)
    ok || (failure("Breaking changes", "The public API of $(RELEASEFLOW_HEAD_REF) couldn't be compared:\n$(last(errors, 2000))"); return String[])
    return filter(!isempty, split(output, '\n'))
end

# Run the base's tests against the head: a copy of the head with the base's `test/` directory.
function old_tests(base_directory)
    directory = mktempdir()
    # Without the manifest, which Pkg resolves afresh for the head's dependencies.
    for entry in readdir(ROOT)
        entry in (".git", "test") || startswith(entry, "Manifest") || cp(joinpath(ROOT, entry), joinpath(directory, entry))
    end
    isdir(joinpath(base_directory, "test")) || return true, "the base has no tests"
    cp(joinpath(base_directory, "test"), joinpath(directory, "test"))
    # A base from before the tests were a project of the workspace keeps the head's test project, which the head's workspace names.
    head_test_project = joinpath(ROOT, "test", "Project.toml")
    test_project = joinpath(directory, "test", "Project.toml")
    isfile(test_project) || !isfile(head_test_project) || cp(head_test_project, test_project)
    ok, output, errors = julia_in(directory, "using Pkg; Pkg.test()")
    failing = filter(line -> occursin(r"Test Failed at|Error During Test at|Got exception outside of a @test", line), split(output * errors, '\n'))
    # A failure without failing tests, such as one of Pkg, is reported by the end of its output.
    ok || !isempty(failing) || push!(failing, last(errors, 3000))
    return ok, join(failing, "\n")
end

function check_breaking()
    base = release_base()
    if base === nothing
        note("There's no earlier release, so there's nothing to break.")
        return
    end
    head = head_version()
    head_label = isempty(RELEASEFLOW_HEAD_REF) ? RELEASEFLOW_HEAD_SHA : RELEASEFLOW_HEAD_REF
    name = head_project()["name"]
    base_project = file_at(base.ref, "Project.toml")
    narrowed, widened = compat_changes(TOML.parse(base_project), head_project())

    base_directory = checkout(base.ref)
    removed, (tests_pass, failing) = try
        api_removals(base_directory, name, base.label), old_tests(base_directory)
    finally
        remove_checkout(base_directory)
    end

    breaking = !isempty(removed) || !tests_pass || !isempty(narrowed)
    report = ["## Breaking changes from $(base.version) to $(head)", ""]
    if isempty(removed)
        push!(report, "The public API of $(base.label) is still provided.")
    else
        push!(report, "The public API of $(base.label) that $(head_label) no longer provides:", "", "```", replace.(removed, '\t' => ' ')..., "```")
    end
    push!(report, "")
    if isempty(narrowed)
        push!(report, "The compat bounds of $(base.label) are still admitted.")
    else
        push!(report, "The compat bounds that no longer admit every version that $(base.label) did:", "", "```", narrowed..., "```")
    end
    isempty(widened) || push!(report, "", "Other changes to compat bounds, which aren't breaking:", "", "```", widened..., "```")
    push!(report, "")
    push!(report, tests_pass ? "The tests of $(base.label) pass." : "The tests of $(base.label) fail against $(head_label):\n\n```\n$(failing)\n```")
    summary(join(report, '\n'))
    println(join(report, '\n'))
    breaking || return

    if release_kind() == "hotfix"
        failure("Breaking changes", "A hotfix may not make breaking changes to $(base.version); release the change from a release branch with a breaking version.")
    elseif !(head in breaking_steps(base.version))
        failure("Breaking changes", "The changes are breaking for users of $(base.version), so the version must be $(join(breaking_steps(base.version), " or ")), not $(head); see the job summary.")
    end
    text = head_changelog()
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> first(section) == head, parsed)
    if index === nothing || subsection_entries(last(parsed[index]), "Breaking") == 0
        failure("Breaking changes", "The changes are breaking for users of $(base.version), so the section of $(head) in CHANGELOG.md needs a `### Breaking` subsection that describes them; see the job summary.")
    end
    return
end

# Main
# ----

const CHECKS = Dict(
    "source" => check_source, "version" => check_version, "changelog" => check_changelog,
    "breaking" => check_breaking, "entry" => check_entry, "release" => check_release,
)

if length(ARGS) != 1 || !haskey(CHECKS, ARGS[1]) || !haskey(MODELS, RELEASEFLOW_MODEL)
    println(stderr, "usage: RELEASEFLOW_MODEL=$(join(sort(collect(keys(MODELS))), '|')) julia checks.jl $(join(sort(collect(keys(CHECKS))), '|'))")
    exit(2)
end
CHECKS[ARGS[1]]()
isempty(ERRORS) || exit(1)
