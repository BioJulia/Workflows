# Versions
# --------

next_patch(v) = VersionNumber(v.major, v.minor, v.patch + 1)
next_minor(v) = VersionNumber(v.major, v.minor + 1, 0)
next_major(v) = VersionNumber(v.major + 1, 0, 0)

# The steps that a version may take from `base`.
single_steps(base) = (next_patch(base), next_minor(base), next_major(base))

# The steps that a breaking change may take from `base`: the next major version, or below 1.0 the next minor version, which Julia's compat treats as breaking.
breaking_steps(base) = base.major == 0 ? (next_minor(base), next_major(base)) : (next_major(base),)

# The steps that new features may take from `base`: the next minor or major version, or below 1.0 any single step, since Julia's compat treats the next minor version as breaking there, and takes the next patch as a compatible release.
feature_steps(base) = base.major == 0 ? single_steps(base) : (next_minor(base), next_major(base))

# A release or hotfix branch's name gives its version; trunk names no versions.
check_name(settings::Settings, branch::Branch, head) = unnamed(settings, branch, head)

function check_name(settings::Settings, branch::ReleaseOrHotfix, head)
    if branch.version === nothing
        unnamed(settings, branch, head)
    elseif branch.version != head
        failure(settings, "Version", "The branch $(branch.name) names $(branch.version), but Project.toml has $(head); they must agree.")
    end
    return
end

check_name(::Settings{Trunk}, ::Branch, head) = nothing
check_name(::Settings{Trunk}, ::ReleaseOrHotfix, head) = nothing

unnamed(settings::Settings, branch::Branch, head) = failure(settings, "Version", "The branch $(branch.name) doesn't name a version; name it $(kind_name(branch))/v$(head), after the version in Project.toml.")

# A version takes a single step up from the last release's, and a hotfix the next patch.
function check_step(settings::Settings, ::Branch, head, release::LastRelease)
    head in single_steps(release.version) || not_a_step(settings, head, release.version)
    return
end

function check_step(settings::Settings, ::Branch{Hotfix}, head, release::LastRelease)
    base = release.version
    head in single_steps(base) || return not_a_step(settings, head, base)
    head == next_patch(base) || failure(settings, "Version", "A hotfix releases the next patch, $(next_patch(base)), not $(head).")
    return
end

# The number of entries under `### Added` in the section of `version` of the head's changelog; none where there's no changelog or no such section, which the changelog checks report.
function added_entries(settings::Settings, version)
    path = joinpath(package_directory(settings), "CHANGELOG.md")
    isfile(path) || return 0
    parsed = sections(read(path, String))
    index = findfirst(section -> is_version(section, version), parsed)
    return index === nothing ? 0 : subsection_entries(parsed[index], "Added")
end

# New features take a feature step, which a hotfix can't; a version that isn't a single step fails `check_step` already.
function check_features(settings::Settings, ::Branch, head, release::LastRelease)
    base = release.version
    head in single_steps(base) || return
    head in feature_steps(base) || added_entries(settings, head) == 0 || failure(settings, "Version", "The section of $(head) in $(package_path(settings, "CHANGELOG.md")) has `### Added` entries, whose new features take the next minor version, $(next_minor(base)), or a major one, not the patch $(head).")
    return
end

function check_features(settings::Settings, branch::Branch{Hotfix}, head, ::LastRelease)
    added_entries(settings, head) == 0 || failure(settings, "Version", "The hotfix $(branch.name) has `### Added` entries in the section of $(head) in $(package_path(settings, "CHANGELOG.md")), but a hotfix may not add features; release them from a release branch.")
    return
end

check_features(::Settings, ::Branch, head, ::InitialRelease) = nothing

# An initial release takes a standard first version, as General accepts for a new package: 0.0.1, 0.1.0, or a major version, X.0.0.
is_first_version(version) = version == v"0.0.1" || version == v"0.1.0" || (version.major >= 1 && version.minor == 0 && version.patch == 0)

function check_step(settings::Settings, ::Branch, head, ::InitialRelease)
    note("$(settings.base_ref) has no version, so $(head) is the initial release.")
    is_first_version(head) || failure(settings, "Version", "The initial release takes a standard first version, 0.0.1, 0.1.0 or X.0.0, as General accepts for a new package, not $(head).")
    check_nothing_released(settings, head)
    return
end

# There's nothing to fix before the first release, which comes from a release branch.
check_step(settings::Settings, branch::Branch{Hotfix}, head, ::InitialRelease) = failure(settings, "Version", "The hotfix $(branch.name) can't be the initial release, since there's no release to fix; release the package from a release branch.")

# An initial release follows no earlier one: the registry records no version of the package, and the repository has no version tag but the release's own, at its commit, as OneFlow tags it before it merges.
# Otherwise the main branch's missing version is a mistake, rather than a first release.
function check_nothing_released(settings::Settings, head)
    released = registered_versions(settings)
    isempty(released) || failure(settings, "Version", "$(registry_name(settings)) already records $(join(released, ", ")) of the package, so $(head) isn't its initial release; set the version of $(settings.base_ref) to its last release, $(last(released)).")
    head_tree = package_tree(settings, settings.head_sha)
    tags = filter(split(something(git(settings, "tag", "--list", "v*"), ""), '\n')) do tag
        occursin(r"^v\d+\.\d+\.\d+$", tag) && !(tag == "v$(head)" && package_tree(settings, tag) == head_tree)
    end
    isempty(tags) || failure(settings, "Version", "The repository already has the version tags $(join(tags, ", ")), so $(head) isn't its initial release; set the version of $(settings.base_ref) to its last release.")
    return
end

not_a_step(settings::Settings, head, base) = failure(settings, "Version", "The version $(head) isn't a single step up from $(base); the next is $(join(single_steps(base), ", ", " or ")).")

function check(::VersionCheck, settings::Settings)
    head = head_version(settings)
    base = base_version(settings)
    println("Version: $(head) on $(head_label(settings)); $(base === nothing ? "no version" : base) on $(settings.base_ref).")
    isempty(head.prerelease) && isempty(head.build) || failure(settings, "Version", "The version $(head) has a prerelease or build suffix; a release has neither.")
    branch = head_branch(settings)
    check_name(settings, branch, head)

    # A release may be registered and tagged before it merges, as OneFlow does, but only at this commit.
    head_tree = package_tree(settings, settings.head_sha)
    registered = registered_tree(settings, head)
    registered === nothing || registered == head_tree || failure(settings, "Version", "$(registry_name(settings)) already records $(head), with another tree; a release takes a new version.")
    tag = "v$(head)"
    has_tag(settings, tag) && package_tree(settings, tag) != head_tree && failure(settings, "Version", "The version $(head) is already tagged, $(tag), at another commit; a release takes a new version.")

    # Finding the last release checks that its tag agrees with the registry.
    release = last_release(settings)
    check_step(settings, branch, head, release)
    check_features(settings, branch, head, release)
    return
end
