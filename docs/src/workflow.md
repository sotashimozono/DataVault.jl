# Experiment workflow

This page is the **canonical 4-stage process** for running and recording a
numerical experiment backed by DataVault.  Consumer projects
(e.g. ReducedEnvExperiments.jl) link here instead of maintaining their
own copy.

Every experiment goes through the same four stages so that purpose /
computation / data / conclusion are linked by a single ID
(`EXP-NNN-slug`).

## Three orthogonal axes

Experiment documentation lives on three independent axes:

| Axis | Who writes | What lives here |
|---|---|---|
| **Narrative** | human | `experiments/EXP-NNN-<slug>/README.md`, `note/STATUS.md`, `note/RESEARCH_PLAN.md` |
| **Provenance** | DataVault (automatic) | `out/data/<project>/<run>/README.md`, `schema.toml`, `figures.toml`, `INDEX.md` |
| **Infrastructure** | DataVault (fixed) | this page, `conventions.md`, the TEMPLATE returned by [`experiment_template`](@ref) |

A clean repository keeps these axes from leaking into each other.
Narrative files **link** to provenance; they do not duplicate it.

## Stage 1 — Plan

Scaffold a new experiment directory in one line:

```julia
using DataVault
vault = Vault("configs/your_config.toml"; run="your-run-name", outdir="out/")
DataVault.new_experiment(
    vault;
    slug="finite-temp-smoke",
    purpose="Confirm the TPQ pipeline runs end-to-end at tiny size.",
    hypothesis="No physical hypothesis; framework test.",
    hypothesis_ref="RQ1",
)
```

This writes
`projects/<P>/experiments/EXP-001-finite-temp-smoke/README.md` from the
TEMPLATE, substituting the supplied metadata and auto-incrementing the
`EXP-NNN` id.  Commit the scaffolded file immediately:

```bash
git add experiments/EXP-001-finite-temp-smoke/
git commit -m "Plan EXP-001: finite-temp-smoke"
```

## Stage 2 — Freeze inputs

Confirm every input is pinned:

1. `git submodule status` shows the submodule SHAs you want.
2. The config TOML is on disk and committed.
3. The DataVault ledger dir (`out/data/<P>/<run>/`) is empty or matches
   the run you are re-attaching to.

DataVault captures the frozen state automatically the first time the
Vault is constructed, via `config_snapshot.toml` and `schema.toml`.  You
do **not** hand-copy git SHAs into the EXP README — [`build_experiment_report`](@ref)
records them for you.

## Stage 3 — Run

Run the compute script:

```bash
julia --project=. scripts/compute.jl configs/your_config.toml
```

DataVault will produce, per run:

- `out/data/<P>/<run>/` — raw JLD2 per key, `ledger.csv`, `config_snapshot.toml`
- `out/figure/<P>/<run>/` — PDFs + `figures.toml` archive
- `out/.datavault/<P>/<run>.log.toml` — discovery anchor

As the run progresses, append dated notes to the **Log** section of
`experiments/EXP-NNN-<slug>/README.md`.

## Stage 4 — Analyze

Run the analysis script to regenerate figures and the machine-readable
run report:

```julia
using DataVault
DataVault.build_experiment_report(
    vault, YourComputeModule;
    experiments_root = "experiments",   # opt-in: links run ↔ EXP-NNN
)
DataVault.build_experiments_index(vault.outdir, "<project>")
DataVault.build_narrative_index("experiments")
```

`build_experiment_report` updates three things:

1. `out/data/<P>/<run>/README.md` — run-level provenance (always).
2. `out/data/<P>/<run>/schema.toml` — writer package / version / data
   schema (first-write-only; later calls are a no-op unless identity
   changes).
3. When `experiments_root` is provided: every EXP-NNN README whose
   front-matter `data_runs` list contains this run's `vault.run` gets
   its `## Generated provenance` section re-written with links back to
   the run report (idempotent).

Fill in **Result summary** and **Conclusion** in the EXP README by hand,
commit, and tag:

```bash
git add experiments/EXP-NNN-<slug>/ out/data/.../README.md
git commit -m "EXP-NNN: <slug> — <one-line conclusion>"
git tag exp/NNN-<slug>
git push origin main exp/NNN-<slug>
```

## Narrative section contents (EXP-NNN README)

After the Stage 1 scaffold you own the following sections.  Everything
else is either machine-generated or small boilerplate:

- **Purpose** — one paragraph, what physical / methodological question
  this experiment answers.  Reference the RQ it targets.
- **Hypothesis** — falsifiable prediction, or explicit "exploratory".
- **Design** — parameter sweep summary, list of observables + references.
- **Log** — dated entries written during the run.
- **Result summary** — bulleted numbers / observations.
- **Conclusion** — 1–3 sentences: hypothesis confirmed / rejected /
  inconclusive.
- **Next actions** — checkbox list.
- **Cross-references** — link to the RQ in `note/RESEARCH_PLAN.md` and
  any related prior experiments.

The top `## Generated provenance` section is **owned by DataVault** —
do not edit it by hand.

## Anti-patterns

- Copying git SHAs into the EXP README (they live in
  `schema.toml.writer.parent_git_hash`; DataVault maintains the link).
- Hand-editing the `## Generated provenance` section.
- Using `docs/src/results/EXP-NNN.md` as a separate "published" tier.
  EXP-NNN/README.md is the single narrative source.
- Running experiments before scaffolding the EXP directory
  (Purpose / Hypothesis go in *before* the run).
- Deleting an EXP directory when rerunning — instead, create
  `EXP-(NNN+1)` that cites the old one.

## Versioning

DataVault-backed projects follow SemVer:

| Change | Bump |
|---|---|
| New bench field / breaking `data_schema_version` increment | minor (while 0.y) |
| Analysis script bug fix | patch |
| New experiment module under `src/` | minor |
| Submodule pointer update | usually patch |

Cut a `vX.Y.Z` tag after every batch of publication-ready experiments.
