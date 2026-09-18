#!/usr/bin/env bash
# Checks that the L10 portfolio package is not stale or broken. This does not
# re-measure any experiment; it verifies package integrity (required docs,
# curated repetition counts, destroy-contract residual, evidence link
# existence, and the absence of private paths, credential-like content, or
# the known L07/L08 curated-index label swap).
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

fail=0
note() { printf '%-60s %s\n' "$1" "$2"; }
check_fail() { note "$1" 'FAIL'; fail=1; }
check_ok() { note "$1" 'OK'; }

# 1. Required portfolio docs exist and are non-empty.
for doc in docs/portfolio.md docs/demo-runbook.md results/curated/README.md README.md \
	docs/roadmap.md docs/architecture.md; do
	if [[ -s "${doc}" ]]; then
		check_ok "required doc present: ${doc}"
	else
		check_fail "required doc present: ${doc}"
	fi
done

# 2. L06-L09 curated evidence has at least 3 selected repetitions each.
for unit in l06 l07 l08 l09; do
	count=0
	if [[ -d "results/curated/${unit}" ]]; then
		count="$(find "results/curated/${unit}" -maxdepth 1 -type d -name 'repetition-*' | wc -l | tr -d ' ')"
	fi
	if [[ "${count}" -ge 3 ]]; then
		check_ok "${unit} curated repetitions >= 3 (found ${count})"
	else
		check_fail "${unit} curated repetitions >= 3 (found ${count})"
	fi
done

# 3. L09 destroy contract must show zero residual owned resources.
readonly L09_DESTROY_CONTRACT='results/curated/l09/destroy-contract.json'
if [[ -f "${L09_DESTROY_CONTRACT}" ]] && command -v jq >/dev/null 2>&1 \
	&& jq -e '.residual_owned_resources == 0 and .confirmed_absent == true' "${L09_DESTROY_CONTRACT}" >/dev/null 2>&1; then
	check_ok 'L09 destroy contract residual_owned_resources == 0'
else
	check_fail 'L09 destroy contract residual_owned_resources == 0'
fi

# 4. Every results/curated/ link referenced from the portfolio docs must
#    resolve to a real path.
missing_links=0
while IFS= read -r link; do
	target="${link#*](}"
	target="${target%)}"
	target="${target%%#*}"
	resolved="docs/${target}"
	[[ "${target}" == /* ]] && resolved="${target#/}"
	if [[ ! -e "${resolved}" ]]; then
		printf 'missing evidence path referenced from portfolio docs: %s\n' "${target}" >&2
		missing_links=1
	fi
done < <(grep -ohE '\]\([^)]*results/curated/[^)]*\)' docs/portfolio.md docs/demo-runbook.md)
if [[ "${missing_links}" -eq 0 ]]; then
	check_ok 'all results/curated/ links referenced from portfolio docs resolve'
else
	check_fail 'all results/curated/ links referenced from portfolio docs resolve'
fi

# 5. No private absolute filesystem paths in L10-owned docs.
readonly L10_DOCS=(docs/portfolio.md docs/demo-runbook.md README.md docs/architecture.md \
	docs/roadmap.md results/curated/README.md scripts/verify-l10-portfolio.sh)
if grep -nE '/home/[A-Za-z0-9_.-]+|/Users/[A-Za-z0-9_.-]+' "${L10_DOCS[@]}" >&2; then
	check_fail 'no private absolute paths in L10-owned docs'
else
	check_ok 'no private absolute paths in L10-owned docs'
fi

# 6. No credential-like content in L10-owned docs.
if grep -nEi 'authorization:[[:space:]]*bearer[[:space:]]+[A-Za-z0-9._-]{8,}|ghp_[0-9A-Za-z]{20,}|gho_[0-9A-Za-z]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "${L10_DOCS[@]}" >&2; then
	check_fail 'no credential-like content in L10-owned docs'
else
	check_ok 'no credential-like content in L10-owned docs'
fi

# 7. results/curated/README.md index must not carry the known L07/L08 label
#    swap (L07 must read RCA Mitigations, L08 must read Chaos Mesh
#    Reproduction, matching docs/roadmap.md).
readonly CURATED_INDEX='results/curated/README.md'
if grep -q 'L07 — RCA Mitigations' "${CURATED_INDEX}" \
	&& grep -q 'L08 — Chaos Mesh Reproduction' "${CURATED_INDEX}" \
	&& ! grep -q 'L07 — Chaos Mesh Reproduction' "${CURATED_INDEX}" \
	&& ! grep -q 'L08 — Toxiproxy Reproduction' "${CURATED_INDEX}"; then
	check_ok 'curated index L07/L08 titles match roadmap'
else
	check_fail 'curated index L07/L08 titles match roadmap'
fi

# 8. Roadmap consistency guard: L10 must not be marked Complete while L09
#    is not yet Complete (prevents a premature status flip before L09 merges).
if awk '
	/^## L09 /  { unit = "l09" }
	/^## L10 /  { unit = "l10" }
	/^## L11 /  { unit = "" }
	unit == "l09" && /- \*\*Status:\*\*/ { l09_complete = ($0 ~ /\*\*Status:\*\* Complete/) }
	unit == "l10" && /- \*\*Status:\*\*/ { l10_complete = ($0 ~ /\*\*Status:\*\* Complete/) }
	END { exit (l10_complete && !l09_complete) ? 1 : 0 }
' docs/roadmap.md; then
	check_ok 'L10 roadmap status does not outrun L09'
else
	check_fail 'L10 roadmap status does not outrun L09'
fi

# 9. This script itself must be valid bash.
if bash -n "${BASH_SOURCE[0]}"; then
	check_ok 'verify-l10-portfolio.sh bash syntax'
else
	check_fail 'verify-l10-portfolio.sh bash syntax'
fi

exit "${fail}"
