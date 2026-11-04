# The package
# -----------

head_project(settings::Settings) = TOML.parsefile(joinpath(package_directory(settings), "Project.toml"))

head_version(settings::Settings) = VersionNumber(head_project(settings)["version"])

base_version(settings::Settings) = version_at(settings, settings.base_ref)

# The package's version at `ref`, or `nothing` where it has no project or the project has no version.
function version_at(settings::Settings, ref)
    project = file_at(settings, ref, package_path(settings, "Project.toml"))
    project === nothing && return nothing
    version = get(TOML.parse(project), "version", nothing)
    return version === nothing ? nothing : VersionNumber(version)
end
