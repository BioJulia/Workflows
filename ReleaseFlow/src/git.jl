# Git
# ---

# The output of `git arguments...` in the repository, without its last newline, or `nothing` where git fails.
function git(settings::Settings, arguments...)
    output = IOBuffer()
    process = run(pipeline(ignorestatus(`git -C $(settings.root) $(arguments)`); stdout = output, stderr = devnull))
    return success(process) ? chomp(String(take!(output))) : nothing
end

# The contents of `path` at `ref`, or `nothing` where `ref` has no such file, or doesn't exist.
file_at(settings::Settings, ref, path) = git(settings, "show", "$(ref):$(path)")

base_file(settings::Settings, path) = file_at(settings, settings.base_ref, path)

has_ref(settings::Settings, ref) = git(settings, "rev-parse", "--verify", "--quiet", "$(ref)^{commit}") !== nothing

has_base(settings::Settings) = has_ref(settings, settings.base_ref)

has_tag(settings::Settings, tag) = has_ref(settings, "refs/tags/$(tag)")

# The commit where `a` and `b` last met, or `nothing` where they never did.
merge_base(settings::Settings, a, b) = git(settings, "merge-base", a, b)

is_ancestor(settings::Settings, a, b) = git(settings, "merge-base", "--is-ancestor", a, b) !== nothing

# The tree of the package at `ref`, which is what a registry records: the repository's, or the package's subdirectory's.
package_tree(settings::Settings, ref) = git(settings, "rev-parse", isempty(settings.project) ? "$(ref)^{tree}" : "$(ref):$(settings.project)")

# The first commit of any branch or tag whose package tree is `tree`, or `nothing`.
function commit_with_tree(settings::Settings, tree)
    if isempty(settings.project)
        for line in split(something(git(settings, "log", "--all", "--format=%H %T"), ""), '\n')
            commit, commit_tree = (split(line, ' ')..., "", "")
            commit_tree == tree && return String(commit)
        end
    else
        # Only the commits that change the package's subdirectory can be the first with its tree.
        for commit in split(something(git(settings, "log", "--all", "--format=%H", "--", settings.project), ""), '\n')
            isempty(commit) || package_tree(settings, commit) != tree || return String(commit)
        end
    end
    return nothing
end
