---
id: "EXP-{{id}}"
slug: "{{slug}}"
status: "planning"
author: "{{author}}"
started: "{{today}}"
hypothesis_ref: "{{hypothesis_ref}}"
data_runs: []
---

# EXP-{{id}} — {{slug}}

## Generated provenance

<!-- Maintained by DataVault.build_experiment_report.  Do not edit by hand. -->

*(No completed runs yet.  Run `scripts/compute.jl` and then call
`DataVault.build_experiment_report(vault, <writer>; experiments_root=…)`
to have this block populated.)*

## Purpose

{{purpose}}

## Hypothesis

{{hypothesis}}

## Design

- **Parameter sweep**:
- **Key observables** (→ `note/OBSERVABLES.md`):
- **References**:

## Log

_Append dated entries as the run progresses._

- {{today}} — experiment scaffolded via `DataVault.new_experiment`.

## Result summary

## Conclusion

## Next actions

- [ ]

## Cross-references

- Hypothesis targeted: `{{hypothesis_ref}}` in `note/RESEARCH_PLAN.md`
- Related prior experiments:
