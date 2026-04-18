# experiment/workflow.jl — scaffolding & indexing for EXP-NNN narratives
#
# This module owns the "infrastructure" layer of DataVault-backed
# experiment workflow (as opposed to the "provenance" layer in
# reporting/report.jl and the "narrative" layer written by the human).
#
# Public API:
#   * new_experiment(vault; slug, purpose, hypothesis, experiments_root, id)
#       → scaffold a `EXP-<id>-<slug>/README.md` from the embedded TEMPLATE
#   * build_narrative_index(experiments_root; output)
#       → list every EXP-*/README.md as a markdown table
#   * experiment_template() → String
#       → return the raw TEMPLATE for callers that want their own renderer
#
# The TEMPLATE lives next to this file as TEMPLATE.md and is read lazily
# so edits during development are picked up without recompile.

const _TEMPLATE_FILE = joinpath(@__DIR__, "TEMPLATE.md")

# ── template access ─────────────────────────────────────────────────────────

"""
    experiment_template() -> String

Return the canonical `EXP-NNN/README.md` template shipped with DataVault.

The template uses `{{name}}` placeholders (`id`, `slug`, `purpose`,
`hypothesis`, `hypothesis_ref`, `author`, `today`) that
[`new_experiment`](@ref) interpolates.  The header is a YAML front-matter
block delimited by `---` lines — [`build_narrative_index`](@ref) parses
it back out.
"""
function experiment_template()::String
    read(_TEMPLATE_FILE, String)
end

function _render_template(; id, slug, purpose, hypothesis, hypothesis_ref, author, today)
    tpl = experiment_template()
    substitutions = (
        "{{id}}" => id,
        "{{slug}}" => slug,
        "{{purpose}}" => purpose,
        "{{hypothesis}}" => hypothesis,
        "{{hypothesis_ref}}" => hypothesis_ref,
        "{{author}}" => author,
        "{{today}}" => today,
    )
    for (from, to) in substitutions
        tpl = replace(tpl, from => to)
    end
    return tpl
end

# ── new_experiment ──────────────────────────────────────────────────────────

"""
    new_experiment(vault::Vault;
                   slug::AbstractString,
                   purpose::AbstractString = "",
                   hypothesis::AbstractString = "",
                   hypothesis_ref::AbstractString = "",
                   author::AbstractString = _git_user_name(),
                   experiments_root::Union{Nothing,AbstractString} = nothing,
                   id::Union{Nothing,AbstractString,Integer} = nothing)
        -> String

Scaffold `experiments_root/EXP-<id>-<slug>/README.md` from the DataVault
TEMPLATE.  Returns the absolute path of the written README.

Behaviour:

- `experiments_root` defaults to a sibling `experiments/` dir of the
  caller's package root: `pkgdir(...)` is discovered from `vault.config_path`
  if available (see [`_default_experiments_root`](@ref)).  Override when
  the caller's layout differs.
- `id` is:
    - an `AbstractString` → used verbatim (e.g. `"001"`, `"20260418"`)
    - an `Integer` → zero-padded to 3 digits
    - `nothing` → auto-increment from existing `EXP-NNN-*` siblings
- Aborts with an error if `experiments_root/EXP-<id>-<slug>` already
  exists (pre-existing experiments must not be silently overwritten).
- Does **not** run DMRG / TDVP / anything compute-heavy — purely a doc
  scaffold that an editor can open immediately.
"""
function new_experiment(
    vault::Vault;
    slug::AbstractString,
    purpose::AbstractString="",
    hypothesis::AbstractString="",
    hypothesis_ref::AbstractString="",
    author::AbstractString=_git_user_name(),
    experiments_root::Union{Nothing,AbstractString}=nothing,
    id::Union{Nothing,AbstractString,Integer}=nothing,
)::String
    root = if experiments_root === nothing
        _default_experiments_root(vault)
    else
        String(experiments_root)
    end
    isempty(slug) && error("new_experiment: slug must be non-empty")
    # Allow filesystem-safe slugs only (letters, digits, dash, underscore).
    all(c -> isletter(c) || isdigit(c) || c in ('-', '_'), slug) || error(
        "new_experiment: slug must be kebab-case / snake_case ([a-zA-Z0-9_-]); got $slug",
    )

    mkpath(root)
    id_str = _resolve_id(root, id)
    exp_dir = joinpath(root, "EXP-$(id_str)-$(slug)")
    isdir(exp_dir) && error("new_experiment: directory already exists — $exp_dir")
    mkpath(exp_dir)

    today = Dates.format(Dates.today(), "yyyy-mm-dd")
    body = _render_template(;
        id=id_str,
        slug=slug,
        purpose=purpose,
        hypothesis=hypothesis,
        hypothesis_ref=hypothesis_ref,
        author=author,
        today=today,
    )
    readme = joinpath(exp_dir, "README.md")
    write(readme, body)
    return readme
end

"""
    _default_experiments_root(vault::Vault) -> String

Heuristic: for a vault attached to `<pkg_root>/projects/<P>/configs/<run>.toml`,
return `<pkg_root>/projects/<P>/experiments`.  Falls back to
`dirname(vault.config_path)/../experiments` when the layout does not match.
"""
function _default_experiments_root(vault::Vault)::String
    cfg = vault.config_path
    cfg_dir = dirname(cfg)
    # Typical case: .../projects/<P>/configs/<run>.toml → .../projects/<P>/experiments
    if basename(cfg_dir) == "configs"
        return joinpath(dirname(cfg_dir), "experiments")
    end
    # Fallback: a sibling experiments/ next to the config file.
    return joinpath(cfg_dir, "experiments")
end

function _resolve_id(root::AbstractString, id)::String
    if id isa AbstractString
        return String(id)
    elseif id isa Integer
        return lpad(Int(id), 3, '0')
    end
    # Auto-increment.  Inspect existing `EXP-NNN-*` directories.
    max_id = 0
    if isdir(root)
        for entry in readdir(root)
            m = match(r"^EXP-(\d+)-", entry)
            m === nothing && continue
            try
                n = parse(Int, m.captures[1])
                n > max_id && (max_id = n)
            catch
            end
        end
    end
    return lpad(max_id + 1, 3, '0')
end

function _git_user_name()::String
    try
        return strip(read(pipeline(`git config user.name`; stderr=devnull), String))
    catch
        return ""
    end
end

# ── front-matter parser ────────────────────────────────────────────────────

"""
    _parse_front_matter(text::AbstractString) -> (Dict{String,Any}, String)

Parse the `---`-delimited YAML-ish front-matter block at the top of a
markdown file.  Returns the parsed header dict and the body (everything
after the closing `---`).  When no front-matter is present returns
`(Dict(), text)`.

Supports:
- scalar values (`status: planning`)
- quoted strings (`slug: "foo-bar"`)
- inline list values (`data_runs: [smoke, phase1]`)

Not a full YAML parser — deliberately minimal so DataVault does not grow
a `YAML.jl` dep.
"""
function _parse_front_matter(text::AbstractString)
    lines = split(text, '\n')
    isempty(lines) && return (Dict{String,Any}(), String(text))
    first_line = strip(first(lines))
    first_line == "---" || return (Dict{String,Any}(), String(text))

    header = Dict{String,Any}()
    body_start = length(lines) + 1
    for (i, line) in enumerate(lines[2:end])
        sline = strip(line)
        if sline == "---"
            body_start = i + 2
            break
        end
        idx = findfirst(':', sline)
        idx === nothing && continue
        key = strip(sline[1:(idx - 1)])
        raw = strip(sline[(idx + 1):end])
        header[String(key)] = _parse_front_matter_value(raw)
    end
    body = join(lines[body_start:end], '\n')
    return (header, String(body))
end

function _parse_front_matter_value(raw::AbstractString)
    isempty(raw) && return ""
    # Inline list: `[a, b, c]`
    if startswith(raw, "[") && endswith(raw, "]")
        inner = strip(raw[2:(end - 1)])
        isempty(inner) && return String[]
        return [String(strip(strip(x), '"')) for x in split(inner, ",")]
    end
    # Quoted scalar
    if (startswith(raw, '"') && endswith(raw, '"')) ||
        (startswith(raw, '\'') && endswith(raw, '\''))
        return String(raw[2:(end - 1)])
    end
    return String(raw)
end

# ── build_narrative_index ──────────────────────────────────────────────────

"""
    build_narrative_index(experiments_root::AbstractString;
                          output::AbstractString = joinpath(experiments_root, "INDEX.md"))
        -> String

Scan `experiments_root/EXP-*-*/README.md`, parse each file's
front-matter, and write a markdown table of experiments ordered by
numeric ID.  Complementary to
[`build_experiments_index`](@ref) (which lists `out/data/<P>/<run>/`
provenance records).

Columns: `ID`, `Slug`, `Status`, `Started`, `Hypothesis ref`, `Data runs`.

Returns the absolute path of the written INDEX.
"""
function build_narrative_index(
    experiments_root::AbstractString;
    output::AbstractString=joinpath(experiments_root, "INDEX.md"),
)::String
    isdir(experiments_root) ||
        error("build_narrative_index: experiments_root not found — $experiments_root")

    rows = Vector{NamedTuple}()
    for entry in sort!(readdir(experiments_root))
        m = match(r"^EXP-(\d+)-(.+)$", entry)
        m === nothing && continue
        exp_dir = joinpath(experiments_root, entry)
        isdir(exp_dir) || continue
        readme = joinpath(exp_dir, "README.md")
        isfile(readme) || continue

        id = m.captures[1]
        slug_fallback = m.captures[2]
        header, _ = _parse_front_matter(read(readme, String))
        slug = String(get(header, "slug", slug_fallback))
        status = String(get(header, "status", ""))
        started = String(get(header, "started", ""))
        hyp = String(get(header, "hypothesis_ref", ""))
        runs_raw = get(header, "data_runs", String[])
        runs =
            runs_raw isa AbstractVector ? [String(r) for r in runs_raw] : [String(runs_raw)]
        push!(rows, (; id, slug, status, started, hyp, runs, entry))
    end
    sort!(rows; by=r -> r.id)

    io = IOBuffer()
    ts = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    println(io, "# Experiment narrative index")
    println(io)
    println(io, "_Auto-generated by `DataVault.build_narrative_index` on ", ts, "_")
    println(io)
    println(io, "| ID | Slug | Status | Started | Hypothesis | Data runs |")
    println(io, "|----|------|--------|---------|------------|-----------|")
    for r in rows
        runs_cell = isempty(r.runs) ? "" : join(r.runs, ", ")
        println(
            io,
            "| EXP-",
            r.id,
            " | [",
            r.slug,
            "](",
            r.entry,
            "/README.md) | ",
            r.status,
            " | ",
            r.started,
            " | ",
            r.hyp,
            " | ",
            runs_cell,
            " |",
        )
    end
    mkpath(dirname(output))
    write(output, String(take!(io)))
    return output
end

# ── provenance back-link (used by build_experiment_report) ─────────────────

"""
    _inject_provenance_block!(readme_path, provenance_md)

Rewrite the `## Generated provenance` section of an EXP-NNN README with
`provenance_md` (pure markdown).  Idempotent: the block is detected by
its heading and replaced in place; surrounding narrative is untouched.
Noop if the file lacks a `## Generated provenance` heading.
"""
function _inject_provenance_block!(
    readme_path::AbstractString, provenance_md::AbstractString
)
    isfile(readme_path) || return nothing
    text = read(readme_path, String)
    m = match(r"(?m)^##\s+Generated provenance\s*$", text)
    m === nothing && return nothing
    # Find end of the section: the next `## ` heading, or end-of-file.
    after = m.offset + length(m.match)
    tail = text[after:end]
    next_heading = match(r"(?m)^##\s+\w"a, tail)
    end_idx = next_heading === nothing ? lastindex(text) : (after + next_heading.offset - 1)

    new_text = string(
        text[1:(m.offset - 1)],
        "## Generated provenance\n",
        "\n",
        "<!-- Maintained by DataVault.build_experiment_report.  Do not edit by hand. -->\n",
        "\n",
        provenance_md,
        "\n",
        next_heading === nothing ? "" : text[end_idx:end],
    )
    write(readme_path, new_text)
    return nothing
end

"""
    _update_data_runs!(readme_path, run_entry::AbstractString)

Append `run_entry` to the `data_runs:` list in the README's front-matter
(idempotent — no duplicate inserts).  Noop when there is no
front-matter or no `data_runs` field.
"""
function _update_data_runs!(readme_path::AbstractString, run_entry::AbstractString)
    isfile(readme_path) || return nothing
    text = read(readme_path, String)
    header, body = _parse_front_matter(text)
    isempty(header) && return nothing
    runs = get(header, "data_runs", String[])
    runs_vec = runs isa AbstractVector ? [String(r) for r in runs] : String[]
    run_entry in runs_vec && return nothing
    push!(runs_vec, run_entry)
    header["data_runs"] = runs_vec
    _write_front_matter!(readme_path, header, body)
    return nothing
end

function _write_front_matter!(
    path::AbstractString, header::AbstractDict, body::AbstractString
)
    # Emit keys in a stable order if they appear in the canonical list.
    canonical_order = [
        "id", "slug", "status", "author", "started", "hypothesis_ref", "data_runs"
    ]
    io = IOBuffer()
    println(io, "---")
    seen = Set{String}()
    for k in canonical_order
        haskey(header, k) || continue
        push!(seen, k)
        _emit_front_matter_kv(io, k, header[k])
    end
    for (k, v) in header
        k in seen && continue
        _emit_front_matter_kv(io, k, v)
    end
    println(io, "---")
    println(io)
    write(path, string(String(take!(io)), body))
end

function _emit_front_matter_kv(io::IO, key::AbstractString, value)
    if value isa AbstractVector
        print(io, key, ": [")
        for (i, v) in enumerate(value)
            i == 1 || print(io, ", ")
            print(io, v)
        end
        println(io, "]")
    else
        println(io, key, ": \"", value, "\"")
    end
end
