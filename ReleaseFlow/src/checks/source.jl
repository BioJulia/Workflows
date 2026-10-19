# Source branch
# -------------

function check(::SourceCheck, settings::Settings)
    if settings.base_branch == settings.main_branch
        into_main(settings, head_branch(settings))
    elseif settings.base_branch == settings.develop_branch
        into_develop(settings, head_branch(settings))
    else
        uncovered(settings)
    end
    return
end

check(::SourceCheck, ::Settings{Trunk}) = note("The trunk model has no rules about source branches.")

uncovered(settings::Settings) = note("The $(title(settings.model)) checks don't cover pull requests into $(isempty(settings.base_branch) ? "an unnamed branch; set RELEASEFLOW_BASE_BRANCH" : settings.base_branch).")

# Only gitflow has a develop branch.
into_develop(settings::Settings, ::Branch) = uncovered(settings)

# Gitflow: the main branch takes merges only from release and hotfix branches; develop takes them from any other branch, and release and hotfix branches reach it through the main branch.
function into_main(settings::Settings{Gitflow}, branch::ReleaseOrHotfix)
    println("$(settings.main_branch) takes the merge of $(branch.name), a release or hotfix branch.")
    check_origin(settings, branch, settings.develop_ref, settings.develop_branch, settings.base_ref, settings.main_branch)
    return
end

into_main(settings::Settings{Gitflow}, branch::Branch) = failure(settings, "Gitflow", "$(settings.main_branch) takes merges only from release/* and hotfix/* branches, as gitflow does, not from $(branch.name); merge features into $(settings.develop_branch).")

into_develop(settings::Settings{Gitflow}, branch::ReleaseOrHotfix) = failure(settings, "Gitflow", "$(settings.develop_branch) doesn't take merges from release/* and hotfix/* branches, such as $(branch.name); merge it into $(settings.main_branch), and then merge $(settings.main_branch) into $(settings.develop_branch).")

into_develop(settings::Settings{Gitflow}, branch::Branch) = println("$(settings.develop_branch) takes the merge of $(branch.name).")

# OneFlow: the main branch takes any branch; a hotfix branches from the last release's tag, and a release carries the main branch's work since then.
into_main(settings::Settings{OneFlow}, branch::ReleaseOrHotfix) = oneflow_origin(settings, branch, last_release(settings))

function oneflow_origin(settings::Settings{OneFlow}, branch::ReleaseOrHotfix, release::LastRelease)
    println("$(settings.main_branch) takes the merge of $(branch.name), a release or hotfix branch.")
    check_origin(settings, branch, settings.base_ref, settings.main_branch, release.ref, "the release $(release.version), v$(release.version)")
    return
end

# Without a released commit, there's nothing to measure where the branch came from against.
oneflow_origin(settings::Settings{OneFlow}, branch::ReleaseOrHotfix, ::LastRelease{MainBranch}) = note("The last release has no commit of its own, so where $(branch.name) came from isn't checked.")
oneflow_origin(settings::Settings{OneFlow}, branch::ReleaseOrHotfix, ::InitialRelease) = note("This is the initial release, so where $(branch.name) came from isn't checked.")

into_main(settings::Settings{OneFlow}, branch::Branch) = println("$(settings.main_branch) takes the merge of $(branch.name).")

# A hotfix branches from what's released, so the point where it last met the branch of unreleased work, `unreleased`, is already released; a release branches from that branch, so that point isn't released yet.
# The head commit is compared, not the merge commit that GitHub Actions checks out, and with this repository's branches, so a fork's own branches don't matter.
function check_origin(settings::Settings, branch::ReleaseOrHotfix, unreleased, unreleased_name, released, released_name)
    if !has_ref(settings, unreleased)
        note("There's no $(unreleased), so where $(branch.name) came from isn't checked.")
        return
    end
    fork = merge_base(settings, settings.head_sha, unreleased)
    is_released = fork === nothing || is_ancestor(settings, fork, released)
    origin(settings, branch, is_released, fork, unreleased_name, released, released_name)
    return
end

function origin(settings::Settings, branch::Branch{Hotfix}, is_released, fork, unreleased_name, released, released_name)
    if is_released
        println("$(branch.name) carries no unreleased commit of $(unreleased_name).")
    else
        commits = split(something(git(settings, "log", "--oneline", "-n", "5", "$(released)..$(fork)"), ""), '\n')
        failure(settings, title(settings.model), "The hotfix $(branch.name) carries unreleased commits of $(unreleased_name), such as:\n$(join(commits, '\n'))\nBranch a hotfix from $(released_name).")
    end
    return
end

function origin(settings::Settings, branch::Branch{Release}, is_released, fork, unreleased_name, released, released_name)
    if is_released
        failure(settings, title(settings.model), "The release $(branch.name) carries none of the unreleased commits of $(unreleased_name); branch a release from $(unreleased_name).")
    else
        println("$(branch.name) carries the unreleased commits of $(unreleased_name).")
    end
    return
end
