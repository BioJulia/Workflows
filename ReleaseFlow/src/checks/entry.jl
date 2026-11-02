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
    base = base_file(settings, package_path(settings, "CHANGELOG.md"))
    known = Set(base === nothing ? String[] : unreleased_entries(sections(base)))
    added = filter(entry -> !(entry in known), unreleased_entries(sections(text)))
    if isempty(added)
        failure(settings, "Changelog entry", "$(package_path(settings, "CHANGELOG.md")) has no new entry under `## [Unreleased]`; describe the change there, or, for a change that users won't notice, a maintainer adds the `$(settings.skip_label)` label.")
    else
        println("Changelog entry: $(length(added)) new $(length(added) == 1 ? "entry" : "entries") under `## [Unreleased]`.")
        check_api_entries(settings, sections(text), added)
    end
    return
end

# Whether the pull request changes what the package's public API comes from: its source or its project, whose dependencies it may reexport.
# A package that the base doesn't have yet has no API to compare with.
function changes_api(settings::Settings)
    base_file(settings, package_path(settings, "Project.toml")) === nothing && return false
    changed = git(settings, "diff", "--name-only", settings.base_ref, "--", package_path(settings, "src"), package_path(settings, "Project.toml"))
    return changed === nothing || !isempty(changed)
end

# A change to the public API takes a new entry of its kind under `## [Unreleased]`: one that removes or changes a name, method, keyword or field, an entry under `### Breaking`, and one that adds any, an entry under `### Added`.
# A change in behaviour with the same API, which the API can't show, is left to the breaking check of the release.
function check_api_entries(settings::Settings, parsed, added)
    changes_api(settings) || return
    name = head_project(settings)["name"]
    head = (package_directory(settings), head_label(settings))
    removed, provided = with_checkout(settings, settings.base_ref) do directory
        base = (package_directory(settings, directory), settings.base_ref)
        api_missing(settings, "Changelog entry", name, base, head), api_missing(settings, "Changelog entry", name, head, base)
    end
    isempty(removed) && isempty(provided) && return
    report = ["## Public API from $(settings.base_ref) to $(head_label(settings))", ""]
    isempty(removed) || push!(report, "The public API of $(settings.base_ref) that $(head_label(settings)) no longer provides:", "", "```", replace.(removed, '\t' => ' ')..., "```", "")
    isempty(provided) || push!(report, "The public API that $(head_label(settings)) adds:", "", "```", replace.(provided, '\t' => ' ')..., "```", "")
    summary(settings, join(report, '\n'))
    println(join(report, '\n'))
    unreleased = parsed[unreleased_index(parsed)]
    changelog = package_path(settings, "CHANGELOG.md")
    isempty(removed) || any(in(added), subsection(unreleased, "Breaking")) || failure(settings, "Changelog entry", "$(head_label(settings)) removes or changes public API of $(settings.base_ref), so $(changelog) needs a new entry under `### Breaking` in `## [Unreleased]` that describes it; see the job summary.")
    isempty(provided) || any(in(added), subsection(unreleased, "Added")) || failure(settings, "Changelog entry", "$(head_label(settings)) adds public API, so $(changelog) needs a new entry under `### Added` in `## [Unreleased]` that describes it; see the job summary.")
    return
end
