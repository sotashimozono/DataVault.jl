# test_query.jl — programmatic query API (attach / open_all / load_ledger / build_master_ledger)
#
# Q. はテスト戦略 A〜F に対応する Query という独立カテゴリ。
# DataVault.jl をデータベースとして使った検索可能性を担保する。

using Dates

const Q_FIXTURES = joinpath(@__DIR__, "fixtures")
const Q_CONFIG = joinpath(Q_FIXTURES, "study.toml")

# ──────────────────────────────────────────────────────────────────────────────
# Q.1 attach(log_path) returns a working Vault
# ──────────────────────────────────────────────────────────────────────────────

@testset "Q.1 attach(log_path) returns a working Vault" begin
    outdir = mktempdir()
    try
        v0 = Vault(Q_CONFIG; run="phase1", outdir=outdir)
        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "phase1.log.toml"
        )

        v1 = attach(log_path)
        @test v1 isa Vault
        @test v1.run == "phase1"
        @test v1.outdir == abspath(outdir)
        @test v1.spec.study.project_name == v0.spec.study.project_name
        @test v1.spec.path_keys == v0.spec.path_keys
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.2 attach(outdir; project, run) resolves via the frozen contract" begin
    outdir = mktempdir()
    try
        Vault(Q_CONFIG; run="phase1", outdir=outdir)
        v = attach(outdir; project="test_study", run="phase1")
        @test v.run == "phase1"
        @test v.outdir == abspath(outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.3 attach on missing log.toml errors cleanly" begin
    outdir = mktempdir()
    try
        ex = try
            attach(outdir; project="ghost", run="none")
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("No log.toml", ex.msg)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.4 attach falls back to config_snapshot when original config is gone" begin
    outdir = mktempdir()
    try
        Vault(Q_CONFIG; run="phase1", outdir=outdir)

        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "phase1.log.toml"
        )
        parsed = TOML.parsefile(log_path)
        parsed["study"]["config"] = "/absolutely/nonexistent/study.toml"
        open(log_path, "w") do io
            TOML.print(io, parsed)
        end

        v = attach(log_path)
        @test v.run == "phase1"
        @test v.spec.study.project_name == "test_study"
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.5 attach on unknown version errors explicitly" begin
    outdir = mktempdir()
    try
        dv_study = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME, "future_study")
        mkpath(dv_study)
        cp(
            joinpath(Q_FIXTURES, "log_v99_unknown.toml"),
            joinpath(dv_study, "default.log.toml"),
        )

        ex = try
            attach(outdir; project="future_study", run="default")
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("Unknown log_toml_version", ex.msg)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.6 open_all returns every (study, run) under outdir" begin
    outdir = mktempdir()
    try
        Vault(Q_CONFIG; run="phase1", outdir=outdir)
        Vault(Q_CONFIG; run="phase2", outdir=outdir)

        attached = open_all(outdir)
        @test length(attached) == 2
        @test all(a -> a isa AttachedStudy, attached)
        @test Set(a.info.run for a in attached) == Set(["phase1", "phase2"])
        @test all(a -> a.vault isa Vault, attached)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.7 open_all on empty outdir returns []" begin
    outdir = mktempdir()
    try
        @test isempty(open_all(outdir))
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.8 open_all warns and skips broken log.toml" begin
    outdir = mktempdir()
    try
        Vault(Q_CONFIG; run="phase1", outdir=outdir)

        # Plant a broken (missing-meta) log.toml as a second entry
        dv_study = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME, "broken_study")
        mkpath(dv_study)
        cp(
            joinpath(Q_FIXTURES, "log_v1_missing_meta.toml"),
            joinpath(dv_study, "default.log.toml"),
        )

        attached = @test_logs (:warn, r"Failed to attach") match_mode = :any open_all(
            outdir
        )
        @test length(attached) == 1
        @test attached[1].info.project_name == "test_study"
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.9 load_ledger returns rows after mark_done! + build_ledger" begin
    outdir = mktempdir()
    try
        vault = Vault(Q_CONFIG; run="phase1", outdir=outdir)
        ks = DataVault.keys(vault)[1:3]
        for k in ks
            DataVault.save!(vault, k, Dict("x" => 1.0))
            mark_done!(vault, k)
        end
        build_ledger(vault)

        rows = load_ledger(vault)
        @test length(rows) == 3
        @test all(r -> haskey(r, "sample"), rows)
        @test all(r -> r["status"] == "done", rows)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.10 load_ledger returns empty Vector when ledger.csv is missing" begin
    outdir = mktempdir()
    try
        vault = Vault(Q_CONFIG; run="default", outdir=outdir)
        @test isempty(load_ledger(vault))
        @test load_ledger(vault) isa Vector{Dict{String,String}}
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.11 build_master_ledger aggregates across multiple runs" begin
    outdir = mktempdir()
    try
        # phase1: 3 done
        v1 = Vault(Q_CONFIG; run="phase1", outdir=outdir)
        for k in DataVault.keys(v1)[1:3]
            DataVault.save!(v1, k, Dict("x" => 1.0))
            mark_done!(v1, k)
        end
        build_ledger(v1)

        # phase2: 2 done
        v2 = Vault(Q_CONFIG; run="phase2", outdir=outdir)
        for k in DataVault.keys(v2)[1:2]
            DataVault.save!(v2, k, Dict("x" => 2.0))
            mark_done!(v2, k)
        end
        build_ledger(v2)

        master = build_master_ledger(outdir)
        @test length(master) == 5
        @test Set(r["run"] for r in master) == Set(["phase1", "phase2"])
        @test all(r -> r["project_name"] == "test_study", master)
        @test all(r -> haskey(r, "datavault_version"), master)
        @test all(r -> haskey(r, "log_toml"), master)

        # Per-run row counts
        @test count(r -> r["run"] == "phase1", master) == 3
        @test count(r -> r["run"] == "phase2", master) == 2
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Q.12 end-to-end: discover → attach → load → analyze" begin
    outdir = mktempdir()
    try
        # Write data via a vault, then forget the writer
        vault0 = Vault(Q_CONFIG; run="phase1", outdir=outdir)
        key0 = DataVault.keys(vault0)[1]
        DataVault.save!(vault0, key0, Dict("energy" => -2.5))
        mark_done!(vault0, key0)

        # Discover and attach fresh — no knowledge of config_path
        attached = open_all(outdir)
        @test length(attached) == 1
        study = attached[1]

        # Use the existing DataKey-based API on the attached vault
        done_keys = DataVault.keys(study.vault; status=:done)
        @test length(done_keys) == 1
        loaded = DataVault.load(study.vault, done_keys[1])
        @test loaded["energy"] ≈ -2.5
    finally
        rm(outdir; recursive=true, force=true)
    end
end
