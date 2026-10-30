# Release
# -------

# Whether the pull request is a release, written to the step's outputs as `release=true` or `release=false`, for the trunk workflow to choose its checks.
function check(::IsReleaseCheck, settings::Settings)
    release = is_release(settings)
    println(release ? "The pull request changes the version to $(head_version(settings)), so it's a release." : "The pull request keeps the version, so it isn't a release.")
    output(settings, "release", string(release))
    return
end
