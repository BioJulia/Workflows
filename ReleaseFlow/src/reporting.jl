# Reporting
# ---------

# Report a failure as an annotation of GitHub Actions, which a pull request shows, and remember it in the run's settings.
function failure(settings::Settings, title, message)
    println("::error title=$(title)::", replace(message, "\n" => "%0A"))
    push!(settings.errors, message)
    return
end

note(message) = println("::notice::", replace(message, "\n" => "%0A"))

# Append Markdown to the job's summary, which GitHub Actions shows on the run's page.
function summary(settings::Settings, text)
    isempty(settings.step_summary) || open(io -> println(io, text), settings.step_summary, "a")
    return
end
