# Registration
# ------------
#
# What to register of the package at the head: its version, whether the registry still lacks it, and its section of the changelog, as the release notes.
# The register workflow comments `@JuliaRegistrator register` where it does, after a release merges into the main branch, or under OneFlow from its release branch.
# A package's first release is registered by hand, as a new package's review in the registry calls for, and the check says how.

function check(::RegistrationCheck, settings::Settings)
    version = head_version(settings)
    path = joinpath(package_directory(settings), "CHANGELOG.md")
    notes = isfile(path) ? something(section_text(read(path, String), version), "") : ""
    output(settings, "version", string(version))
    output(settings, "register", string(to_register(settings, version)))
    output(settings, "notes", notes)
    return
end

# Whether the register workflow comments for Registrator: only where the registry knows the package and lacks `version`.
function to_register(settings::Settings, version)
    command = isempty(settings.project) ? "@JuliaRegistrator register" : "@JuliaRegistrator register subdir=$(settings.project)"
    commit = git(settings, "rev-parse", "HEAD")
    # The registry reads its files as it's asked, so a broken one may only fail here.
    versions = try
        registry(settings) === nothing ? missing : registered(settings)
    catch exception
        note("The registry $(settings.registry) couldn't be read: $(sprint(showerror, exception))")
        missing
    end
    if versions === missing
        failure(settings, "Registration", "The registry $(settings.registry) couldn't be read, so whether it records $(version) is unknown; if it doesn't, comment `$(command)` on the commit $(commit).")
        return false
    elseif versions === nothing
        name = head_project(settings)["name"]
        first = is_first_version(version) ? "" : " A new package's first version must be 0.0.1, 0.1.0 or X.0.0, which $(version) isn't."
        message = "$(registry_name(settings)) doesn't know $(name) yet, so its first release, $(version), is registered by hand: comment `$(command)` on the commit $(commit).$(first) Once the registry merges it, after its waiting period for new packages, this workflow registers later releases by itself."
        warning("Registration", message)
        summary(settings, "## Registering $(name) $(version)\n\n$(message)")
        return false
    elseif registered_tree(settings, version) === nothing
        println("$(registry_name(settings)) doesn't record $(version) yet, so it's to be registered.")
        return true
    else
        println("$(registry_name(settings)) already records $(version), so there's nothing to register.")
        return false
    end
end
