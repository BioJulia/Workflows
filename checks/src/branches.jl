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
