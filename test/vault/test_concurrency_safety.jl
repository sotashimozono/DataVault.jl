using Dates

isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))
isdefined(@__MODULE__, :CONFIG) || (const CONFIG = joinpath(FIXTURES, "study.toml"))

"""
test_concurrency_safety.jl — concurrency / robustness fixes

- `save!` uses a per-task tmp name, so concurrent writers to one key in the
  same process can't `mv` each other's half-written tmp file (corruption).
- a future-dated heartbeat never yields a negative age, so NFS clock skew can't
  make a `.running` lock look perpetually fresh (immortal / never reclaimable).
- `ledger.csv` quotes cells, so a comma in `tag_value` round-trips instead of
  shifting every later column.
"""

@testset "save!: concurrent writers to one key don't corrupt" begin
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        key = DataVault.keys(vault)[1]
        @sync for _ in 1:50
            Threads.@spawn DataVault.save!(vault, key, Dict{String,Any}("x" => 1))
        end
        d = DataVault.load(vault, key)        # must load cleanly (not truncated)
        @test d["x"] == 1
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "heartbeat: future timestamp never yields negative age (no immortal lock)" begin
    mktempdir() do dir
        p = joinpath(dir, "k.running")
        for ahead in (Dates.Second(60), Dates.Hour(10))   # within-skew and beyond-skew
            future = Dates.now() + ahead
            write(p, "heartbeat=" * Dates.format(future, "yyyy-mm-ddTHH:MM:SS") * "\n")
            @test DataVault._running_age_secs(p, Dates.now()) >= 0.0
        end
    end
end

@testset "ledger CSV: comma in tag_value round-trips" begin
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict{String,Any}("x" => 1))
        DataVault.mark_done!(vault, key; tag_value="[1, 2, 3]")
        DataVault.build_ledger(vault)
        rows = DataVault.load_ledger(vault)
        @test length(rows) == 1
        @test rows[1]["tag_value"] == "[1, 2, 3]"
    finally
        rm(outdir; recursive=true, force=true)
    end
end
