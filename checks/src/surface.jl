# Lists the public API of the package named by the first argument: its public names and those of its public submodules, the methods of its public functions, with their keywords, and the supertypes, parameters and fields of its public types.
# With `against` and the path of another version's listing, it instead writes each entry of that listing that this version no longer provides.
#
# The breaking check runs it in a fresh Julia process in the package's project: `julia --project=<package> surface.jl Name list` or `… Name against <listing>`.

using Pkg
# A manifest left over from another version would lack this version's dependencies, so they're resolved afresh.
Pkg.resolve(; io = devnull)
Pkg.instantiate(; io = devnull)
const NAME = Symbol(ARGS[1])
@eval import $(NAME)
const PACKAGE = getfield(Main, NAME)

# Whether a method belongs to the package, rather than to a package whose function it extends.
function owned(method)
    m = method.module
    while m !== parentmodule(m) && m !== PACKAGE
        m = parentmodule(m)
    end
    return m === PACKAGE
end

signature(method) = join(string.(Base.unwrap_unionall(method.sig).parameters[2:end]), ", ")

function listing!(lines, mod, prefix)
    for name in sort(names(mod))
        (name === nameof(mod) || !isdefined(mod, name)) && continue
        value = getfield(mod, name)
        label = "$(prefix).$(name)"
        if value isa Module
            parentmodule(value) === mod && value !== mod && (push!(lines, "module\t$(label)"); listing!(lines, value, label))
        elseif value isa Function
            push!(lines, "function\t$(label)")
            for method in methods(value)
                owned(method) || continue
                push!(lines, "method\t$(label)\t$(signature(method))")
                for keyword in Base.kwarg_decl(method)
                    push!(lines, "keyword\t$(label)\t$(signature(method))\t$(keyword)")
                end
            end
        elseif value isa Type
            type = Base.unwrap_unionall(value)
            push!(lines, "type\t$(label)")
            type isa DataType || continue
            push!(lines, "supertype\t$(label)\t$(supertype(type))")
            push!(lines, "parameters\t$(label)\t$(length(type.parameters))")
            isabstracttype(type) || foreach(field -> push!(lines, "field\t$(label)\t$(field)"), fieldnames(type))
        else
            push!(lines, "constant\t$(label)")
        end
    end
    return lines
end

resolve(label) = foldl((value, part) -> getfield(value, Symbol(part)), split(label, '.')[2:end]; init = PACKAGE)

# Whether the method of `label` with argument types `text` still applies, with `keyword` if given.
function provided(label, text, keyword = nothing)
    f = try
        resolve(label)
    catch
        return false
    end
    types = try
        Core.eval(Main, Meta.parse("Tuple{$(text)}"))
    catch
        nothing
    end
    if types === nothing
        # Types that this version can't express, such as those with type variables, are compared as text.
        return any(method -> signature(method) == text, methods(f))
    end
    keyword === nothing && return hasmethod(f, types)
    # A method that takes any keywords, `options...`, takes every keyword.
    name = endswith(keyword, "...") ? :__any_keyword_of_the_checks__ : Symbol(keyword)
    return hasmethod(f, types, (name,))
end

function missing_entries(lines)
    current = Set(listing!(String[], PACKAGE, string(NAME)))
    removed = String[]
    for line in lines
        line in current && continue
        fields = split(line, '\t')
        kind = fields[1]
        if kind == "method"
            provided(fields[2], fields[3]) || push!(removed, line)
        elseif kind == "keyword"
            provided(fields[2], fields[3], fields[4]) || push!(removed, line)
        else
            push!(removed, line)
        end
    end
    return removed
end

if length(ARGS) == 2
    foreach(println, listing!(String[], PACKAGE, string(NAME)))
else
    foreach(println, missing_entries(readlines(ARGS[3])))
end
