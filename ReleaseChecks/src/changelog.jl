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
    path = joinpath(package_directory(settings), "CHANGELOG.md")
    isfile(path) || (failure(settings, "Changelog", "There's no $(package_path(settings, "CHANGELOG.md"))."); return nothing)
    return read(path, String)
end

# The URL of the repository on GitHub, from `GITHUB_REPOSITORY` in GitHub Actions, or from the `origin` remote locally; `nothing` where neither gives one.
function repository_url(settings::Settings)
    repository = settings.repository
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
# After the initial release, the oldest version's link may compare with an earlier tag, as a changelog begun after earlier releases does; the initial release's links to its own tag.
compares_earlier(::LastRelease) = true
compares_earlier(::InitialRelease) = false

function check_links(settings::Settings, text, parsed, release::Baseline)
    url = repository_url(settings)
    url === nothing && (failure(settings, "Changelog", "The repository's URL is unknown, so the links of CHANGELOG.md can't be checked; set `GITHUB_REPOSITORY`, such as `owner/Package.jl`."); return)
    definitions = links(text)
    released = versions(parsed)
    for (index, version) in enumerate(released)
        expected = index == length(released) ? "$(url)/releases/tag/v$(version)" : "$(url)/compare/v$(released[index + 1])...v$(version)"
        actual = get(definitions, string(version), get(definitions, "v$(version)", nothing))
        if actual === nothing
            failure(settings, "Changelog", "CHANGELOG.md has no link for $(version); add `[$(version)]: $(expected)` at its end.")
        elseif actual != expected && !(index == length(released) && compares_earlier(release) && from_earlier(actual, url, version))
            failure(settings, "Changelog", "The link for $(version) in CHANGELOG.md is $(actual), but it should be $(expected).")
        end
    end
    if unreleased_index(parsed) !== nothing
        occursin(r"^##\s+\[Unreleased\]\s*$"im, text) || failure(settings, "Changelog", "Head the unreleased section of CHANGELOG.md `## [Unreleased]`, so that it links to the unreleased changes.")
        if !isempty(released)
            expected = "$(url)/compare/v$(first(released))...HEAD"
            actual = get(definitions, "unreleased", nothing)
            if actual === nothing
                failure(settings, "Changelog", "CHANGELOG.md has no link for the unreleased changes; add `[Unreleased]: $(expected)` at its end.")
            elseif actual != expected
                failure(settings, "Changelog", "The link for the unreleased changes in CHANGELOG.md is $(actual), but it should be $(expected).")
            end
        end
    end
    return
end
