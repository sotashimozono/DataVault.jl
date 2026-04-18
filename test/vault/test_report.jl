using Dates, TOML, JLD2

const FIXTURES_REPORT = joinpath(@__DIR__, "fixtures")
const CONFIG_REPORT = joinpath(FIXTURES_REPORT, "study.toml")

# Build a named dummy writer module.  `pkgversion(m)` returns `nothing` for
# modules that are not part of a registered package, so `_introspect_writer`
# stamps "unknown" and relies on the caller-supplied `data_schema_version`
# kwarg.  That is exactly what we want to exercise here.
function _dummy_writer(name::Symbol)
    m = Module(name, false)
    Core.eval(m, :(const DATA_SCHEMA_VERSION = 7))
    m
end

function with_report_vault(f)
    outdir = mktempdir()
    try
        vault = Vault(CONFIG_REPORT; outdir=outdir, run="r1")
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ── build_experiment_report ─────────────────────────────────────────────────

@testset "build_experiment_report: writes README.md + schema.toml" begin
    with_report_vault() do vault, outdir
        writer = _dummy_writer(:FakeWriter)

        # Plant one completed sample JLD2 so schema introspection has keys.
        key = DataVault.keys(vault)[1]
        DataVault.save!(
            vault,
            key,
            Dict("bench" => Dict("betas" => [0.0, 0.5], "energy_raw" => [1.0, 2.0])),
        )
        mark_done!(vault, key)
        build_ledger(vault)

        readme = build_experiment_report(vault, writer)

        @test isfile(readme)
        content = read(readme, String)
        for section in [
            "## Identity",
            "## Code versions",
            "## Config",
            "## Progress",
            "## Timing",
            "## Figures",
            "## Schema",
        ]
            @test occursin(section, content)
        end
        # Writer reflection worked
        @test occursin("FakeWriter", content)
        @test occursin("data_schema_version: **7**", content)

        schema_path = joinpath(outdir, "data", "test_study", "r1", "schema.toml")
        @test isfile(schema_path)
        s = TOML.parsefile(schema_path)
        @test s["writer"]["package"] == "FakeWriter"
        @test s["schema"]["data_schema_version"] == 7
        # bench introspection from JLD2 picked up "betas" and "energy_raw"
        bench_keys = s["schema"]["bench_keys"]
        @test "betas" in bench_keys
        @test "energy_raw" in bench_keys
    end
end

@testset "build_experiment_report: idempotent on repeat call" begin
    with_report_vault() do vault, outdir
        writer = _dummy_writer(:FakeWriter)
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict("bench" => Dict("x" => [1])))
        mark_done!(vault, key)
        build_ledger(vault)

        p1 = build_experiment_report(vault, writer)
        sleep(1.1)  # ensure any timestamp difference is flushed if present
        p2 = build_experiment_report(vault, writer)

        @test p1 == p2
        # README is auto-timestamped so it DOES change between calls.  The
        # invariant we care about is that `schema.toml` is NOT overwritten
        # across repeat calls with the same writer identity.
        schema_path = joinpath(outdir, "data", "test_study", "r1", "schema.toml")
        original = read(schema_path)
        build_experiment_report(vault, writer)
        @test read(schema_path) == original
    end
end

@testset "build_experiment_report: warns + spills schema.toml.vN when writer changes" begin
    with_report_vault() do vault, outdir
        w1 = _dummy_writer(:FakeWriterA)
        w2 = _dummy_writer(:FakeWriterB)

        build_experiment_report(vault, w1)
        base = joinpath(outdir, "data", "test_study", "r1", "schema.toml")
        @test isfile(base)

        @test_logs (:warn, r"writer identity changed") build_experiment_report(vault, w2)
        @test isfile(base * ".v2")
    end
end

# ── schema reader + compat check ────────────────────────────────────────────

@testset "read_schema_record: parses schema.toml" begin
    with_report_vault() do vault, _
        writer = _dummy_writer(:FakeWriter)
        # Explicit override to pin the data_schema_version independent of const.
        build_experiment_report(vault, writer; data_schema_version=3)

        rec = read_schema_record(vault)
        @test rec !== nothing
        @test rec.package == "FakeWriter"
        @test rec.data_schema_version == 3
    end
end

@testset "read_schema_record: returns nothing for legacy run" begin
    with_report_vault() do vault, _
        @test read_schema_record(vault) === nothing
    end
end

@testset "check_schema_compat: four statuses" begin
    with_report_vault() do vault, _
        # :legacy
        r = check_schema_compat(
            vault; reader_package="FakeWriter", reader_min_writer_version="0.1.0"
        )
        @test r.status == :legacy
        @test r.ok == false

        writer = _dummy_writer(:FakeWriter)
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict("bench" => Dict("betas" => [0.0])))
        mark_done!(vault, key)
        build_experiment_report(vault, writer; data_schema_version=3)

        # :mismatch (package name differs)
        r = check_schema_compat(
            vault; reader_package="OtherPkg", reader_min_writer_version="0.1.0"
        )
        @test r.status == :mismatch

        # :partial (expected field missing)
        r = check_schema_compat(
            vault;
            reader_package="FakeWriter",
            reader_min_writer_version="",
            reader_expected_fields=["nonexistent_field"],
        )
        @test r.status == :partial
        @test "nonexistent_field" in r.missing_fields

        # :match
        r = check_schema_compat(
            vault;
            reader_package="FakeWriter",
            reader_min_writer_version="",
            reader_expected_fields=["betas"],
        )
        @test r.status == :match
        @test r.ok == true
    end
end

# ── gather_code_versions (tmpdir git fixture) ───────────────────────────────

@testset "gather_code_versions: minimal git fixture" begin
    root = mktempdir()
    try
        cd(root) do
            run(pipeline(`git init --quiet`; stderr=devnull))
            run(
                pipeline(
                    `git -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet`;
                    stderr=devnull,
                ),
            )
        end
        submod = joinpath(root, "submodules", "FooLib")
        mkpath(submod)
        cd(submod) do
            run(pipeline(`git init --quiet`; stderr=devnull))
            run(
                pipeline(
                    `git -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet`;
                    stderr=devnull,
                ),
            )
        end

        cv = gather_code_versions(root)
        @test haskey(cv, "parent")
        @test haskey(cv, "FooLib")
        @test !isempty(cv["parent"])
        @test !isempty(cv["FooLib"])
    finally
        rm(root; recursive=true, force=true)
    end
end

# ── build_experiments_index ─────────────────────────────────────────────────

@testset "build_experiments_index: lists all runs" begin
    outdir = mktempdir()
    try
        v1 = Vault(CONFIG_REPORT; outdir=outdir, run="r1")
        v2 = Vault(CONFIG_REPORT; outdir=outdir, run="r2")
        build_ledger(v1);
        build_ledger(v2)

        idx = build_experiments_index(outdir, "test_study")
        @test isfile(idx)
        txt = read(idx, String)
        @test occursin("r1", txt)
        @test occursin("r2", txt)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ── events_*.jsonl timing section ───────────────────────────────────────────

@testset "build_experiment_report: events_*.jsonl timing section populated" begin
    with_report_vault() do vault, outdir
        writer = _dummy_writer(:FakeWriter)
        # Write a minimal events_*.jsonl under outdir.
        ev = joinpath(outdir, "events_host_1.jsonl")
        open(ev, "w") do io
            println(io, """{"kind":"key_start","ts":"2026-04-18T10:00:00","key":"a"}""")
            println(
                io,
                """{"kind":"key_done","ts":"2026-04-18T10:00:05","key":"a","secs":5.0}""",
            )
            println(
                io,
                """{"kind":"key_done","ts":"2026-04-18T10:00:10","key":"b","secs":2.0}""",
            )
        end

        readme = build_experiment_report(vault, writer)
        content = read(readme, String)
        @test occursin("Masters: 1", content)
        @test occursin("key_done events: 2", content)
        @test occursin("Longest keys", content)
    end
end
