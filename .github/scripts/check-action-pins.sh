#!/usr/bin/env bash
# vi: ft=bash ts=4 sw=4 et
# shellcheck shell=bash
# check-action-pins.sh v1.0 created 2607 cl-bs
# SPDX-License-Identifier: Apache-2.0
#
# Enforces the GitHub Actions pinning discipline from research-general
# conventions/tech-stack-and-versions.md section 3.1: every `uses:` line must
# reference a 40-character commit SHA, not a tag. Tags are mutable, SHAs are not.
#
# This file is copied verbatim into every workspace repo that runs workflows,
# so it must not assume where it sits: repos with a bin/ keep it there, the
# rest carry it as .github/scripts/check-action-pins.sh.
#
# Three failure classes are reported separately, because they fail differently:
#   mutable   `uses: actions/checkout@v4` - upstream can retag under us
#   empty     `uses: actions/checkout@`   - valid YAML, fails only at run time,
#             the signature of an unset variable in a pinning script
#   bare      pinned SHA with no `# vX.Y.Z` comment - immutable but unreadable,
#             so nobody can tell whether the pin has gone stale
#
# Local actions (`./path`) and reusable workflows (`org/repo/.github/...@sha`)
# are covered by the same rule; docker:// refs are skipped as out of scope.
#
# Usage:
#   bash bin/check-action-pins.sh                 # this repo
#   bash bin/check-action-pins.sh --all-repos     # every sibling repo in ~/src/ybiyrit
#   bash bin/check-action-pins.sh --strict        # bare pins fail too, not just warn

set -o errexit -o nounset -o pipefail -o errtrace
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# git decides the root, so bin/ and .github/scripts/ copies behave identically;
# the parent-directory fallback covers a copy run outside a checkout.
if ! REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"

scope_all_repos=0
strict=0

for arg in "$@"; do
    case "$arg" in
        --all-repos) scope_all_repos=1 ;;
        --strict)    strict=1 ;;
        -h|--help)
            printf 'usage: %s [--all-repos] [--strict]\n' "$(basename "$0")" >&2
            exit 0
            ;;
        *)
            printf '[error] unknown arg: %s\n' "$arg" >&2
            exit 1
            ;;
    esac
done

count_mutable=0
count_empty=0
count_bare=0
count_pinned=0

# checks one workflow file; prints a line per offending ref
check_file() {
    local file="$1" label="$2"
    local line_no ref line

    while IFS= read -r line; do
        line_no="${line%%:*}"
        ref="${line#*:}"
        # strip everything up to and including `uses:` plus surrounding space
        ref="${ref#*uses:}"
        ref="${ref#"${ref%%[![:space:]]*}"}"

        case "$ref" in
            docker://*|./*)
                continue
                ;;
        esac

        if [[ "${ref}" =~ @([0-9a-f]{40})([[:space:]]|$) ]]; then
            if [[ "${ref}" =~ \#[[:space:]]*v[0-9] ]]; then
                count_pinned=$((count_pinned + 1))
            else
                count_bare=$((count_bare + 1))
                printf '[warn]  %s:%s bare pin, no version comment: %s\n' \
                    "${label}" "${line_no}" "${ref%% #*}"
            fi
        elif [[ "${ref}" =~ @[[:space:]] ]] || [[ "${ref}" =~ @$ ]] || [[ "${ref}" =~ @\# ]]; then
            count_empty=$((count_empty + 1))
            printf '[error] %s:%s empty ref, fails only at run time: %s\n' \
                "${label}" "${line_no}" "${ref}"
        else
            count_mutable=$((count_mutable + 1))
            printf '[error] %s:%s mutable tag: %s\n' \
                "${label}" "${line_no}" "${ref}"
        fi
    done < <(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "${file}" 2>/dev/null || true)
}

# walks every workflow file under one repo
check_repo() {
    local repo_dir="$1" repo_name="$2"
    local file found=0

    for file in "${repo_dir}"/.github/workflows/*.yml "${repo_dir}"/.github/workflows/*.yaml; do
        [[ -f "${file}" ]] || continue
        found=1
        check_file "${file}" "${repo_name}/$(basename "${file}")"
    done

    [[ "${found}" -eq 1 ]] || printf '[info]  %s: no workflow files\n' "${repo_name}"
}

printf '[info]  action pin audit, convention: tech-stack-and-versions.md 3.1\n'

if [[ "${scope_all_repos}" -eq 1 ]]; then
    for dir in "${WORKSPACE_ROOT}"/*; do
        [[ -d "${dir}/.git" || -f "${dir}/.git" ]] || continue
        check_repo "${dir}" "$(basename "${dir}")"
    done
else
    check_repo "${REPO_ROOT}" "$(basename "${REPO_ROOT}")"
fi

printf '[info]  pinned with version comment: %s\n' "${count_pinned}"
[[ "${count_bare}" -gt 0 ]] && printf '[warn]  bare pins (no version comment): %s\n' "${count_bare}"

if [[ "${count_mutable}" -gt 0 || "${count_empty}" -gt 0 ]]; then
    printf '[fail]  mutable: %s, empty: %s\n' "${count_mutable}" "${count_empty}"
    exit 1
fi

if [[ "${strict}" -eq 1 && "${count_bare}" -gt 0 ]]; then
    printf '[fail]  bare pins present and --strict given\n'
    exit 1
fi

printf '[pass]  every uses: ref is a 40-character commit SHA\n'
