using Dates, TOML

const FIXTURES_WF = joinpath(@__DIR__, "fixtures")
const CONFIG_WF = joinpath(FIXTURES_WF, "study.toml")

function with_workflow_vault(f)
    outdir = mktempdir()
    try
        vault = Vault(CONFIG_WF; outdir=outdir, run="rwf")
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ── new_experiment ──────────────────────────────────────────────────────────

@testset "new_experiment: scaffolds EXP directory with front-matter" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        path = new_experiment(
            vault;
            slug="foo-bar",
            purpose="Test scaffold.",
            hypothesis="H1",
            hypothesis_ref="RQ1",
            author="tester",
            experiments_root=experiments_root,
        )
        @test isfile(path)
        @test basename(dirname(path)) == "EXP-001-foo-bar"
        content = read(path, String)
        @test occursin(r"(?m)^# EXP-001 — foo-bar", content)
        @test occursin("Test scaffold.", content)
        @test occursin("H1", content)
        @test occursin("## Generated provenance", content)
        @test occursin("slug: \"foo-bar\"", content)
    end
end

@testset "new_experiment: auto-increments ID" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        p1 = new_experiment(vault; slug="one", experiments_root=experiments_root)
        p2 = new_experiment(vault; slug="two", experiments_root=experiments_root)
        @test occursin("EXP-001-one", p1)
        @test occursin("EXP-002-two", p2)
    end
end

@testset "new_experiment: explicit id as Integer" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        p = new_experiment(vault; slug="pinned", experiments_root=experiments_root, id=42)
        @test occursin("EXP-042-pinned", p)
    end
end

@testset "new_experiment: rejects bad slug" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        @test_throws ErrorException new_experiment(
            vault; slug="has spaces", experiments_root=experiments_root
        )
        @test_throws ErrorException new_experiment(
            vault; slug="bad/slash", experiments_root=experiments_root
        )
    end
end

@testset "new_experiment: refuses to overwrite existing EXP" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        new_experiment(vault; slug="dup", experiments_root=experiments_root, id=1)
        @test_throws ErrorException new_experiment(
            vault; slug="dup", experiments_root=experiments_root, id=1
        )
    end
end

# ── build_narrative_index ──────────────────────────────────────────────────

@testset "build_narrative_index: tabulates scaffolded EXPs" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        new_experiment(vault; slug="alpha", experiments_root=experiments_root)
        new_experiment(vault; slug="beta", experiments_root=experiments_root)

        idx = build_narrative_index(experiments_root)
        @test isfile(idx)
        txt = read(idx, String)
        @test occursin("EXP-001", txt)
        @test occursin("EXP-002", txt)
        @test occursin("alpha", txt)
        @test occursin("beta", txt)
    end
end

# ── build_experiment_report ↔ EXP-NNN linking ───────────────────────────────

@testset "build_experiment_report: updates matched EXP README" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        # Scaffold an EXP that opts in to this run via data_runs.
        readme_path = new_experiment(
            vault; slug="linked", experiments_root=experiments_root
        )
        # Manually add rwf to data_runs in the scaffolded front-matter.
        DataVault._update_data_runs!(readme_path, vault.run)

        # Provide a dummy writer so build_experiment_report has a module.
        writer = Module(:DummyWriter, false)
        Core.eval(writer, :(const DATA_SCHEMA_VERSION = 1))

        # Plant a minimal ledger + data so build_experiment_report has
        # something to summarise.
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict("bench" => Dict("x" => [1])))
        mark_done!(vault, key)
        build_ledger(vault)

        out = build_experiment_report(
            vault, writer; experiments_root=experiments_root,
        )
        @test isfile(out)

        updated = read(readme_path, String)
        @test occursin("Run: [`", updated)
        @test occursin(vault.run, updated)
        # data_runs is idempotent — second call should not duplicate.
        build_experiment_report(vault, writer; experiments_root=experiments_root)
        updated2 = read(readme_path, String)
        @test count(_ -> true, eachmatch(r"data_runs:\s*\[rwf\]", updated2)) == 1
    end
end

@testset "build_experiment_report: skips EXP without opt-in" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        # Scaffold but do NOT opt in via data_runs.
        readme_path = new_experiment(
            vault; slug="isolated", experiments_root=experiments_root
        )
        writer = Module(:DummyWriter, false)
        Core.eval(writer, :(const DATA_SCHEMA_VERSION = 1))
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict("bench" => Dict("x" => [1])))
        mark_done!(vault, key)
        build_ledger(vault)

        original = read(readme_path, String)
        build_experiment_report(vault, writer; experiments_root=experiments_root)
        after = read(readme_path, String)
        # No data_runs, no match_all, so the file is unchanged.
        @test original == after
    end
end

@testset "build_experiment_report: match_all overrides opt-in" begin
    with_workflow_vault() do vault, outdir
        experiments_root = joinpath(outdir, "experiments")
        readme_path = new_experiment(
            vault; slug="bulk", experiments_root=experiments_root
        )
        writer = Module(:DummyWriter, false)
        Core.eval(writer, :(const DATA_SCHEMA_VERSION = 1))
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict("bench" => Dict("x" => [1])))
        mark_done!(vault, key)
        build_ledger(vault)

        build_experiment_report(
            vault, writer; experiments_root=experiments_root, narrative_match_all=true,
        )
        after = read(readme_path, String)
        @test occursin("Run: [`", after)
    end
end

# ── experiment_template ────────────────────────────────────────────────────

@testset "experiment_template: returns the raw TEMPLATE string" begin
    tpl = experiment_template()
    @test occursin("{{slug}}", tpl)
    @test occursin("{{purpose}}", tpl)
    @test occursin("## Generated provenance", tpl)
end
