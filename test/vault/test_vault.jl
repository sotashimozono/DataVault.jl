using Dates

const FIXTURES = joinpath(@__DIR__, "fixtures")
const CONFIG = joinpath(FIXTURES, "study.toml")

# Each testset uses its own tmpdir so tests are isolated
function with_vault(f)
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# Convenience: first key in the full key list
first_key(vault) = DataVault.keys(vault)[1]

# ── Constructor ───────────────────────────────────────────────────────────────

@testset "Vault: constructor reads config" begin
    with_vault() do vault, _
        @test vault.spec.study.project_name == "test_study"
        @test vault.spec.study.total_samples == 2
        @test vault.spec.path_keys == ["system.N", "model.g"]
    end
end

@testset "Vault: outdir override" begin
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        @test vault.outdir == abspath(outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Vault: config snapshot created" begin
    with_vault() do vault, outdir
        snapshot = joinpath(
            outdir, "data", "test_study", "default", "config_snapshot.toml"
        )
        @test isfile(snapshot)
    end
end

@testset "Vault: config snapshot warns on change" begin
    with_vault() do vault, outdir
        snapshot = joinpath(
            outdir, "data", "test_study", "default", "config_snapshot.toml"
        )
        # Overwrite snapshot with a different parameter value
        raw = TOML.parsefile(snapshot)
        raw["study"]["total_samples"] = 999
        open(snapshot, "w") do io
            TOML.print(io, raw)
        end
        # Re-constructing the Vault should warn, not error
        @test_logs (:warn, r"Config has changed") Vault(CONFIG; outdir=outdir)
    end
end

# ── Key enumeration ───────────────────────────────────────────────────────────

@testset "keys: returns all DataKeys" begin
    with_vault() do vault, _
        ks = DataVault.keys(vault)
        # 2N × 2g × 2 samples = 8
        @test length(ks) == 8
        @test all(k -> k isa DataKey, ks)
    end
end

@testset "keys: status filtering" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test length(DataVault.keys(vault; status=:done)) == 0
        @test length(DataVault.keys(vault; status=:pending)) == 8

        mark_done!(vault, k)

        @test length(DataVault.keys(vault; status=:done)) == 1
        @test length(DataVault.keys(vault; status=:pending)) == 7
    end
end

@testset "keys: unknown status → error" begin
    with_vault() do vault, _
        @test_throws ErrorException DataVault.keys(vault; status=:bogus)
    end
end

# ── Status: done / running ────────────────────────────────────────────────────

@testset "is_done: false before, true after mark_done!" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test !is_done(vault, k)
        mark_done!(vault, k)
        @test is_done(vault, k)
    end
end

@testset "mark_done!: .done file has expected fields" begin
    with_vault() do vault, outdir
        k = first_key(vault)
        mark_done!(vault, k; tag_value=0.99)

        # Find and parse the .done file
        done_files = filter(
            f -> endswith(f, ".done"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test length(done_files) == 1

        content = read(done_files[1], String)
        @test occursin("jobid=", content)
        @test occursin("completed=", content)
        @test occursin("git_hash=", content)
        @test occursin("tag_value=0.99", content)
    end
end

@testset "mark_running! creates .running; mark_done! removes it" begin
    with_vault() do vault, outdir
        k = first_key(vault)
        mark_running!(vault, k)

        running_files = filter(
            f -> endswith(f, ".running"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test length(running_files) == 1

        mark_done!(vault, k)
        @test !isfile(running_files[1])
    end
end

# ── Data I/O ──────────────────────────────────────────────────────────────────

@testset "save! / load: round-trip" begin
    with_vault() do vault, _
        k = first_key(vault)
        data = Dict("energy" => -1.23, "magnetization" => [0.1, 0.2, 0.3])

        DataVault.save!(vault, k, data)
        loaded = DataVault.load(vault, k)

        @test loaded["energy"] ≈ -1.23
        @test loaded["magnetization"] ≈ [0.1, 0.2, 0.3]
    end
end

@testset "save! is atomic: file does not appear until complete" begin
    with_vault() do vault, _
        k = first_key(vault)
        DataVault.save!(vault, k, Dict("x" => 42))
        @test isfile(DataVault._data_file(vault, k))
    end
end

@testset "load: error on missing file" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test_throws ErrorException DataVault.load(vault, k)
    end
end

@testset "save_bin! / load_bin: round-trip" begin
    with_vault() do vault, _
        k = first_key(vault)
        data = Dict("mps" => rand(4, 4))

        DataVault.save_bin!(vault, k, data)
        loaded = DataVault.load_bin(vault, k)
        @test loaded["mps"] ≈ data["mps"]
    end
end

@testset "load_bin: error with helpful message when missing" begin
    with_vault() do vault, _
        k = first_key(vault)
        ex = try
            DataVault.load_bin(vault, k);
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("HPC", ex.msg)
    end
end

# ── Ledger ────────────────────────────────────────────────────────────────────

@testset "build_ledger: empty when no done keys" begin
    with_vault() do vault, outdir
        path = build_ledger(vault)
        @test isfile(path)
        @test read(path, String) == ""
    end
end

@testset "build_ledger: rows match done keys" begin
    with_vault() do vault, outdir
        ks = DataVault.keys(vault)[1:3]
        for k in ks
            mark_done!(vault, k)
        end

        path = build_ledger(vault)
        lines = readlines(path)

        @test length(lines) == 4   # header + 3 rows
        @test occursin("sample", lines[1])
        @test occursin("git_hash", lines[1])
        @test length(lines) - 1 == 3
    end
end

# ── Figure provenance ─────────────────────────────────────────────────────────

@testset "record_figure: meta.toml created" begin
    with_vault() do vault, outdir
        path = record_figure(
            vault;
            study="test_study",
            scripts=Dict("plot_energy" => "scripts/plot_energy.jl"),
        )

        @test isfile(path)
        meta = TOML.parsefile(path)
        @test haskey(meta, "source")
        @test haskey(meta["source"], "config")
        @test haskey(meta["source"], "git_hash")
        @test haskey(meta["source"], "generated_at")
        @test meta["scripts"]["plot_energy"] == "scripts/plot_energy.jl"
    end
end

# ── Cleanup ───────────────────────────────────────────────────────────────────

@testset "cleanup_stale: removes .running files" begin
    with_vault() do vault, outdir
        ks = DataVault.keys(vault)[1:3]
        for k in ks
            ;
            mark_running!(vault, k);
        end

        n = cleanup_stale(vault)
        @test n == 3

        running = filter(
            f -> endswith(f, ".running"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test isempty(running)
    end
end

@testset "cleanup_stale: returns 0 if no status dir" begin
    with_vault() do vault, _
        @test cleanup_stale(vault) == 0
    end
end

# ── Custom path_formatter ─────────────────────────────────────────────────────

@testset "path_formatter: default uses ParamIO.format_path" begin
    with_vault() do vault, _
        # デフォルトでは ParamIO.format_path と一致すべき
        @test vault.path_formatter === ParamIO.format_path
        key = first_key(vault)
        expected = ParamIO.format_path(key, vault.spec.path_keys)
        @test DataVault._param_path(vault, key) == expected
    end
end

@testset "path_formatter: custom function overrides default" begin
    outdir = mktempdir()
    try
        # カスタムフォーマッタ: "custom_N{N}_g{g}" のような独自形式
        my_format = (key, _) -> begin
            n = key.params["system.N"]
            g = key.params["model.g"]
            "custom_N$(n)_g$(g)"
        end

        vault = Vault(CONFIG; outdir=outdir, path_formatter=my_format)
        key = DataVault.keys(vault)[1]
        @test DataVault._param_path(vault, key) == "custom_N24_g0.5"
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "path_formatter: custom format affects data/bin/status paths" begin
    outdir = mktempdir()
    try
        my_format = (_, _) -> "FIXED_LABEL"
        vault = Vault(CONFIG; outdir=outdir, path_formatter=my_format)
        key = DataVault.keys(vault)[1]

        DataVault.save!(vault, key, Dict("x" => 1.0))
        mark_done!(vault, key)

        # 全パスに "FIXED_LABEL" が含まれていることを確認
        @test occursin("FIXED_LABEL", DataVault._data_dir(vault, key))
        @test occursin("FIXED_LABEL", DataVault._bin_dir(vault, key))
        @test occursin("FIXED_LABEL", DataVault._status_dir(vault, key))
        @test isfile(DataVault._data_file(vault, key))
        @test is_done(vault, key)
    finally
        rm(outdir; recursive=true, force=true)
    end
end
