# Settings
# --------

"""
    Settings{M}

The inputs of a run of the checks under the model `M`, from the environment, what the run has found, such as the registry and the last release, and its failures.
"""
struct Settings{M <: Model}
    model::M
    root::String
    # The package's directory, relative to the root; empty for a package at the root.
    project::String
    main_branch::String
    develop_branch::String
    head_ref::String
    head_sha::String
    base_branch::String
    base_ref::String
    develop_ref::String
    skip_label::String
    skip_changelog::Bool
    check_links::Bool
    registry::String
    # Where GitHub Actions names the repository, takes a step's outputs and shows a job's summary; empty outside it.
    repository::String
    outputs::String
    step_summary::String
    found::Dict{Symbol, Any}
    errors::Vector{String}
end

# An input, or `default` where it's missing or empty, as GitHub Actions passes an input that it has no value for.
input(environment, name, default) = (value = get(environment, name, ""); isempty(value) ? default : value)

function Settings(environment = ENV; root = pwd())
    main_branch = input(environment, "MAIN_BRANCH", "master")
    develop_branch = input(environment, "DEVELOP_BRANCH", "develop")
    return Settings(
        MODELS[input(environment, "MODEL", "gitflow")],
        root,
        String(strip(input(environment, "PROJECT", ""), '/')),
        main_branch,
        develop_branch,
        input(environment, "HEAD_REF", ""),
        input(environment, "HEAD_SHA", "HEAD"),
        input(environment, "BASE_BRANCH", ""),
        input(environment, "BASE_REF", "origin/$(main_branch)"),
        input(environment, "DEVELOP_REF", "origin/$(develop_branch)"),
        input(environment, "SKIP_LABEL", "skip changelog"),
        lowercase(input(environment, "SKIP_CHANGELOG", "false")) == "true",
        lowercase(input(environment, "CHECK_LINKS", "true")) == "true",
        input(environment, "REGISTRY", "General"),
        input(environment, "GITHUB_REPOSITORY", ""),
        input(environment, "GITHUB_OUTPUT", ""),
        input(environment, "GITHUB_STEP_SUMMARY", ""),
        Dict{Symbol, Any}(),
        String[],
    )
end

# The path of `name` in the package, relative to the repository's root, as git names it.
package_path(settings::Settings, name) = isempty(settings.project) ? name : "$(settings.project)/$(name)"

# The package's directory in the checkout at `root`.
package_directory(settings::Settings, root = settings.root) = joinpath(root, settings.project)

# What `find` gives, found once per run.
found!(find, settings::Settings, key::Symbol) = get!(find, settings.found, key)

head_label(settings::Settings) = isempty(settings.head_ref) ? settings.head_sha : settings.head_ref
