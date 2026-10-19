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
            failure(settings, "Release", "$(name) records the tree $(tree) for $(version), but no branch or tag has a commit with it; fetch the whole history, or tag the release.")
            return nothing
        end
        if tagged && package_tree(settings, tag) != tree
            failure(settings, "Release", "The tag $(tag) isn't the release of $(version) that $(name) records: its tree is $(package_tree(settings, tag)), but the registered tree is $(tree), of the commit $(commit); move the tag.")
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
