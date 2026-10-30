# The dependents workflow
# -----------------------

@testset "Dependents" begin
    directory = mktempdir()
    script = joinpath(directory, "step.sh")
    write(script, workflow_step("dependents.yml", "List the dependents"))
    function list(dependents)
        outputs = joinpath(directory, "outputs")
        write(outputs, "")
        output = IOBuffer()
        process = run(pipeline(Cmd(addenv(`bash $(script)`, "DEPENDENTS" => dependents, "GITHUB_OUTPUT" => outputs); ignorestatus = true); stdout = output, stderr = output))
        return (code = process.exitcode, output = String(take!(output)), matrix = readchomp(outputs))
    end
    # One per line or separated by commas, with spaces and duplicates, in order.
    result = list("BioJulia/GFF3.jl\n  BioJulia/BED.jl, BioJulia/XAM.jl,\n\nBioJulia/BED.jl\n")
    @test result.code == 0
    @test result.matrix == """matrix=["BioJulia/BED.jl", "BioJulia/GFF3.jl", "BioJulia/XAM.jl"]"""
    @test list("Example/Toy.jl").matrix == """matrix=["Example/Toy.jl"]"""
    @test fails(list("BioJulia/BED.jl, not a repository"), "not a repository isn't a repository")
    @test fails(list(" , \n"), "names no repository")
end
