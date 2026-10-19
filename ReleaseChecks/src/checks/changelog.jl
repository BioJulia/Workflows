# Changelog
# ---------

function check(::ChangelogCheck, settings::Settings)
    version = head_version(settings)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = findfirst(section -> is_version(section, version), parsed)
    if index === nothing
        failure(settings, "Changelog", "CHANGELOG.md has no section for $(version); move the unreleased entries under a heading `## [$(version)]`.")
        return
    end
    isempty(entries(parsed[index])) && failure(settings, "Changelog", "The section of $(version) in CHANGELOG.md has no entries.")

    unreleased = unreleased_index(parsed)
    if unreleased !== nothing
        isempty(entries(parsed[unreleased])) || failure(settings, "Changelog", "The unreleased section of CHANGELOG.md still has entries; a release moves them into the section of $(version).")
        unreleased < index || failure(settings, "Changelog", "The unreleased section of CHANGELOG.md must come before the section of $(version).")
    end
    # The newest version comes first: no version's section comes before the new one's, and none after it is newer.
    for earlier in versions(parsed[1:(index - 1)])
        failure(settings, "Changelog", "The section of $(version) in CHANGELOG.md must come before that of $(earlier).")
    end
    for later in versions(parsed[(index + 1):end])
        later >= version && failure(settings, "Changelog", "The section of $(later) in CHANGELOG.md must come after that of $(version), which is newer.")
    end

    release = last_release(settings)
    check_history(settings, parsed, version, release)
    settings.check_links && check_links(settings, text, parsed, release)
    println("Changelog: the section of $(version) has $(length(entries(parsed[index]))) entries.")
    return
end

# A release's section is new: the last release's changelog hasn't one.
function check_history(settings::Settings, parsed, version, release::LastRelease)
    released = file_at(settings, release.ref, package_path(settings, "CHANGELOG.md"))
    if released !== nothing && any(section -> is_version(section, version), sections(released))
        failure(settings, "Changelog", "The section of $(version) is already in the changelog of $(label(release)); a release adds a new section.")
    end
    return
end

# An initial release's changelog describes no earlier release.
function check_history(settings::Settings, parsed, version, ::InitialRelease)
    for earlier in filter(!=(version), versions(parsed))
        failure(settings, "Changelog", "CHANGELOG.md has a section for $(earlier), but $(version) is the initial release; describe its changes in its own section.")
    end
    return
end
