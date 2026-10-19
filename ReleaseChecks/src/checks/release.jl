# Release
# -------

# Whether the pull request is a release, written to the step's outputs as `release=true` or `release=false`, for the trunk workflow to choose its checks.
function check(::ReleaseCheck, settings::Settings)
    release = is_release(settings)
    println(release ? "The pull request changes the version to $(head_version(settings)), so it's a release." : "The pull request keeps the version, so it isn't a release.")
    isempty(settings.outputs) || open(io -> println(io, "release=$(release)"), settings.outputs, "a")
    return
end
