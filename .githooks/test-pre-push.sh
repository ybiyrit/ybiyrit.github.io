#!/usr/bin/env bash
# -*- mode: sh -*-
# vi: set ft=sh ff=unix fenc=utf-8
# shellcheck shell=bash
#
# ---
# name: test-pre-push
# version: v1.6
# created: 2026-08-02
# created_by: cl-bs
# updated: 2026-09-25
# updated_by: cl-bs
# description: regression suite for .githooks/pre-push; builds throwaway repos in a tempdir and asserts what the hook blocks and what it lets through
# type: test
# ---
#
#  Copyright 2026 the original author or authors.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       https://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# a guard that blocks a legitimate push is worse than no guard, so the
# suite asserts BOTH directions: real pushes stay allowed, planted
# material gets blocked. every fixture uses obviously-fake placeholder
# values (runs of A/B), never a real credential shape with real entropy.
#
# the suite caught a real defect on first run: the strict-mode
# IFS=$'\n\t' stopped `read` from splitting git's space-separated ref
# updates, so every sha arrived empty, the range collapsed to `..`, and
# the hook passed everything while reporting success.
#
# usage: .githooks/test-pre-push.sh   (exit 0 = all assertions passed)

set -o errexit -o nounset -o pipefail -o errtrace

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-push"
readonly HOOK
ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

_PASS=0
_FAIL=0

# compare an expected exit code against the observed one
_check() {
    local name="${1}" want="${2}" got="${3}"
    if [[ "${want}" == "${got}" ]]; then
        printf '[pass] %s\n' "${name}"
        _PASS=$(( _PASS + 1 ))
    else
        printf '[fail] %s (expected rc=%s, got rc=%s)\n' "${name}" "${want}" "${got}"
        _FAIL=$(( _FAIL + 1 ))
    fi
}

# assert a string is present (want=yes) or absent (want=no) in a file
_expect_output() {
    local name="${1}" want="${2}" needle="${3}" file="${4}"
    local found="no"
    grep -q -- "${needle}" "${file}" 2>/dev/null && found="yes"
    if [[ "${found}" == "${want}" ]]; then
        printf '[pass] %s\n' "${name}"
        _PASS=$(( _PASS + 1 ))
    else
        printf '[fail] %s (expected %s, got %s)\n' "${name}" "${want}" "${found}"
        _FAIL=$(( _FAIL + 1 ))
    fi
}

# fresh bare remote + work tree with the hook installed
_setup_repo() {
    rm -rf "${ROOT}/work" "${ROOT}/remote.git"
    git init -q --bare "${ROOT}/remote.git"
    git init -q -b main "${ROOT}/work"
    cd "${ROOT}/work"
    git config user.email "test@example.invalid"
    git config user.name "test"
    git config commit.gpgsign false
    mkdir -p .githooks
    cp "${HOOK}" .githooks/pre-push
    git config core.hooksPath .githooks
    git remote add origin "${ROOT}/remote.git"
    printf 'hello\n' > readme.md
    git add readme.md
    git commit -q -m "init"
}

_rc() {
    local rc=0
    "$@" || rc=$?
    printf '%s' "${rc}"
}

main() {
    local rc

    # a first push to an empty remote takes the new-ref path
    _setup_repo
    rc="$(_rc git push -q origin main 2>"${ROOT}/o1")"
    _check "clean first push allowed" 0 "${rc}"
    _expect_output "success line printed" yes "pre-push: no secret-shaped" "${ROOT}/o1"

    printf 'more\n' >> readme.md
    git commit -qam "more"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o2")"
    _check "clean incremental push allowed" 0 "${rc}"

    # planted token, fake by construction
    printf 'TOKEN=ghp_%s\n' "$(printf 'A%.0s' {1..36})" > leak.txt
    git add leak.txt
    git commit -qm "oops"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o3")"
    _check "token in content blocked" 1 "${rc}"
    _expect_output "token reported" yes "secret-shaped content" "${ROOT}/o3"
    _expect_output "match redacted, not echoed" no "ghp_AAAA" "${ROOT}/o3"

    # removing it in a later commit does not un-publish it
    git rm -q leak.txt
    git commit -qm "remove it"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o4")"
    _check "add-then-remove still blocked" 1 "${rc}"

    # the catalogue that defines the patterns is excluded from the CONTENT
    # scan, because every earlier revision of it in the range carries the
    # pre-evasion spelling and would block the push forever. the exclusion
    # is path-scoped: the same token one directory away must still block, or
    # it is a global weakening wearing a narrow disguise.
    _setup_repo
    git push -q origin main 2>/dev/null
    mkdir -p claude/hooks
    printf 'TOKEN=ghp_%s\n' "$(printf 'C%.0s' {1..36})" > claude/hooks/block-dangerous-commands.sh
    git add claude/hooks/block-dangerous-commands.sh
    git commit -qm "catalogue"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o8")"
    _check "token in catalogue source allowed" 0 "${rc}"
    _expect_output "skipped content scan reported" yes "content scan skipped" "${ROOT}/o8"

    printf 'TOKEN=ghp_%s\n' "$(printf 'C%.0s' {1..36})" > notes.txt
    git add notes.txt
    git commit -qm "same token, ordinary path"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o9")"
    _check "same token outside the catalogue still blocked" 1 "${rc}"

    # the NAME alone is disqualifying, whatever the content is
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'not actually a key\n' > server.pem
    git add server.pem
    git commit -qm "add pem"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o5")"
    _check "secret-shaped filename blocked" 1 "${rc}"
    _expect_output "path reported" yes "secret-shaped path" "${ROOT}/o5"

    # personal identifiers are advisory: a dotfiles repo is full of them
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'contact: someone@example.com via 10.0.1.61\n' > contact.md
    git add contact.md
    git commit -qm "contact"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o6")"
    _check "personal identifiers allowed" 0 "${rc}"
    _expect_output "personal identifiers warned" yes "personal identifier" "${ROOT}/o6"

    # a deletion publishes nothing and must not error
    _setup_repo
    git push -q origin main 2>/dev/null
    git push -q origin HEAD:refs/heads/doomed 2>/dev/null
    rc="$(_rc git push -q origin :refs/heads/doomed 2>"${ROOT}/o7")"
    _check "deletion of a real remote branch allowed" 0 "${rc}"
    _expect_output "deletion did not crash the hook" no "line .*: " "${ROOT}/o7"

    # documented escape hatch: git bypasses hooks entirely
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'TOKEN=ghp_%s\n' "$(printf 'B%.0s' {1..36})" > leak2.txt
    git add leak2.txt
    git commit -qm "bypass"
    rc="$(_rc git push -q --no-verify origin main 2>/dev/null)"
    _check "--no-verify bypasses, as documented" 0 "${rc}"

    # a credential-bearing remote URL matched check 1, so by construction the
    # URL holds the secret. the refusal must not echo it back: that copies the
    # leak into scrollback, CI logs and screen recordings.
    _setup_repo
    rc="$(_rc bash "${HOOK}" leaky "https://someone:hunter2@example.invalid/r.git" < /dev/null 2>"${ROOT}/o11")"
    _check "credential URL blocks the push" 1 "${rc}"
    _expect_output "password not echoed" no "hunter2" "${ROOT}/o11"
    _expect_output "userinfo redacted" yes "REDACTED" "${ROOT}/o11"
    _expect_output "host still identifiable" yes "example.invalid" "${ROOT}/o11"

    # v1.4 fail-closed paths. a guard that can only be reached by breaking the
    # repository is the one most likely to be wrong, so exercise the reachable
    # end of it: an unresolvable remote means check 1 cannot run, and "cannot
    # run" must refuse rather than skip.
    _setup_repo
    rc="$(_rc bash "${HOOK}" no-such-remote "" < /dev/null 2>"${ROOT}/o10")"
    _check "unresolvable remote URL refuses the push" 1 "${rc}"
    _expect_output "refusal names the reason" yes "cannot verify this push" "${ROOT}/o10"

    # v1.7: a credential URL long enough to outlast the pipe buffer. a
    # regression guard for the here-string: the SIGPIPE pass it prevents was
    # not reproduced against v1.6 on fry1, so this case passes on both.
    # the credential sits early and a long path follows, so grep matches in
    # its first read and exits while printf is still writing; 100000 bytes
    # outlast the 64 KiB pipe buffer and stay under the 128 KiB argv limit
    _setup_repo
    local long_path
    long_path="$(printf 'p%.0s' {1..100000})"
    rc="$(_rc bash "${HOOK}" leaky "https://someone:hunter2@example.invalid/${long_path}" < /dev/null 2>"${ROOT}/o12")"
    _check "long credential URL still blocks (no SIGPIPE pass)" 1 "${rc}"

    # v1.7 check 3 on a PR forge. the hook reads ref updates on stdin, so feed
    # one directly: "<local ref> <local sha> <remote ref> <remote sha>".
    _setup_repo
    local head_sha zero
    head_sha="$(git rev-parse HEAD)"
    zero="0000000000000000000000000000000000000000"
    rc="$(_rc bash "${HOOK}" origin "git@GITHUB.COM:owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o13")"
    _check "upper-case GITHUB.COM main push refused" 1 "${rc}"
    _expect_output "refusal names the direct push" yes "refusing a direct push" "${ROOT}/o13"

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    rc="$(_rc bash "${HOOK}" origin "https://github.com/owner/repo.git" \
        <<< "refs/heads/trunk ${head_sha} refs/heads/trunk ${zero}" 2>"${ROOT}/o14")"
    _check "remote default branch trunk refused" 1 "${rc}"

    rc="$(_rc bash "${HOOK}" origin "https://notgithub.com.example/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o15")"
    _check "a host that only contains github.com is not a PR forge" 0 "${rc}"

    rc="$(_rc bash "${HOOK}" origin "https://github.com/owner/repo.git" \
        <<< "refs/heads/feature ${head_sha} refs/heads/feature ${zero}" 2>"${ROOT}/o16")"
    _check "feature branch push to github allowed" 0 "${rc}"

    # v1.8: the host is parsed, so github.com in a PATH is not a PR forge,
    # and GitHub's ssh-over-443 host and an https userinfo still are
    # -q: the ref may be absent, and errexit must not end the suite here
    git symbolic-ref -q --delete refs/remotes/origin/HEAD || true
    rc="$(_rc bash "${HOOK}" origin "https://git.example/github.com/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o17")"
    _check "github.com as a path segment is not a PR forge" 0 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "ssh://git@ssh.github.com:443/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o18")"
    _check "ssh.github.com main push refused" 1 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "https://someone@github.com/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o19")"
    _check "https userinfo form main push refused" 1 "${rc}"
    # v1.10: the root dot names the same host
    rc="$(_rc bash "${HOOK}" origin "https://github.com./owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o19b")"
    _check "trailing-dot github.com. main push refused" 1 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "git@ssh.github.com.:owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/o19c")"
    _check "trailing-dot ssh.github.com. main push refused" 1 "${rc}"

    # v1.9: removing a published secret-shaped path is the remediation and
    # must pass; the scan used to list deleted paths and refused it
    _setup_repo
    mkdir -p etc/ssh
    printf 'PermitRootLogin no\n' > etc/ssh/published.conf
    git add etc/ssh/published.conf
    git commit -qm "publish a secret-shaped path"
    git push -q --no-verify origin main 2>/dev/null
    git switch -q -c cleanup
    git rm -q etc/ssh/published.conf
    git commit -qm "delete the published path"
    rc="$(_rc git push -q origin cleanup 2>"${ROOT}/o20")"
    _check "deleting a published secret-shaped path passes" 0 "${rc}"
    printf 'k\n' > id_rsa
    git add id_rsa
    git commit -qm "add a key name"
    rc="$(_rc git push -q origin cleanup 2>"${ROOT}/o21")"
    _check "adding a secret-shaped path still blocks" 1 "${rc}"

    # v1.10: a rename carries the secret-shaped source name, so moving a key
    # to a harmless name in one commit still blocks (claude-bocuse#6 review)
    _setup_repo
    printf 'k\nk\nk\n' > id_rsa
    git add id_rsa
    git commit -qm "publish a key name"
    git push -q --no-verify origin main 2>/dev/null
    git switch -q -c rename
    git mv id_rsa backup.txt
    git commit -qm "rename the key to a harmless name"
    rc="$(_rc git push -q origin rename 2>"${ROOT}/o22")"
    _check "renaming a secret-shaped path to a harmless name blocks" 1 "${rc}"

    # manual invocation without args is a no-op, not a check of origin.
    # only stderr is silenced: _rc reports the exit code on stdout, and
    # redirecting that would capture nothing (the hook writes its usage
    # to stderr, so stdout stays clean for the code).
    rc="$(_rc bash "${HOOK}" 2>/dev/null)"
    _check "manual no-arg invocation is a no-op" 0 "${rc}"

    printf '\n[info] %d passed, %d failed\n' "${_PASS}" "${_FAIL}"
    [[ "${_FAIL}" -eq 0 ]]
}

main "$@"
