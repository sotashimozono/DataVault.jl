using TOML

const FIXTURES_FIG = joinpath(@__DIR__, "fixtures")
const CONFIG_FIG = joinpath(FIXTURES_FIG, "study.toml")

function with_fig_vault(f)
    outdir = mktempdir()
    try
        vault = Vault(CONFIG_FIG; outdir=outdir, run="rfig")
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

function _make_pdf(path::AbstractString, content::AbstractString)
    mkpath(dirname(path))
    write(path, content)
end

# ── archive_figure! ─────────────────────────────────────────────────────────

@testset "archive_figure!: two distinct versions chain in figures.toml" begin
    with_fig_vault() do vault, outdir
        run_fig_dir = joinpath(outdir, "figure", "test_study", "rfig")
        live = joinpath(run_fig_dir, "energy.pdf")

        _make_pdf(live, "version1-content")
        a1 = archive_figure!(vault, live; metadata=Dict("style" => "ribbon"))
        @test isfile(a1)

        _make_pdf(live, "version2-content-different")
        a2 = archive_figure!(vault, live; metadata=Dict("style" => "errorbar"))
        @test isfile(a2)
        @test a1 != a2

        toml = TOML.parsefile(joinpath(run_fig_dir, "figures.toml"))
        figs = toml["figures"]
        @test length(figs) == 1
        entry = figs[1]
        @test entry["name"] == "energy.pdf"
        @test length(entry["versions"]) == 2
        @test entry["versions"][1]["is_current"] == false
        @test entry["versions"][2]["is_current"] == true
    end
end

@testset "archive_figure!: content dedup reuses prior archive file" begin
    with_fig_vault() do vault, outdir
        run_fig_dir = joinpath(outdir, "figure", "test_study", "rfig")
        live = joinpath(run_fig_dir, "fig.pdf")

        _make_pdf(live, "identical-content")
        a1 = archive_figure!(vault, live)
        # Simulate a later identical re-generation.
        sleep(1.1)  # ensure archive_tag differs between calls
        a2 = archive_figure!(vault, live)
        @test a1 == a2   # on-disk archive reused
        toml = TOML.parsefile(joinpath(run_fig_dir, "figures.toml"))
        @test length(toml["figures"][1]["versions"]) == 2
    end
end

@testset "list_figure_history: returns recorded versions" begin
    with_fig_vault() do vault, outdir
        run_fig_dir = joinpath(outdir, "figure", "test_study", "rfig")
        live = joinpath(run_fig_dir, "fig.pdf")

        _make_pdf(live, "A")
        archive_figure!(vault, live; generator_script="scripts/g.jl")
        _make_pdf(live, "B")
        archive_figure!(vault, live)

        hist = list_figure_history(vault)
        @test length(hist) == 2
        @test hist[1].name == "fig.pdf"
        @test any(h -> h.is_current, hist)

        only_fig = list_figure_history(vault; name="fig.pdf")
        @test length(only_fig) == 2
    end
end

@testset "restore_figure!: rolls back to earlier version + re-archives current" begin
    with_fig_vault() do vault, outdir
        run_fig_dir = joinpath(outdir, "figure", "test_study", "rfig")
        live = joinpath(run_fig_dir, "fig.pdf")

        _make_pdf(live, "A")
        archive_figure!(vault, live)
        hist1 = list_figure_history(vault)
        tag_v1 = hist1[1].tag

        sleep(1.1)
        _make_pdf(live, "B")
        archive_figure!(vault, live)

        restored = restore_figure!(vault, "fig.pdf", tag_v1)
        @test restored == live
        @test read(live, String) == "A"

        # After restore, live has "A" again; manifest has 3+ versions (the
        # pre-restore "B" state is preserved) and is_current flips to tag_v1.
        hist2 = list_figure_history(vault)
        @test length(hist2) >= 3
        current = filter(h -> h.is_current, hist2)
        @test length(current) == 1
        @test current[1].tag == tag_v1
    end
end

# ── back-compat: record_figure still works ──────────────────────────────────

@testset "record_figure: legacy meta.toml still written" begin
    with_fig_vault() do vault, outdir
        path = record_figure(vault; study="test_study", scripts=Dict("x" => "s.jl"))
        @test isfile(path)
        meta = TOML.parsefile(path)
        @test haskey(meta, "source")
        @test meta["scripts"]["x"] == "s.jl"
    end
end
