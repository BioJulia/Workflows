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
function check_step(settings::Settings, ::Branch, head, base)
    head in single_steps(base) || not_a_step(settings, head, base)
    return
end

function check_step(settings::Settings, ::Branch{Hotfix}, head, base)
    head in single_steps(base) || return not_a_step(settings, head, base)
    head == next_patch(base) || failure(settings, "Version", "A hotfix releases the next patch, $(next_patch(base)), not $(head).")
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

    if base === nothing
        note("$(settings.base_ref) has no version, so $(head) is the first release.")
    else
        # Finding the last release checks that its tag agrees with the registry.
        last_release(settings)
        check_step(settings, branch, head, base)
    end
    return
end
