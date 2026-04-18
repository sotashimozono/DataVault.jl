# reporting/report.jl — experiment report + schema versioning
#
# A single (project, run) gets:
#
#   outdir/data/<project>/<run>/README.md    — machine-generated markdown
#   outdir/data/<project>/<run>/schema.toml  — writer provenance + data schema
#   outdir/data/<project>/INDEX.md           — one row per run
#
# The caller passes only `vault` plus the writer `Module` for schema
# introspection; all other provenance (package name, version, project root,
# DATA_SCHEMA_VERSION) is pulled from the module itself.

# ── writer introspection ─────────────────────────────────────────────────────

struct _WriterInfo
    name::String
    version::String
    root::String
    data_schema_version::Int  # 0 means "not declared"
end

function _introspect_writer(
    writer::Module,
    data_schema_version_kwarg::Union{Nothing,Integer},
)::_WriterInfo
    name = String(nameof(writer))

    raw_ver = try
        pkgversion(writer)
    catch
        nothing
    end
    version = raw_ver === nothing ? "unknown" : string(raw_ver)

    raw_root = try
        pkgdir(writer)
    catch
        nothing
    end
    root = raw_root === nothing ? "" : string(raw_root)

    dsv = if data_schema_version_kwarg !== nothing
        Int(data_schema_version_kwarg)
    elseif isdefined(writer, :DATA_SCHEMA_VERSION)
        val = Base.invokelatest(getglobal, writer, :DATA_SCHEMA_VERSION)
        val isa Integer ? Int(val) :
        (@warn "writer $name.DATA_SCHEMA_VERSION is not an Integer" value=val; 0)
    else
        0
    end

    _WriterInfo(name, version, root, dsv)
end

# ── code versions (git hashes) ──────────────────────────────────────────────

"""
    gather_code_versions(project_root) -> Dict{String,String}

Collect `git rev-parse --short HEAD` for `project_root` and every
`submodules/*/` directory underneath.  The parent entry is keyed `"parent"`;
submodule entries use their directory name.

Never throws: directories that are not git checkouts (or lookups that fail)
yield an empty-string hash.
"""
function gather_code_versions(project_root::AbstractString)::Dict{String,String}
    result = Dict{String,String}()
    result["parent"] = _safe_git_hash(project_root)
    submod_dir = joinpath(project_root, "submodules")
    if isdir(submod_dir)
        for entry in sort!(readdir(submod_dir))
            full = joinpath(submod_dir, entry)
            isdir(full) || continue
            result[entry] = _safe_git_hash(full)
        end
    end
    result
end

function _safe_git_hash(dir::AbstractString)::String
    isdir(dir) || return ""
    try
        return strip(
            read(pipeline(`git -C $dir rev-parse --short HEAD`; stderr=devnull), String)
        )
    catch
        return ""
    end
end

# ── JLD2 schema introspection ───────────────────────────────────────────────

"""
    _introspect_schema_keys(vault) -> (top_keys::Vector{String},
                                       bench_keys::Vector{String})

Open the first completed sample JLD2 under the run directory and collect its
top-level keys plus `bench` subkeys (empty if absent).  Returns two empty
vectors when no JLD2 is present yet.
"""
function _introspect_schema_keys(vault::Vault)
    jld_path = _first_sample_jld2(vault)
    jld_path === nothing && return (String[], String[])
    top = String[]
    bench = String[]
    try
        jldopen(jld_path, "r") do f
            for k in Base.keys(f)
                push!(top, string(k))
            end
            if "bench" in top
                b = f["bench"]
                if b isa AbstractDict
                    for k in Base.keys(b)
                        push!(bench, string(k))
                    end
                end
            end
        end
    catch e
        @warn "schema introspection failed" file=jld_path exception=e
    end
    sort!(top); sort!(bench)
    (top, bench)
end

function _first_sample_jld2(vault::Vault)::Union{Nothing,String}
    run_dir = _run_data_dir(vault)
    isdir(run_dir) || return nothing
    for (root, _, files) in walkdir(run_dir)
        for f in files
            endswith(f, ".jld2") || continue
            startswith(f, "data_sample") || continue
            return joinpath(root, f)
        end
    end
    nothing
end

# ── schema.toml writer (first-write-only) ───────────────────────────────────

const _SCHEMA_FILENAME = "schema.toml"

function _schema_path(vault::Vault)::String
    joinpath(_run_data_dir(vault), _SCHEMA_FILENAME)
end

function _build_schema_payload(
    writer::_WriterInfo,
    code_versions::Dict{String,String},
    top_keys::Vector{String},
    bench_keys::Vector{String},
)::Dict{String,Any}
    submod = Dict{String,Any}()
    parent_hash = ""
    for (k, v) in code_versions
        if k == "parent"
            parent_hash = v
        else
            submod[k] = v
        end
    end
    Dict{String,Any}(
        "writer" => Dict{String,Any}(
            "package" => writer.name,
            "package_version" => writer.version,
            "package_root" => writer.root,
            "parent_git_hash" => parent_hash,
            "submodule_git_hashes" => submod,
        ),
        "datavault" => Dict{String,Any}(
            "version" => _datavault_pkg_version(),
        ),
        "schema" => Dict{String,Any}(
            "data_schema_version" => writer.data_schema_version,
            "top_level_keys" => top_keys,
            "bench_keys" => bench_keys,
        ),
        "created" => Dict{String,Any}(
            "at" => Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"),
            "hostname" => gethostname(),
        ),
    )
end

"""
    _write_schema_toml(vault, writer, code_versions, top_keys, bench_keys) -> String

Write `schema.toml` the first time it is called for this run.  Subsequent
calls compare writer identity (package + version + data_schema_version) to
the existing record:

- identity unchanged → no-op, return existing path
- identity changed   → emit a warning and write `schema.toml.vN` (N ≥ 2)
                       next to the original, preserving the original

Schema.toml is thus **append-only**: the initial one is never overwritten,
but evolving writers can still leave a trail.
"""
function _write_schema_toml(
    vault::Vault,
    writer::_WriterInfo,
    code_versions::Dict{String,String},
    top_keys::Vector{String},
    bench_keys::Vector{String},
)::String
    path = _schema_path(vault)
    mkpath(dirname(path))
    payload = _build_schema_payload(writer, code_versions, top_keys, bench_keys)

    if !isfile(path)
        _atomic_toml_write(path, payload)
        return path
    end

    existing = try
        TOML.parsefile(path)
    catch
        nothing
    end
    if existing !== nothing && _writer_identity_matches(existing, payload)
        return path
    end

    # Identity differs → spill to schema.toml.vN
    n = 2
    alt = path * ".v$n"
    while isfile(alt)
        n += 1
        alt = path * ".v$n"
    end
    @warn "writer identity changed since initial schema — appending new record" current=alt
    _atomic_toml_write(alt, payload)
    alt
end

function _writer_identity_matches(existing::AbstractDict, candidate::AbstractDict)::Bool
    ew = get(existing, "writer", Dict{String,Any}())
    cw = get(candidate, "writer", Dict{String,Any}())
    es = get(existing, "schema", Dict{String,Any}())
    cs = get(candidate, "schema", Dict{String,Any}())
    get(ew, "package", nothing) == get(cw, "package", nothing) &&
        get(ew, "package_version", nothing) == get(cw, "package_version", nothing) &&
        get(es, "data_schema_version", nothing) == get(cs, "data_schema_version", nothing)
end

# ── events_*.jsonl timing ───────────────────────────────────────────────────

struct _TimingSummary
    masters::Int
    key_done::Int
    first_start::String
    last_done::String
    seconds::Vector{Float64}
    longest::Vector{Tuple{String,Float64}}
end

function _parse_events_jsonl(outdir::AbstractString)::Union{Nothing,_TimingSummary}
    files = String[]
    for f in readdir(outdir)
        startswith(f, "events_") && endswith(f, ".jsonl") &&
            push!(files, joinpath(outdir, f))
    end
    isempty(files) && return nothing

    key_done = 0
    first_start = ""
    last_done = ""
    seconds = Float64[]
    per_key = Dict{String,Float64}()

    for path in files
        for line in eachline(path)
            s = strip(line)
            isempty(s) && continue
            ev = try
                JSON3.read(s)
            catch
                continue
            end
            kind = String(get(ev, :kind, ""))
            ts = String(get(ev, :ts, ""))
            if kind == "key_start"
                if isempty(first_start) || ts < first_start
                    first_start = ts
                end
            elseif kind == "key_done"
                key_done += 1
                if isempty(last_done) || ts > last_done
                    last_done = ts
                end
                secs = get(ev, :secs, nothing)
                if secs isa Real
                    push!(seconds, Float64(secs))
                    kstr = String(get(ev, :key, ""))
                    per_key[kstr] = max(get(per_key, kstr, 0.0), Float64(secs))
                end
            end
        end
    end

    sorted_pairs = sort!(collect(per_key); by=p -> -p.second)
    longest = [(p.first, p.second) for p in sorted_pairs[1:min(5, end)]]
    _TimingSummary(length(files), key_done, first_start, last_done, seconds, longest)
end

# ── config / progress / figures helpers ─────────────────────────────────────

function _format_config_summary(snapshot_path::AbstractString)::String
    isfile(snapshot_path) || return "_(no config snapshot found)_\n"
    raw = try
        TOML.parsefile(snapshot_path)
    catch e
        return "_(failed to parse snapshot: $e)_\n"
    end
    io = IOBuffer()
    study = get(raw, "study", Dict())
    dv = get(raw, "datavault", Dict())
    println(io, "- study.project_name: ", get(study, "project_name", ""))
    println(io, "- study.total_samples: ", get(study, "total_samples", ""))
    pk = get(dv, "path_keys", nothing)
    if pk !== nothing
        println(io, "- datavault.path_keys: ", pk)
    end
    paramsets = get(raw, "paramsets", nothing)
    if paramsets isa AbstractVector && !isempty(paramsets)
        println(io, "- paramsets (", length(paramsets), " block(s)):")
        for (i, ps) in enumerate(paramsets)
            ps isa AbstractDict || continue
            for (ns, kv) in ps
                if kv isa AbstractDict
                    for (k, v) in kv
                        println(io, "  - [", i, "] ", ns, ".", k, ": ", v)
                    end
                else
                    println(io, "  - [", i, "] ", ns, ": ", kv)
                end
            end
        end
    end
    String(take!(io))
end

struct _LedgerProgress
    completed::Int
    header::Vector{String}
    path_key_breakdown::Vector{Pair{String,Int}}
end

function _ledger_progress(csv_path::AbstractString, path_keys::Vector{String})::_LedgerProgress
    isfile(csv_path) || return _LedgerProgress(0, String[], Pair{String,Int}[])
    lines = readlines(csv_path)
    isempty(lines) && return _LedgerProgress(0, String[], Pair{String,Int}[])
    header = split(lines[1], ",")
    data_lines = length(lines) > 1 ? lines[2:end] : String[]
    data_lines = filter(!isempty, data_lines)

    # Breakdown by path_keys combo
    idxs = Int[]
    for pk in path_keys
        i = findfirst(==(pk), header)
        i !== nothing && push!(idxs, i)
    end
    counts = Dict{String,Int}()
    for line in data_lines
        cols = split(line, ",")
        length(cols) < maximum(idxs; init=0) && continue
        combo = join((cols[i] for i in idxs), " / ")
        counts[combo] = get(counts, combo, 0) + 1
    end
    breakdown = sort!(collect(counts); by=p -> -p.second)
    _LedgerProgress(length(data_lines), String.(header), breakdown)
end

function _expected_total(spec)::Int
    try
        return length(ParamIO.expand(spec))
    catch
        return 0
    end
end

function _collect_figures(outdir::AbstractString, project::AbstractString, run::AbstractString)
    fig_dir = joinpath(outdir, "figure", project, run)
    isdir(fig_dir) || return String[]
    out = String[]
    for (root, _, files) in walkdir(fig_dir)
        # skip archive/ subtree
        if occursin(joinpath("figure", project, run, "archive"), root)
            continue
        end
        for f in files
            endswith(lowercase(f), ".pdf") || continue
            push!(out, relpath(joinpath(root, f), _run_data_dir_abs(outdir, project, run)))
        end
    end
    sort!(out)
end

function _run_data_dir_abs(outdir::AbstractString, project::AbstractString, run::AbstractString)::String
    joinpath(outdir, "data", project, run)
end

# ── README.md renderer ──────────────────────────────────────────────────────

function _render_report(
    vault::Vault,
    writer::_WriterInfo,
    code_versions::Dict{String,String},
    top_keys::Vector{String},
    bench_keys::Vector{String},
    progress::_LedgerProgress,
    expected::Int,
    timing::Union{Nothing,_TimingSummary},
    figures::Vector{String},
    schema_path::String,
)::String
    io = IOBuffer()
    project = vault.spec.study.project_name
    run = vault.run
    ts = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")

    println(io, "# Run: ", run, "   (", project, ")")
    println(io)
    println(io, "_Auto-generated by DataVault.build_experiment_report on ", ts, "_")
    println(io)

    println(io, "## Identity")
    println(io, "- **project**:  ", project)
    println(io, "- **run**:      ", run)
    println(io, "- **outdir**:   ", vault.outdir)
    println(io, "- **config**:   ", vault.config_path)
    println(io)

    println(io, "## Code versions")
    println(io, "| component | commit | path |")
    println(io, "|-----------|--------|------|")
    parent_hash = get(code_versions, "parent", "")
    println(io, "| parent    | `", parent_hash, "` | `.` |")
    for (k, v) in sort!(collect(code_versions); by=first)
        k == "parent" && continue
        println(io, "| ", k, " | `", v, "` | `submodules/", k, "` |")
    end
    println(io)

    println(io, "## Config")
    snap_path = joinpath(_run_data_dir(vault), "config_snapshot.toml")
    println(io, "Snapshot: [`config_snapshot.toml`](./config_snapshot.toml)")
    println(io)
    print(io, _format_config_summary(snap_path))
    println(io)

    println(io, "## Progress")
    remaining = max(expected - progress.completed, 0)
    pct = expected > 0 ? round(100 * progress.completed / expected; digits=1) : 0.0
    println(io, "- Expected keys: **", expected, "**")
    println(io, "- Completed:    **", progress.completed, "**")
    println(io, "- Remaining:    ", remaining, "  (", pct, "% done)")
    if !isempty(progress.path_key_breakdown)
        println(io)
        println(io, "### Breakdown by path_key")
        println(io, "| combo | count |")
        println(io, "|-------|-------|")
        for (combo, cnt) in progress.path_key_breakdown
            println(io, "| ", combo, " | ", cnt, " |")
        end
    end
    println(io)

    println(io, "## Timing  (events_*.jsonl)")
    if timing === nothing
        println(io, "_(no events_*.jsonl found under outdir)_")
    else
        println(io, "- Masters: ", timing.masters)
        println(io, "- key_done events: ", timing.key_done)
        if !isempty(timing.seconds)
            μ = sum(timing.seconds) / length(timing.seconds)
            sorted = sort(timing.seconds)
            ν = sorted[div(end + 1, 2)]
            M = maximum(timing.seconds)
            println(io, "- Per-key seconds: mean ", round(μ; digits=2),
                    ", median ", round(ν; digits=2), ", max ", round(M; digits=2))
        end
        !isempty(timing.first_start) && println(io, "- First key_start: ", timing.first_start)
        !isempty(timing.last_done) && println(io, "- Last  key_done:  ", timing.last_done)
        if !isempty(timing.longest)
            println(io)
            println(io, "### Longest keys")
            for (k, s) in timing.longest
                println(io, "- `", k, "` — ", round(s; digits=2), " s")
            end
        end
    end
    println(io)

    println(io, "## Figures")
    if isempty(figures)
        println(io, "_(no PDFs under outdir/figure/", project, "/", run, "/)_")
    else
        for f in figures
            name = basename(f)
            println(io, "- [", name, "](", f, ")")
        end
    end
    println(io)

    println(io, "## Schema")
    println(io, "- writer: **", writer.name, "** v", writer.version)
    println(io, "- data_schema_version: **", writer.data_schema_version, "**")
    if isempty(top_keys)
        println(io, "- top_level_keys: _(no sample JLD2 discovered yet)_")
    else
        println(io, "- top_level_keys: `", join(top_keys, ", "), "`")
    end
    if !isempty(bench_keys)
        println(io, "- bench_keys: `", join(bench_keys, ", "), "`")
    end
    println(io, "- record: [`", basename(schema_path), "`](./", basename(schema_path), ")")
    println(io)

    String(take!(io))
end

# ── public API: build_experiment_report ─────────────────────────────────────

"""
    build_experiment_report(vault::Vault, writer::Module;
                            project_root::Union{Nothing,AbstractString}=nothing,
                            data_schema_version::Union{Nothing,Integer}=nothing,
                            output_name::AbstractString="README.md") -> String

Generate a machine-readable `README.md` + `schema.toml` pair for the run at
`outdir/data/<project>/<run>/`, summarising identity, code versions, config,
ledger progress, event timings, figures, and data schema.

`writer` is the caller's top-level module (e.g. `ThermalEquilibrium`).
Package name, version, package root, and `DATA_SCHEMA_VERSION` (if declared
as a module constant) are extracted via Julia reflection — no explicit
kwargs are required in the common case.

- `project_root` defaults to `pkgdir(writer)` (used for git introspection).
- `data_schema_version` overrides any module constant.

The README is overwritten on every call (idempotent).  The schema.toml is
**append-only**: unchanged writers are a no-op, but a changed
(package, version, data_schema_version) triple emits a warning and spills
to `schema.toml.vN` so history is preserved.

Returns the absolute path of the written README.
"""
function build_experiment_report(
    vault::Vault,
    writer::Module;
    project_root::Union{Nothing,AbstractString}=nothing,
    data_schema_version::Union{Nothing,Integer}=nothing,
    output_name::AbstractString="README.md",
)::String
    winfo = _introspect_writer(writer, data_schema_version)

    root = if project_root !== nothing
        String(project_root)
    elseif !isempty(winfo.root)
        winfo.root
    else
        ""
    end

    code_versions = isempty(root) ? Dict{String,String}("parent" => "") :
                    gather_code_versions(root)

    top_keys, bench_keys = _introspect_schema_keys(vault)
    schema_path = _write_schema_toml(vault, winfo, code_versions, top_keys, bench_keys)

    csv_path = joinpath(_run_data_dir(vault), "ledger.csv")
    progress = _ledger_progress(csv_path, vault.spec.path_keys)
    expected = _expected_total(vault.spec)

    timing = _parse_events_jsonl(vault.outdir)
    figures = _collect_figures(vault.outdir, vault.spec.study.project_name, vault.run)

    md = _render_report(
        vault, winfo, code_versions, top_keys, bench_keys,
        progress, expected, timing, figures, schema_path,
    )

    out_path = joinpath(_run_data_dir(vault), output_name)
    mkpath(dirname(out_path))
    write(out_path, md)
    out_path
end

# ── build_experiments_index ─────────────────────────────────────────────────

"""
    build_experiments_index(outdir, project_name) -> String

Walk `outdir/data/<project_name>/` and write `INDEX.md` with one row per
run (linking to its README.md).  Columns: run, snapshot availability,
completed count, parent git hash (from schema.toml if present), latest
ledger activity.

Returns the absolute path of `INDEX.md`.
"""
function build_experiments_index(
    outdir::AbstractString,
    project_name::AbstractString,
)::String
    project_dir = joinpath(outdir, "data", project_name)
    index_path = joinpath(project_dir, "INDEX.md")
    mkpath(project_dir)

    rows = Vector{NamedTuple}()
    if isdir(project_dir)
        for entry in sort!(readdir(project_dir))
            full = joinpath(project_dir, entry)
            isdir(full) || continue
            run_name = entry
            snap = isfile(joinpath(full, "config_snapshot.toml")) ? "yes" : "no"
            csv = joinpath(full, "ledger.csv")
            completed = isfile(csv) ? max(length(readlines(csv)) - 1, 0) : 0
            schema = joinpath(full, "schema.toml")
            parent_hash = ""
            if isfile(schema)
                try
                    s = TOML.parsefile(schema)
                    parent_hash = get(get(s, "writer", Dict()), "parent_git_hash", "")
                catch
                end
            end
            latest = ""
            if isfile(csv)
                try
                    latest = Dates.format(
                        Dates.unix2datetime(mtime(csv)), "yyyy-mm-ddTHH:MM:SS"
                    )
                catch
                end
            end
            push!(rows, (; run=run_name, snap, completed, parent_hash, latest))
        end
    end

    io = IOBuffer()
    ts = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    println(io, "# ", project_name, " — run index")
    println(io)
    println(io, "_Auto-generated on ", ts, "_")
    println(io)
    println(io, "| Run | Snapshot | Completed | Parent git | Latest activity |")
    println(io, "|-----|----------|-----------|------------|-----------------|")
    for r in rows
        println(io, "| [", r.run, "](", r.run, "/README.md) | ", r.snap, " | ",
                r.completed, " | `", r.parent_hash, "` | ", r.latest, " |")
    end
    write(index_path, String(take!(io)))
    index_path
end

# ── schema reader + compat check ────────────────────────────────────────────

"""
    read_schema_record(vault) -> Union{NamedTuple,Nothing}

Parse `outdir/data/<project>/<run>/schema.toml` and return:

    (; package, package_version, package_root, parent_git_hash,
       submodule_git_hashes::Dict{String,String},
       data_schema_version::Int,
       top_level_keys::Vector{String},
       bench_keys::Vector{String},
       datavault_version::String,
       created_at::String,
       hostname::String)

Returns `nothing` for legacy runs (no schema.toml on disk).
"""
function read_schema_record(vault::Vault)
    path = _schema_path(vault)
    isfile(path) || return nothing
    raw = try
        TOML.parsefile(path)
    catch
        return nothing
    end
    w = get(raw, "writer", Dict())
    s = get(raw, "schema", Dict())
    d = get(raw, "datavault", Dict())
    c = get(raw, "created", Dict())
    submod = Dict{String,String}()
    for (k, v) in get(w, "submodule_git_hashes", Dict())
        submod[String(k)] = String(v)
    end
    (;
        package = String(get(w, "package", "")),
        package_version = String(get(w, "package_version", "")),
        package_root = String(get(w, "package_root", "")),
        parent_git_hash = String(get(w, "parent_git_hash", "")),
        submodule_git_hashes = submod,
        data_schema_version = Int(get(s, "data_schema_version", 0)),
        top_level_keys = String.(get(s, "top_level_keys", String[])),
        bench_keys = String.(get(s, "bench_keys", String[])),
        datavault_version = String(get(d, "version", "")),
        created_at = String(get(c, "at", "")),
        hostname = String(get(c, "hostname", "")),
    )
end

"""
    check_schema_compat(vault;
                        reader_package::AbstractString,
                        reader_min_writer_version::AbstractString="",
                        reader_expected_fields::Vector{String}=String[])
        -> NamedTuple

Inspect the run's `schema.toml` and return:

    (; ok::Bool, status::Symbol, missing_fields::Vector{String},
       extra_fields::Vector{String}, notes::String)

`status` values:

- `:legacy`   — no schema.toml (pre-0.5.0 run); `ok=false` (reader should
                use best-effort fallback).
- `:mismatch` — writer's `package_version` is lower than
                `reader_min_writer_version`, **or** the writer package name
                differs from `reader_package`; `ok=false`.
- `:partial`  — schema is present and the writer matches, but some
                `reader_expected_fields` are missing from the data; `ok=false`
                (reader may still proceed with a derive fallback).
- `:match`    — all checks passed; `ok=true`.
"""
function check_schema_compat(
    vault::Vault;
    reader_package::AbstractString,
    reader_min_writer_version::AbstractString="",
    reader_expected_fields::Vector{String}=String[],
)
    rec = read_schema_record(vault)
    if rec === nothing
        return (;
            ok = false,
            status = :legacy,
            missing_fields = String[],
            extra_fields = String[],
            notes = "no schema.toml (pre-0.5.0 run)",
        )
    end

    if rec.package != String(reader_package)
        return (;
            ok = false,
            status = :mismatch,
            missing_fields = String[],
            extra_fields = String[],
            notes = "writer package `$(rec.package)` ≠ reader_package `$reader_package`",
        )
    end

    if !isempty(reader_min_writer_version) &&
       _vcompare(rec.package_version, reader_min_writer_version) < 0
        return (;
            ok = false,
            status = :mismatch,
            missing_fields = String[],
            extra_fields = String[],
            notes = "writer version $(rec.package_version) < required $reader_min_writer_version",
        )
    end

    all_fields = unique(vcat(rec.top_level_keys, rec.bench_keys))
    missing = String[f for f in reader_expected_fields if !(f in all_fields)]
    extra = String[]

    if !isempty(missing)
        return (;
            ok = false,
            status = :partial,
            missing_fields = missing,
            extra_fields = extra,
            notes = "missing fields; reader may use derive fallback",
        )
    end

    (;
        ok = true,
        status = :match,
        missing_fields = String[],
        extra_fields = extra,
        notes = "ok",
    )
end

"""
    _vcompare(a, b) -> Int

Compare two version strings loosely.  Returns -1, 0, or 1.  Falls back to
lexicographic comparison when either string is not a valid `VersionNumber`.
"""
function _vcompare(a::AbstractString, b::AbstractString)::Int
    va = tryparse(VersionNumber, String(a))
    vb = tryparse(VersionNumber, String(b))
    if va !== nothing && vb !== nothing
        return va < vb ? -1 : va > vb ? 1 : 0
    end
    return cmp(String(a), String(b))
end
