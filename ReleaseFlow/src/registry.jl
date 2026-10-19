# The registry
# ------------

# The registry `settings.registry`, updated, or `nothing` where it can't be had; a path is read as it is, as the tests do.
registry(settings::Settings) = found!(() -> open_registry(settings.registry), settings, :registry)

function open_registry(name)
    try
        isdir(name) && return Pkg.Registry.RegistryInstance(name)
        installed = any(instance -> instance.name == name, Pkg.Registry.reachable_registries())
        installed ? Pkg.Registry.update(name; io = devnull) : Pkg.Registry.add(name; io = devnull)
        return only(filter(instance -> instance.name == name, Pkg.Registry.reachable_registries()))
    catch exception
        note("The registry $(name) couldn't be read, so releases are found by their tags: $(sprint(showerror, exception))")
        return nothing
    end
end

# The registry's name, for messages.
registry_name(settings::Settings) = (instance = registry(settings); instance === nothing ? settings.registry : instance.name)

# The versions of the package that the registry records, each with its information, or `nothing` where the registry doesn't know the package.
function registered(settings::Settings)
    instance = registry(settings)
    instance === nothing && return nothing
    entry = get(instance, UUID(head_project(settings)["uuid"]), nothing)
    entry === nothing && return nothing
    # Pkg's registry API changed in Julia 1.13, which passes the registry with the entry.
    info = applicable(Pkg.Registry.registry_info, instance, entry) ? Pkg.Registry.registry_info(instance, entry) : Pkg.Registry.registry_info(entry)
    return info.version_info
end

# The tree of the package's `version` that the registry records, or `nothing` where it records none.
function registered_tree(settings::Settings, version)
    versions = registered(settings)
    version_info = versions === nothing ? nothing : get(versions, version, nothing)
    return version_info === nothing ? nothing : string(version_info.git_tree_sha1)
end

# Every version of the package that the registry records, in order; none for a package that it doesn't know.
registered_versions(settings::Settings) = (versions = registered(settings); versions === nothing ? VersionNumber[] : sort!(collect(keys(versions))))
