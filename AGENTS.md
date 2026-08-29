# Repository Operating Contract

## Project Mission

- Learn and reproduce, at small scale, failure effects described in GitHub's public RCA for the 2026-08-17 incident.
- Never claim this lab reproduces GitHub's private architecture or implementation.

## Source Integrity

- Keep `FACT`, `INFERENCE`, `LAB_IMPLEMENTATION`, and `UNKNOWN` distinct.
- Do not present unconfirmed topology, settings, or algorithms as GitHub facts.
- Label sample numbers as `example`, `planned`, or `target`; never as measured results.
- Cite primary sources for incident claims.

## Scope Discipline

- Implement the minimum needed to prove the current learning goal.
- Do not introduce technology before its roadmap phase.
- Avoid unrelated refactors and speculative abstractions.
- Add no dependency unless the standard library or an existing dependency is insufficient.

## Engineering

- Read existing code and local instructions before editing.
- Use explicit image versions; never use `latest`.
- Keep public metrics low-cardinality and free of request IDs or user input.
- Keep health/readiness behavior independent from injected faults.
- Keep the public workload plane separate from the admin control plane.
- Treat admin credentials as secrets: never log, label, or save them in evidence.

## Verification

- Run tests relevant to every change.
- Run `make verify` before declaring a learning unit complete.
- Review the final diff for scope, secrets, generated files, and misleading claims.
- Update affected documentation with behavior changes.

## Git

- Never implement directly on `main` or `master`.
- Use one feature branch per learning unit.
- Use small Conventional Commits and keep unrelated changes separate.
- Commit only after the corresponding verification passes.
- Do not push, merge, rebase, force-push, or amend unless explicitly requested.

## Environment Safety

- Do not run `sudo`, package managers, or `curl | sh`.
- Do not auto-install missing system tools or alter system repositories.
- Do not provision or destroy Azure resources from this repository without explicit scope.
- Never commit secrets, credentials, kubeconfigs, state files, or local environment files.

## Evidence

- Never overwrite a result directory.
- Record reproducibility metadata without secrets or full personal paths.
- Preserve failed experiments as evidence.
- Generated results remain ignored by default; only `results/README.md` is tracked.
