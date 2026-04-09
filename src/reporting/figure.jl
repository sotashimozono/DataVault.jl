# reporting/figure.jl — figure provenance (meta.toml)

"""
    record_figure(vault; study, scripts=Dict())

Write `meta.toml` under `out/figure/{study}/`.

`scripts` is an optional `Dict{String,String}` mapping label → path,
e.g. `Dict("plot_energy" => "scripts/analysis/plot_energy.jl")`.
"""
function record_figure(
    vault::Vault; study::AbstractString, scripts::Dict{String,String}=Dict{String,String}()
)
    figure_dir = joinpath(vault.outdir, "figure", study)
    mkpath(figure_dir)

    config_rel = relpath(vault.config_path, figure_dir)
    data_rel = relpath(joinpath(vault.outdir, "data", study), figure_dir)
    git_hash = _git_hash(vault.config_path)

    meta = Dict(
        "source" => Dict(
            "config" => config_rel,
            "data_dir" => data_rel,
            "git_hash" => git_hash,
            "generated_at" => string(Dates.today()),
        ),
        "scripts" => scripts,
    )

    meta_path = joinpath(figure_dir, "meta.toml")
    open(meta_path, "w") do io
        TOML.print(io, meta)
    end
    meta_path
end
