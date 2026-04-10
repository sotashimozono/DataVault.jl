# test_log_toml.jl — log.toml の writer / reader / discovery / forward compat
#
# 章立ては test strategy A〜F に対応:
#   A. forward compat (fixture による過去バージョン互換)
#   B. 初期状態の遷移 (fresh / partial / existing)
#   C. run handling (多段フェーズ探索)
#   D. concurrent safety (並列ジョブ)
#   F. round-trip recovery (log.toml からの復元)

using Dates
using JLD2
using Base.Threads: @spawn

const LT_FIXTURES = joinpath(@__DIR__, "fixtures")
const LT_CONFIG = joinpath(LT_FIXTURES, "study.toml")

function with_run_vault(f; run::AbstractString="default")
    outdir = mktempdir()
    try
        vault = Vault(LT_CONFIG; run=run, outdir=outdir)
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# A. Forward compatibility — fixtures
# ──────────────────────────────────────────────────────────────────────────────

@testset "A.1 read_log_toml: v1 fixture parses fully" begin
    path = joinpath(LT_FIXTURES, "log_v1.toml")
    info = read_log_toml(path)

    @test info isa DataVault.LogTomlV1
    @test info.log_toml_version == 1
    @test info.datavault_version == "0.3.0"
    @test info.datavault_git_hash == "abc1234"
    @test info.created_at == "2026-04-10T13:50:00"

    @test info.project_name == "test_study"
    @test info.config == "configs/test_study.toml"
    @test info.run == "phase1"

    @test info.data_dir == "data/test_study/phase1"
    @test info.status_dir == "status/test_study/phase1"
    @test info.bin_dir == "bin/test_study/phase1"
    @test info.ledger == "data/test_study/phase1/ledger.csv"
    @test info.config_snapshot == "data/test_study/phase1/config_snapshot.toml"

    @test info.path_scheme == "default"
    @test info.path_formatter == "ParamIO.format_path"
    @test info.path_keys == ["system.N", "model.g"]

    @test info.julia_version == "1.12.2"
    @test info.hostname == "fixture-host"
end

@testset "A.2 envelope invariants: LOG_TOML_VERSION and registry" begin
    @test DataVault.LOG_TOML_VERSION == 1
    @test haskey(DataVault.LOG_TOML_READERS, 1)
    @test DataVault.LOG_TOML_READERS[1] isa Function
end

@testset "A.3 unknown log_toml_version is rejected explicitly" begin
    path = joinpath(LT_FIXTURES, "log_v99_unknown.toml")
    ex = try
        read_log_toml(path)
        nothing
    catch e
        e
    end
    @test ex isa ErrorException
    @test occursin("Unknown log_toml_version=99", ex.msg)
    @test occursin("upgrade DataVault", ex.msg)
end

@testset "A.4 missing [meta] envelope is rejected explicitly" begin
    path = joinpath(LT_FIXTURES, "log_v1_missing_meta.toml")
    ex = try
        read_log_toml(path)
        nothing
    catch e
        e
    end
    @test ex isa ErrorException
    @test occursin("[meta]", ex.msg)
end

@testset "A.5 nonexistent file is rejected explicitly" begin
    path = joinpath(mktempdir(), "nope.log.toml")
    ex = try
        read_log_toml(path)
        nothing
    catch e
        e
    end
    @test ex isa ErrorException
    @test occursin("not found", ex.msg)
end

@testset "A.6 discovery contract: find_log_tomls scans .datavault/ recursively" begin
    # 手で discovery anchor を配置して scan が見つけることを確認。
    # これは DataVault の writer に依存しない契約テスト。
    tmp = mktempdir()
    try
        dv = joinpath(tmp, DataVault.DATAVAULT_DIR_NAME)
        mkpath(joinpath(dv, "studyA"))
        mkpath(joinpath(dv, "studyB"))
        cp(joinpath(LT_FIXTURES, "log_v1.toml"), joinpath(dv, "studyA", "phase1.log.toml"))
        cp(joinpath(LT_FIXTURES, "log_v1.toml"), joinpath(dv, "studyB", "default.log.toml"))
        write(joinpath(dv, "README.md"), "ignored")   # non-log.toml file
        write(joinpath(dv, "studyA", "other.txt"), "ignored")

        found = find_log_tomls(tmp)
        @test length(found) == 2
        @test all(p -> endswith(p, ".log.toml"), found)
    finally
        rm(tmp; recursive=true, force=true)
    end
end

@testset "A.7 find_log_tomls on empty outdir returns []" begin
    tmp = mktempdir()
    try
        @test isempty(find_log_tomls(tmp))
    finally
        rm(tmp; recursive=true, force=true)
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# B. Initial state transitions
# ──────────────────────────────────────────────────────────────────────────────

@testset "B.1 fresh outdir: .datavault, README, and log.toml are all created" begin
    outdir = mktempdir()
    try
        Vault(LT_CONFIG; outdir=outdir)

        dv_dir = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME)
        @test isdir(dv_dir)
        @test isfile(joinpath(dv_dir, "README.md"))

        log_path = joinpath(dv_dir, "test_study", "default.log.toml")
        @test isfile(log_path)

        info = read_log_toml(log_path)
        @test info.run == "default"
        @test info.project_name == "test_study"
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "B.2 preexisting README is preserved" begin
    outdir = mktempdir()
    try
        dv_dir = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME)
        mkpath(dv_dir)
        marker = "# custom user notes — DO NOT OVERWRITE\n"
        write(joinpath(dv_dir, "README.md"), marker)

        Vault(LT_CONFIG; outdir=outdir)

        @test read(joinpath(dv_dir, "README.md"), String) == marker
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "B.3 idempotent re-construction preserves created_at" begin
    outdir = mktempdir()
    try
        Vault(LT_CONFIG; outdir=outdir)
        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "default.log.toml"
        )
        first_ts = read_log_toml(log_path).created_at

        sleep(1.1)  # ensure Dates.now() would differ if (incorrectly) regenerated

        Vault(LT_CONFIG; outdir=outdir)
        second_ts = read_log_toml(log_path).created_at
        @test first_ts == second_ts
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "B.4 partial state: .datavault exists but no log.toml yet" begin
    outdir = mktempdir()
    try
        mkpath(joinpath(outdir, DataVault.DATAVAULT_DIR_NAME))  # dir, no README, no log
        Vault(LT_CONFIG; outdir=outdir)

        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "default.log.toml"
        )
        @test isfile(log_path)
        @test isfile(joinpath(outdir, DataVault.DATAVAULT_DIR_NAME, "README.md"))
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "B.5 path_keys conflict on same run name → error" begin
    outdir = mktempdir()
    try
        # Initial Vault with canonical config
        Vault(LT_CONFIG; run="phase1", outdir=outdir)

        # Craft a second config with the same project_name but different path_keys
        alt_config = joinpath(outdir, "alt_study.toml")
        cp(LT_CONFIG, alt_config)
        raw = TOML.parsefile(alt_config)
        raw["datavault"]["path_keys"] = ["model.g"]   # shrink the key list
        open(alt_config, "w") do io
            TOML.print(io, raw)
        end

        ex = try
            Vault(alt_config; run="phase1", outdir=outdir)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("path_keys", ex.msg)
        @test occursin("phase1", ex.msg)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "B.6 unknown log_toml_version at construction time → error" begin
    outdir = mktempdir()
    try
        # Plant a future-version log.toml for this study/run
        dv_study = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME, "test_study")
        mkpath(dv_study)
        cp(
            joinpath(LT_FIXTURES, "log_v99_unknown.toml"),
            joinpath(dv_study, "default.log.toml"),
        )

        ex = try
            Vault(LT_CONFIG; outdir=outdir)
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

# ──────────────────────────────────────────────────────────────────────────────
# C. Run handling
# ──────────────────────────────────────────────────────────────────────────────

@testset "C.1 default run is 'default'" begin
    with_run_vault() do vault, _
        @test vault.run == "default"
    end
end

@testset "C.2 multiple runs coexist under the same study" begin
    outdir = mktempdir()
    try
        Vault(LT_CONFIG; run="phase1", outdir=outdir)
        Vault(LT_CONFIG; run="phase2_refined", outdir=outdir)
        Vault(LT_CONFIG; run="default", outdir=outdir)

        dv_study = joinpath(outdir, DataVault.DATAVAULT_DIR_NAME, "test_study")
        @test isfile(joinpath(dv_study, "phase1.log.toml"))
        @test isfile(joinpath(dv_study, "phase2_refined.log.toml"))
        @test isfile(joinpath(dv_study, "default.log.toml"))

        @test length(find_log_tomls(outdir)) == 3
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "C.3 run appears in data/status/bin path segments" begin
    with_run_vault(run="phase1") do vault, outdir
        key = DataVault.keys(vault)[1]
        @test occursin(
            joinpath("data", "test_study", "phase1"), DataVault._data_dir(vault, key)
        )
        @test occursin(
            joinpath("status", "test_study", "phase1"), DataVault._status_dir(vault, key)
        )
        @test occursin(
            joinpath("bin", "test_study", "phase1"), DataVault._bin_dir(vault, key)
        )
    end
end

@testset "C.4 different runs write to disjoint directories" begin
    outdir = mktempdir()
    try
        v1 = Vault(LT_CONFIG; run="phase1", outdir=outdir)
        v2 = Vault(LT_CONFIG; run="phase2", outdir=outdir)

        k1 = DataVault.keys(v1)[1]
        DataVault.save!(v1, k1, Dict("x" => 1.0))
        mark_done!(v1, k1)

        k2 = DataVault.keys(v2)[1]
        DataVault.save!(v2, k2, Dict("x" => 2.0))

        @test DataVault.load(v1, k1)["x"] == 1.0
        @test DataVault.load(v2, k2)["x"] == 2.0
        @test is_done(v1, k1)
        @test !is_done(v2, k2)   # phase2 did not mark_done
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "C.5 layout block in log.toml matches resolved paths" begin
    with_run_vault(run="phase1") do vault, outdir
        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "phase1.log.toml"
        )
        info = read_log_toml(log_path)

        @test joinpath(outdir, info.data_dir) == DataVault._run_data_dir(vault)
        @test joinpath(outdir, info.status_dir) == DataVault._run_status_dir(vault)
        @test joinpath(outdir, info.bin_dir) == DataVault._run_bin_dir(vault)
    end
end

@testset "C.6 config_snapshot is per-run" begin
    outdir = mktempdir()
    try
        Vault(LT_CONFIG; run="phase1", outdir=outdir)
        Vault(LT_CONFIG; run="phase2", outdir=outdir)

        s1 = joinpath(outdir, "data", "test_study", "phase1", "config_snapshot.toml")
        s2 = joinpath(outdir, "data", "test_study", "phase2", "config_snapshot.toml")
        @test isfile(s1)
        @test isfile(s2)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# D. Concurrent safety (pattern B)
# ──────────────────────────────────────────────────────────────────────────────

@testset "D.1 same-run concurrent construction is idempotent" begin
    outdir = mktempdir()
    try
        # Kick off several tasks that all construct the same (study, run)
        tasks = [@spawn Vault(LT_CONFIG; run="phase1", outdir=outdir) for _ in 1:8]
        for t in tasks
            fetch(t)
        end

        log_path = joinpath(
            outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "phase1.log.toml"
        )
        @test isfile(log_path)

        info = read_log_toml(log_path)
        @test info.run == "phase1"
        @test info.path_keys == ["system.N", "model.g"]

        # No leftover tmp files from interrupted writes
        leftovers = filter(f -> occursin(".tmp.", f), readdir(dirname(log_path); join=true))
        @test isempty(leftovers)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "D.2 different runs can be constructed in parallel without conflict" begin
    outdir = mktempdir()
    try
        runs = ["phase_a", "phase_b", "phase_c", "phase_d"]
        tasks = [@spawn Vault(LT_CONFIG; run=r, outdir=outdir) for r in runs]
        for t in tasks
            fetch(t)
        end

        for r in runs
            lp = joinpath(
                outdir, DataVault.DATAVAULT_DIR_NAME, "test_study", "$(r).log.toml"
            )
            @test isfile(lp)
        end
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# F. Round-trip recovery
# ──────────────────────────────────────────────────────────────────────────────

@testset "F.1 log.toml round-trip: discover → read → locate → load" begin
    outdir = mktempdir()
    try
        # 1. Write data via a normal Vault
        vault = Vault(LT_CONFIG; run="phase1", outdir=outdir)
        key = DataVault.keys(vault)[1]
        payload = Dict("energy" => -1.23, "mags" => [0.1, 0.2, 0.3])
        DataVault.save!(vault, key, payload)
        mark_done!(vault, key)
        build_ledger(vault)

        # 2. Discover log.toml without any Vault instance in hand
        logs = find_log_tomls(outdir)
        @test length(logs) == 1

        info = read_log_toml(logs[1])
        @test info.run == "phase1"
        @test info.path_keys == ["system.N", "model.g"]

        # 3. Reconstruct paths from log.toml alone
        data_dir_abs = joinpath(outdir, info.data_dir)
        ledger_path = joinpath(outdir, info.ledger)
        snapshot_path = joinpath(outdir, info.config_snapshot)
        @test isdir(data_dir_abs)
        @test isfile(ledger_path)
        @test isfile(snapshot_path)

        # 4. Locate the JLD2 file by the recorded path scheme + keys and load it
        #    (This mirrors what a future "load by log.toml" helper would do.)
        param_segment = ParamIO.format_path(key, info.path_keys)
        jld2_path = joinpath(
            data_dir_abs, param_segment, "data_sample$(lpad(key.sample, 3, '0')).jld2"
        )
        @test isfile(jld2_path)

        loaded = JLD2.load(jld2_path)
        @test loaded["energy"] ≈ -1.23
        @test loaded["mags"] ≈ [0.1, 0.2, 0.3]
    finally
        rm(outdir; recursive=true, force=true)
    end
end
