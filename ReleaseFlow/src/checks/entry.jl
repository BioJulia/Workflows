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
        failure(settings, "Changelog entry", "CHANGELOG.md has no new entry under `## [Unreleased]`; describe the change there, or, for a change that users won't notice, a maintainer adds the `$(settings.skip_label)` label.")
    else
        println("Changelog entry: $(length(added)) new $(length(added) == 1 ? "entry" : "entries") under `## [Unreleased]`.")
    end
    return
end
