# The package
# -----------

head_project(settings::Settings) = TOML.parsefile(joinpath(package_directory(settings), "Project.toml"))

head_version(settings::Settings) = VersionNumber(head_project(settings)["version"])

function base_version(settings::Settings)
    project = base_file(settings, package_path(settings, "Project.toml"))
    project === nothing && return nothing
    version = get(TOML.parse(project), "version", nothing)
    return version === nothing ? nothing : VersionNumber(version)
end
