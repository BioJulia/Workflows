# The package
# -----------

head_project(settings::Settings) = TOML.parsefile(joinpath(settings.root, "Project.toml"))

head_version(settings::Settings) = VersionNumber(head_project(settings)["version"])

function base_version(settings::Settings)
    project = base_file(settings, "Project.toml")
    project === nothing && return nothing
    version = get(TOML.parse(project), "version", nothing)
    return version === nothing ? nothing : VersionNumber(version)
end
