"""
scripts/compute.jl — Van der Pol 計算スクリプト

使い方:
    julia --project=. scripts/compute.jl [config_path]

デフォルト config: configs/vanderpol.toml
"""

using DataVault, ParamIO
include(joinpath(@__DIR__, "..", "src", "VanDerPol.jl"))
using .VanDerPol

const EXAMPLES = joinpath(@__DIR__, "..")
const CONFIG = get(ARGS, 1, joinpath(EXAMPLES, "configs", "vanderpol.toml"))
const OUTDIR = get(ENV, "DATAVAULT_OUTDIR", joinpath(EXAMPLES, "out"))

vault = Vault(CONFIG; outdir=OUTDIR)

pending = DataVault.keys(vault; status=:pending)
println("=== Van der Pol computation ===")
println("Config : $CONFIG")
println("Outdir : $(vault.outdir)")
println("Pending: $(length(pending)) / $(length(DataVault.keys(vault))) keys")

for key in pending
    μ = Float64(key.params["system.mu"])
    t_end = Float64(key.params["system.t_end"])
    dt = Float64(key.params["system.dt"])
    s = key.sample

    # sample ごとにシードを固定して初期条件を決める
    rng = (s * 1234567 + 891011) % 999983   # 簡易シード (Random 依存なし)
    x0 = 0.5 + (rng % 100) / 200.0        # 0.5 ~ 1.0
    v0 = ((rng * 31337) % 100) / 200.0 - 0.25  # -0.25 ~ 0.25
    u0 = [x0, v0]

    mark_running!(vault, key)
    print("  mu=$(μ), sample=$(s) ... ")

    ts, xs, ys = rk4_solve(μ, u0, t_end, dt)
    obs = extract_observables(ts, xs, ys)

    # 軌跡は容量が大きいので間引いて保存 (10 ステップに 1 点)
    stride = 10
    data = Dict{String,Any}(
        "amplitude" => obs["amplitude"],
        "period" => obs["period"],
        "energy" => obs["energy"],
        "ts" => obs["ts"][1:stride:end],
        "xs" => obs["xs"][1:stride:end],
        "ys" => obs["ys"][1:stride:end],
        "x0" => x0,
        "v0" => v0,
        "mu" => μ,
    )

    DataVault.save!(vault, key, data)
    mark_done!(vault, key; tag_value=obs["amplitude"])
    println(
        "amplitude=$(round(obs["amplitude"], digits=4)), period=$(round(obs["period"], digits=4))",
    )
end

println("\nBuilding ledger...")
ledger_path = build_ledger(vault)
println("Ledger: $ledger_path")

record_figure(
    vault;
    study="vanderpol",
    scripts=Dict(
        "compute" => "scripts/compute.jl", "summary" => "scripts/analysis/summarize.jl"
    ),
)

println("Done.")
