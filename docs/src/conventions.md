# Documentation conventions

DataVault-backed projects keep documentation on **three orthogonal axes**.
This page is the canonical definition of which axis owns what — consumer
repositories link here instead of writing their own regulations.

## Axis 1 — Narrative (human)

The "why" of the project: research questions, hypotheses, per-experiment
reasoning.  Files live in the consumer repository and are hand-edited.

| File | Scope | What goes in it |
|---|---|---|
| `note/RESEARCH_PLAN.md` | monorepo | Cross-project research questions (`RQ1`, `RQ2`, …).  Problem setting, success criteria, which project owns each RQ. |
| `projects/<P>/note/STATUS.md` | per-project | Rolling status, project-local hypotheses (reference RQs by number), TODO, known issues, update log. |
| `projects/<P>/note/OBSERVABLES.md` | per-project | The measurement × reference convention: which quantities we measure, against which exact solution / ED / QAtlas reference, and the `data_schema_version` that produces them. |
| `projects/<P>/experiments/EXP-NNN-<slug>/README.md` | per-experiment | Purpose / Hypothesis / Design / Log / Result summary / Conclusion / Next actions. |

**Rules:**

- RQs are **defined** in `RESEARCH_PLAN.md` and **referenced** elsewhere.
  Do not copy RQ definitions into `STATUS.md`.
- `OBSERVABLES.md` is updated whenever the `bench.jl` schema
  (`data_schema_version`) changes.
- EXP-NNN READMEs are the single narrative source per experiment — no
  separate `docs/src/results/` tier.

## Axis 2 — Provenance (DataVault, automatic)

The "what ran when" layer: config snapshots, git hashes, run progress,
figures, schema.  Entirely produced by DataVault; **never hand-edited**.

| File | Written by | Purpose |
|---|---|---|
| `out/data/<P>/<run>/README.md` | `build_experiment_report` | Per-run machine report: identity, code versions, config summary, ledger progress, event timings, figure index, schema. |
| `out/data/<P>/<run>/schema.toml` | `build_experiment_report` (first-write-only) | Writer package / version / data_schema_version / introspected JLD2 keys.  Never overwritten; new writer identities spill to `schema.toml.vN`. |
| `out/data/<P>/INDEX.md` | `build_experiments_index` | Per-run row: snapshot, completed count, parent git hash, latest activity. |
| `out/data/<P>/<run>/config_snapshot.toml` | Vault constructor (first-write-only) | Exact TOML the run was launched with. |
| `out/data/<P>/<run>/ledger.csv` | `build_ledger` | Per-completed-key row with git hash, timestamp, tag value. |
| `out/figure/<P>/<run>/figures.toml` | `archive_figure!` | Append-only figure version chain with SHA-1 dedup. |
| `out/.datavault/<P>/<run>.log.toml` | Vault constructor | Frozen discovery anchor (`log_toml_version` contract). |

**Rules:**

- Every provenance file is idempotent.  Re-running the compute + analyze
  scripts must not corrupt them.
- Narrative files **link** to provenance; they never duplicate.
- Deleting a file in `out/` is permitted (data layer), but deleting
  anything under `out/.datavault/` breaks discovery.

## Axis 3 — Infrastructure (DataVault, fixed)

Shared workflow / TEMPLATE / regulations — owned by DataVault and
**not replicated** per project.

| File / API | Location | Role |
|---|---|---|
| `experiment_template()` | `DataVault` | Returns the canonical `EXP-NNN/README.md` template string. |
| [`new_experiment`](@ref) | `DataVault` | Scaffolds `experiments/EXP-NNN-<slug>/README.md` with auto-incrementing ID. |
| [`build_narrative_index`](@ref) | `DataVault` | Parses front-matter across `experiments/EXP-*/README.md` into an aggregated markdown table. |
| `docs/src/workflow.md` | DataVault docs | Canonical 4-stage process (Plan / Freeze / Run / Analyze). |
| `docs/src/conventions.md` | DataVault docs | This page. |

**Rules:**

- Consumer repos do **not** ship their own `TEMPLATE/` or `WORKFLOW.md`.
  They link to the DataVault docs instead.
- When the workflow evolves, it is updated here (DataVault's docs),
  merged, and consumer repos pick it up by bumping the submodule.

## Why three axes?

Keeping the axes separate makes documentation **sustainable**:

- Changing the physics (new observable, new RQ) touches only Narrative.
- Re-running a compute touches only Provenance (the human text is
  untouched).
- Updating the workflow itself is a DataVault release — consumer repos
  don't need to re-learn the process.

When writing a new file, ask: "which axis owns this?"  If the answer
requires more than one axis, split the file.
