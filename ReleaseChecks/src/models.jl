# Models
# ------

abstract type Model end

"A main branch of releases and a develop branch of unreleased work."
struct Gitflow <: Model end

"One main branch, from which release and hotfix branches are released at their last commit, and merged back."
struct OneFlow <: Model end

"One main branch, on which a release is a commit that changes the version."
struct Trunk <: Model end

const MODELS = Dict("gitflow" => Gitflow(), "oneflow" => OneFlow(), "trunk" => Trunk())

title(model::Model) = string(nameof(typeof(model)))
