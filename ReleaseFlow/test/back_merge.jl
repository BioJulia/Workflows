# Back-merge
# ----------

@testset "Back-merge" begin
    directory = mktempdir()
    script = joinpath(directory, "step.sh")
    write(script, workflow_step("back-merge.yml", "Open the pull request that brings one branch into another"))
    # A stand-in for `gh`: it logs its calls with their tokens, creates refs in the origin for `api`, unless `REFUSE_DEFAULT` refuses the default token as GitHub may, and reports `OPEN_PRS` open pull requests.
    bin = mkpath(joinpath(directory, "bin"))
    write(
        joinpath(bin, "gh"), raw"""
        #!/bin/bash
        echo "gh $* (token $GH_TOKEN)" >> "$LOG"
        case "$1 $2" in
          "api repos/"*)
            if [ "$GH_TOKEN" = default ] && [ -n "$REFUSE_DEFAULT" ]; then echo "refusing to allow a GitHub App to create or update workflow without workflows permission" >&2; exit 1; fi
            for a in "$@"; do case "$a" in ref=*) ref=${a#ref=};; sha=*) sha=${a#sha=};; esac; done; git -C "$ORIGIN" update-ref "$ref" "$sha";;
          "pr list") echo "${OPEN_PRS:-0}";;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    origin = joinpath(directory, "origin.git")
    run(pipeline(`git init -q --bare $(origin)`))
    work = repository()
    git(work, "remote", "set-url", "origin", origin)
    commit!(work, "Start", "Project.toml" => project("0.1.0"))
    git(work, "push", "-q", "origin", "HEAD:master", "HEAD:develop")
    branch!(work, "develop", "master")
    commit!(work, "Feature", "feature.txt" => "feature")
    git(work, "push", "-q", "origin", "develop")
    branch!(work, "master", "master")
    commit!(work, "Release", "release.txt" => "release")
    git(work, "push", "-q", "origin", "master")
    git(work, "fetch", "-q", "origin")
    log = joinpath(directory, "log")

    function step(; has_token = "true", open = "0", project = "", refuse_default = false, from = "", into = "")
        write(log, "")
        environment = Dict(
            "PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "ORIGIN" => origin, "GH_TOKEN" => has_token == "true" ? "token" : "default", "HAS_TOKEN" => has_token,
            "DEFAULT_TOKEN" => "default", "REFUSE_DEFAULT" => refuse_default ? "1" : "",
            "REPOSITORY" => "Example/Toy.jl", "RELEASEFLOW_MAIN_BRANCH" => "master", "RELEASEFLOW_DEVELOP_BRANCH" => "develop", "OPEN_PRS" => open, "RELEASEFLOW_PROJECT" => project, "FROM" => from, "INTO" => into,
        )
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = work, ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), calls = readlines(log))
    end

    # The first run creates the branch at master and opens the pull request, which says to reopen it without the token.
    result = step(; has_token = "false")
    @test result.code == 0
    @test git(origin, "rev-parse", "refs/heads/back-merge/v0.1.0") == git(work, "rev-parse", "master")
    @test any(call -> startswith(call, "gh pr create") && occursin("--base develop", call), result.calls)
    @test occursin("close and reopen it", read(log, String))
    # The job's own token creates the branch, so the pull request's token needs only access to pull requests.
    @test any(call -> startswith(call, "gh api") && endswith(call, "(token default)"), result.calls)
    # Where GitHub refuses the job's token the branch, the pull request's token creates it.
    git(origin, "update-ref", "-d", "refs/heads/back-merge/v0.1.0")
    git(work, "fetch", "-q", "--prune", "origin")
    result = step(; refuse_default = true)
    @test result.code == 0 && occursin("The job's token couldn't create the branch back-merge/v0.1.0: refusing to allow", result.output)
    @test [split(call, " (token ")[end] for call in result.calls if startswith(call, "gh api")] == ["default)", "token)"]
    @test git(origin, "rev-parse", "refs/heads/back-merge/v0.1.0") == git(work, "rev-parse", "master")
    # Without another token, the refusal is an error.
    git(origin, "update-ref", "-d", "refs/heads/back-merge/v0.1.0")
    git(work, "fetch", "-q", "--prune", "origin")
    result = step(; has_token = "false", refuse_default = true)
    @test result.code == 1 && occursin("::error title=Back-merge::The job's token couldn't create the branch", result.output)
    git(origin, "update-ref", "refs/heads/back-merge/v0.1.0", git(work, "rev-parse", "master"))
    # A rerun leaves the branch and the open pull request as they are.
    git(work, "fetch", "-q", "origin")
    result = step(; open = "1")
    @test result.code == 0 && occursin("is open already", result.output)
    @test !any(call -> startswith(call, "gh api") || startswith(call, "gh pr create"), result.calls)
    # Nothing to do once develop has master's commit.
    branch!(work, "develop", "origin/develop")
    git(work, "merge", "-q", "--no-edit", "master")
    git(work, "push", "-q", "origin", "develop")
    branch!(work, "master", "master")
    git(work, "fetch", "-q", "origin")
    result = step()
    @test result.code == 0 && occursin("there's nothing to bring back", result.output) && isempty(result.calls)
    # A package in a subdirectory names the branch from its own Project.toml.
    commit!(work, "Subdirectory", "lib/Toy/Project.toml" => project("0.3.0"), "subdirectory.txt" => "x")
    git(work, "push", "-q", "origin", "master")
    git(work, "fetch", "-q", "origin")
    result = step(; project = "lib/Toy/")
    @test result.code == 0 && occursin("back-merge/v0.3.0", result.output)
    # A version that can't name the branch is an error.
    commit!(work, "Bad version", "Project.toml" => replace(project("0.1.0"), "0.1.0" => "0.1"))
    result = step()
    @test result.code == 1 && occursin("Project.toml on master has no version of the form X.Y.Z", result.output)
    # From any other branch, such as a maintenance branch into master, the branch is named after the branch and its commit.
    branch!(work, "maintenance/1.x", "origin/master")
    maintenance = commit!(work, "A fix for 1.x", "maintenance.txt" => "fix")
    git(work, "push", "-q", "origin", "maintenance/1.x")
    git(work, "fetch", "-q", "origin")
    result = step(; from = "maintenance/1.x", into = "master")
    branch = "back-merge/maintenance-1.x-$(first(maintenance, 7))"
    @test result.code == 0
    @test git(origin, "rev-parse", "refs/heads/$(branch)") == maintenance
    create = only(filter(call -> startswith(call, "gh pr create"), result.calls))
    @test occursin("--head $(branch) --base master --title Merge maintenance/1.x into master", create)
    @test occursin("This brings maintenance/1.x into master at its commit $(first(maintenance, 7)).", read(log, String))
    # Nothing to bring once master has the commit.
    git(work, "push", "-q", "origin", "maintenance/1.x:master")
    git(work, "fetch", "-q", "origin")
    result = step(; from = "maintenance/1.x", into = "master")
    @test result.code == 0 && occursin("master already has maintenance/1.x's commit", result.output) && isempty(result.calls)
end

# The back-merge's merge, once TagBot has tagged the release and GitHub would merge it.
@testset "Merging back-merges" begin
    directory = mktempdir()
    script = joinpath(directory, "step.sh")
    write(script, workflow_step("back-merge.yml", "Merge the back-merges that are ready"))
    # A stand-in for `gh`: it logs its calls with their tokens, lists `BACK_MERGES`, reports `APPROVED` approvals and the state `STATE`, and refuses the review or the merge with `REFUSE_REVIEW` or `REFUSE_MERGE`'s message.
    bin = mkpath(joinpath(directory, "bin"))
    write(
        joinpath(bin, "gh"), raw"""
        #!/bin/bash
        echo "gh $* (token $GH_TOKEN)" >> "$LOG"
        case "$1 $2" in
          "pr list") echo -n "$BACK_MERGES";;
          "pr view") case "$*" in *latestReviews*) echo "${APPROVED:-0}";; *) echo "$STATE";; esac;;
          "pr review") if [ -n "$REFUSE_REVIEW" ]; then echo "$REFUSE_REVIEW" >&2; exit 1; fi;;
          "pr merge") if [ -n "$REFUSE_MERGE" ]; then echo "$REFUSE_MERGE" >&2; exit 1; fi;;
        esac
        """
    )
    chmod(joinpath(bin, "gh"), 0o755)
    origin = joinpath(directory, "origin.git")
    run(pipeline(`git init -q --bare $(origin)`))
    work = repository()
    git(work, "remote", "set-url", "origin", origin)
    git(work, "config", "tag.gpgsign", "false")
    commit!(work, "Start", "Project.toml" => project("0.1.0"))
    git(work, "push", "-q", "origin", "HEAD:master", "HEAD:develop")
    release = commit!(work, "Release 0.1.1", "Project.toml" => project("0.1.1"))
    git(work, "push", "-q", "origin", "HEAD:master", "HEAD:refs/heads/back-merge/v0.1.1")
    log = joinpath(directory, "log")
    summary = joinpath(directory, "summary.md")

    function step(; back_merges = "7 back-merge/v0.1.1 $(release)\n", state = "CLEAN APPROVED $(release)", approved = "0", has_token = "true", refuse_review = "", refuse_merge = "", from = "")
        write(log, "")
        write(summary, "")
        environment = Dict(
            "PATH" => "$(bin):$(ENV["PATH"])", "LOG" => log, "GITHUB_STEP_SUMMARY" => summary, "RELEASEFLOW_RETRY_SECONDS" => "0",
            "GH_TOKEN" => has_token == "true" ? "token" : "", "HAS_TOKEN" => has_token, "DEFAULT_TOKEN" => "default",
            "REPOSITORY" => "Example/Toy.jl", "RELEASEFLOW_MAIN_BRANCH" => "master", "RELEASEFLOW_DEVELOP_BRANCH" => "develop", "FROM" => from, "INTO" => "",
            "BACK_MERGES" => back_merges, "STATE" => state, "APPROVED" => approved, "REFUSE_REVIEW" => refuse_review, "REFUSE_MERGE" => refuse_merge,
        )
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, environment); dir = work, ignorestatus = true); stdout = output, stderr = output))
        calls = readlines(log)
        return (
            code = process.exitcode, output = String(take!(output)), summary = read(summary, String), calls = calls,
            approvals = filter(call -> startswith(call, "gh pr review"), calls), merges = filter(call -> startswith(call, "gh pr merge"), calls),
        )
    end

    # Without the tag, the back-merge waits for TagBot, without approving or merging.
    result = step()
    @test result.code == 0 && occursin("#7, back-merge/v0.1.1 waits for TagBot to tag v0.1.1.", result.summary)
    @test isempty(result.approvals) && isempty(result.merges)
    # Without open back-merges, there's nothing to do.
    result = step(; back_merges = "")
    @test result.code == 0 && occursin("There's no open back-merge of a release into develop.", result.summary)
    # Only the back-merges of releases, from the main branch, merge themselves.
    result = step(; from = "maintenance/1.x")
    @test result.code == 0 && occursin("merge the one from maintenance/1.x by hand", result.summary) && isempty(result.calls)
    # Without the app's token or RELEASEFLOW_TOKEN, the merge couldn't start develop's workflows, so it says which secrets to give.
    result = step(; has_token = "false")
    @test result.code == 1 && occursin("::error title=Back-merge::Merging a back-merge needs the ReleaseFlow app's secrets", result.output) && isempty(result.calls)

    # Once TagBot tags the release's commit, github-actions[bot] approves the back-merge with the job's token, and the app's token merges it at the head that was checked.
    git(work, "tag", "v0.1.1", release)
    git(work, "push", "-q", "origin", "v0.1.1")
    result = step()
    @test result.code == 0
    @test only(result.approvals) == "gh pr review 7 --repo Example/Toy.jl --approve --body TagBot has tagged v0.1.1 at $(first(release, 7)), the release's commit, so this back-merge can merge. (token default)"
    @test only(result.merges) == "gh pr merge 7 --repo Example/Toy.jl --merge --match-head-commit $(release) (token token)"
    @test occursin("Merged #7, back-merge/v0.1.1 into develop, after TagBot tagged v0.1.1 at $(first(release, 7)).", result.summary)
    # An approval already given isn't given again.
    result = step(; approved = "1")
    @test result.code == 0 && isempty(result.approvals) && length(result.merges) == 1
    # Once a maintainer has merged develop into the back-merge to resolve a conflict, the release's commit is still in its history.
    branch!(work, "back-merge/v0.1.1", "v0.1.1")
    git(work, "merge", "-q", "--no-edit", "origin/develop")
    resolved = commit!(work, "Resolve", "resolved.txt" => "resolved")
    git(work, "push", "-q", "origin", "HEAD:refs/heads/back-merge/v0.1.1")
    result = step(; back_merges = "7 back-merge/v0.1.1 $(resolved)\n", state = "CLEAN APPROVED $(resolved)")
    @test result.code == 0 && only(result.merges) == "gh pr merge 7 --repo Example/Toy.jl --merge --match-head-commit $(resolved) (token token)"

    # A back-merge that GitHub wouldn't merge yet says what it waits for, and isn't merged.
    waits(state) = step(; state = "$(state) $(release)")
    result = waits("BLOCKED REVIEW_REQUIRED")
    @test result.code == 0 && isempty(result.merges) && occursin("needs a review that github-actions[bot] can't give, such as a code owner's", result.summary)
    result = waits("BLOCKED APPROVED")
    @test result.code == 0 && isempty(result.merges) && occursin("waits for its required checks; their completion merges it.", result.summary)
    result = waits("DIRTY APPROVED")
    @test result.code == 0 && isempty(result.merges) && occursin("conflicts with develop: merge develop into back-merge/v0.1.1", result.summary)
    result = waits("BEHIND APPROVED")
    @test result.code == 0 && isempty(result.merges) && occursin("is behind develop", result.summary)
    result = waits("UNSTABLE APPROVED")
    @test result.code == 0 && isempty(result.merges) && occursin("merge it by hand", result.summary)
    # A state that stays unknown is retried, then reported.
    result = waits("UNKNOWN APPROVED")
    @test result.code == 0 && isempty(result.merges) && count(call -> occursin("mergeStateStatus", call), result.calls) == 6
    @test occursin("GitHub's state of it is UNKNOWN", result.summary)

    # A setting or permission that's missing is named, with GitHub's own message.
    result = step(; refuse_review = "failed to create review: GraphQL: GitHub Actions is not permitted to approve pull requests. (addPullRequestReview)")
    @test result.code == 1 && isempty(result.merges)
    @test occursin("::error title=Back-merge::GitHub Actions couldn't approve #7, back-merge/v0.1.1: turn on Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests.", result.output)
    @test occursin("GitHub said: failed to create review: GraphQL: GitHub Actions is not permitted to approve pull requests.", result.output)
    result = step(; refuse_merge = "GraphQL: Resource not accessible by integration (mergePullRequest)")
    @test result.code == 1 && occursin("needs Contents and Pull requests: Read and write on Example/Toy.jl. GitHub said: GraphQL: Resource not accessible by integration", result.summary)
    result = step(; refuse_merge = "GraphQL: Pull request is not mergeable (mergePullRequest)")
    @test result.code == 1 && occursin("The token couldn't merge #7, back-merge/v0.1.1: GraphQL: Pull request is not mergeable", result.summary)
    # A back-merge that moves while it's being merged waits for its checks again.
    result = step(; refuse_merge = "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)")
    @test result.code == 0 && occursin("moved while it was being merged", result.summary)

    # A tag that TagBot made at a commit that the back-merge doesn't bring is an error, and the back-merge isn't merged.
    other = commit!(work, "Elsewhere", "elsewhere.txt" => "x")
    git(work, "tag", "-f", "v0.1.1", other)
    git(work, "push", "-q", "--force", "origin", "v0.1.1")
    result = step()
    @test result.code == 1 && isempty(result.approvals) && isempty(result.merges)
    @test occursin("::error title=Back-merge::#7, back-merge/v0.1.1 isn't merged: v0.1.1 is at $(first(other, 7)), which the back-merge, at $(first(release, 7)), doesn't bring", result.output)
end
