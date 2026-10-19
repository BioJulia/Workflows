# The checks
# ----------

abstract type Check end

struct SourceCheck <: Check end
struct VersionCheck <: Check end
struct ChangelogCheck <: Check end
struct BreakingCheck <: Check end
struct EntryCheck <: Check end
struct IsReleaseCheck <: Check end
struct PrepareCheck <: Check end
struct RegistrationCheck <: Check end

const CHECKS = Dict(
    "source" => SourceCheck(), "version" => VersionCheck(), "changelog" => ChangelogCheck(),
    "breaking" => BreakingCheck(), "entry" => EntryCheck(), "is-release" => IsReleaseCheck(), "prepare" => PrepareCheck(), "registration" => RegistrationCheck(),
)
