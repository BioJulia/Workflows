# Prepare
# -------
#
# Prepare a release in a checkout of the branch that it starts from: set its version in Project.toml, give the changelog's unreleased entries its section, with its links, and set the pins of an action to it.
# The workflow then commits the changes on the branch that `branch` names, and opens its pull request into `base`.

# A release or a hotfix, as `RELEASEFLOW_KIND` names it.
release_kind(settings::Settings) = settings.kind == "hotfix" ? Hotfix() : Release()

kind_label(::Release) = "release"
kind_label(::Hotfix) = "hotfix"

# Trunk releases from its main branch, and has no hotfixes.
allows(::Settings, ::Kind) = true
allows(settings::Settings{Trunk}, ::Hotfix) = (failure(settings, "Prepare", "The trunk model has no hotfixes; prepare a release, from the main branch."); false)

# `auto`: a `### Breaking` subsection of the unreleased changes takes a breaking version, `### Added` the next minor version, and anything else the next patch.
function auto_step(unreleased)
    unreleased === nothing && return "patch"
    subsection_entries(unreleased, "Breaking") > 0 && return "breaking"
    subsection_entries(unreleased, "Added") > 0 && return "minor"
    return "patch"
end

# The version that a release of `kind` takes after its baseline, or `nothing` where it can't take one.
function next_version(settings::Settings, ::Release, release::LastRelease, unreleased)
    base = release.version
    step = settings.step == "auto" ? auto_step(unreleased) : settings.step
    step == "breaking" && return first(breaking_steps(base))
    step == "major" && return next_major(base)
    step == "minor" && return next_minor(base)
    return next_patch(base)
end

next_version(::Settings, ::Hotfix, release::LastRelease, unreleased) = next_patch(release.version)

# The initial release takes a standard first version: 0.1.0, unless the step asks for 1.0.0, or for 0.0.1.
next_version(settings::Settings, ::Release, ::InitialRelease, unreleased) = settings.step == "major" ? v"1.0.0" : settings.step == "patch" ? v"0.0.1" : v"0.1.0"

next_version(settings::Settings, ::Hotfix, ::InitialRelease, unreleased) = (failure(settings, "Prepare", "There's no release to fix, so a hotfix can't be the initial release; prepare a release."); nothing)

release_branch(kind::Kind, version) = "$(kind_label(kind))/v$(version)"

# The link of a version's section: the comparison with the last release's tag, or the initial release's own tag.
version_link(url, version, release::LastRelease) = "$(url)/compare/v$(release.version)...v$(version)"
version_link(url, version, ::InitialRelease) = "$(url)/releases/tag/v$(version)"

function set_version!(settings::Settings, version)
    path = joinpath(package_directory(settings), "Project.toml")
    text = read(path, String)
    pattern = r"^version\s*=.*$"m
    occursin(pattern, text) || (failure(settings, "Prepare", "$(package_path(settings, "Project.toml")) has no version."); return)
    write(path, replace(text, pattern => "version = \"$(version)\""; count = 1))
    return
end

# Give the unreleased entries the section of `version`, under the unreleased heading, which stays, empty; without one, the section goes before the newest version's.
# The links follow: the unreleased changes compare with the new version's tag, and the new version with the last release's.
function add_section!(settings::Settings, version, release::Baseline)
    path = joinpath(package_directory(settings), "CHANGELOG.md")
    isfile(path) || (failure(settings, "Prepare", "There's no $(package_path(settings, "CHANGELOG.md"))."); return)
    lines = String.(split(rstrip(read(path, String)), '\n'))
    heading = "## [$(version)] - $(settings.date)"
    unreleased = findfirst(line -> occursin(UNRELEASED, line), lines)
    if unreleased !== nothing
        splice!(lines, (unreleased + 1):unreleased, ["", heading])
    else
        newest = findfirst(line -> heading_of(line) isa Released, lines)
        at = something(newest, length(lines) + 1)
        splice!(lines, at:(at - 1), newest === nothing ? ["", heading] : [heading, ""])
    end
    url = repository_url(settings)
    if settings.check_links && url !== nothing
        link = "[$(version)]: $(version_link(url, version, release))"
        defined = findfirst(line -> occursin(r"^\[unreleased\]:"i, line), lines)
        if unreleased !== nothing && defined !== nothing
            lines[defined] = "[Unreleased]: $(url)/compare/v$(version)...HEAD"
            insert!(lines, defined + 1, link)
        elseif unreleased !== nothing
            first_link = findfirst(is_link, lines)
            new = ["[Unreleased]: $(url)/compare/v$(version)...HEAD", link]
            first_link === nothing ? append!(lines, ["", new...]) : splice!(lines, first_link:(first_link - 1), new)
        else
            first_link = findfirst(is_link, lines)
            first_link === nothing ? append!(lines, ["", link]) : insert!(lines, first_link, link)
        end
    end
    write(path, join(lines, '\n') * '\n')
    return
end

heading_of(line) = startswith(line, "## ") ? heading(line) : nothing

# Set each pin of the action `settings.pin_action` in the workflows, `uses: <action>@vA.B.C`, to the new version; a major tag, such as `@v1`, stays.
function set_pins!(settings::Settings, version)
    isempty(settings.pin_action) && return 0
    directory = joinpath(settings.root, ".github", "workflows")
    isdir(directory) || return 0
    pattern = Regex("(uses:\\s*" * replace(settings.pin_action, "." => "\\.") * "(?:/[^@\\s]*)?@)v\\d+\\.\\d+\\.\\d+")
    changed = 0
    for file in readdir(directory; join = true)
        endswith(file, ".yml") || endswith(file, ".yaml") || continue
        text = read(file, String)
        new = replace(text, pattern => SubstitutionString("\\1v$(version)"))
        new == text && continue
        write(file, new)
        changed += 1
    end
    return changed
end

function check(::PrepareCheck, settings::Settings)
    settings.kind in ("release", "hotfix") || return failure(settings, "Prepare", "RELEASEFLOW_KIND is `release` or `hotfix`, not `$(settings.kind)`.")
    settings.step in ("auto", "patch", "minor", "major") || return failure(settings, "Prepare", "RELEASEFLOW_STEP is `auto`, `patch`, `minor` or `major`, not `$(settings.step)`.")
    kind = release_kind(settings)
    allows(settings, kind) || return
    release = last_release(settings)
    text = head_changelog(settings)
    text === nothing && return
    parsed = sections(text)
    index = unreleased_index(parsed)
    version = next_version(settings, kind, release, index === nothing ? nothing : parsed[index])
    (version === nothing || !isempty(settings.errors)) && return
    set_version!(settings, version)
    add_section!(settings, version, release)
    pins = set_pins!(settings, version)
    isempty(settings.errors) || return
    branch = release_branch(kind, version)
    println("Prepared the $(kind_label(kind)) $(version), after $(label(release)), for $(branch) into $(settings.main_branch)$(pins > 0 ? ", with the pins of $(settings.pin_action) in $(pins) workflows" : "").")
    output(settings, "version", string(version))
    output(settings, "branch", branch)
    output(settings, "base", settings.main_branch)
    output(settings, "notes", something(section_text(read(joinpath(package_directory(settings), "CHANGELOG.md"), String), version), ""))
    return
end
