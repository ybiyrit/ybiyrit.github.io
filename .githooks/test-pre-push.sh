#!/usr/bin/env bash
# -*- mode: sh -*-
# vi: set ft=sh ff=unix fenc=utf-8
# shellcheck shell=bash
#
# ---
# name: test-pre-push
# version: v1.18
# created: 2026-08-02
# created_by: cl-bs
# updated: 2026-10-01
# updated_by: cl-bs
# description: regression suite for .githooks/pre-push; builds throwaway repos in a tempdir and asserts what the hook blocks and what it lets through. v1.3 adds coverage for the fixture marker's markdown form and the new-ref path base, merged from a parallel line into the v1.7 hook. v1.4 adds coverage for the eight v1.8 security fixes: basic-auth redaction (content scan and PII sweep), merge-commit scanning via first-parent diff, per-remote new-ref exclusion, the fixture marker's whole-line match, non-ASCII path scanning, the exact-path catalogue exclusion, content-aware already-published detection, and check-1 userinfo redaction with a slash. v1.5 adds coverage for the v1.9 already-published fix: a blob swapped to a real secret and back within one range still blocks, content recreated identical to the base blob still warns, a deletion-only range still warns, a new-ref blob matching a later-sorted remote branch still warns (not just the first-sorted one), and a new-ref blob matching no base still blocks. v1.6 adds coverage for the remaining v1.9 fixes that had none: a push target given as a bare URL redacts on every REMOTE_DISPLAY output line, not just the check-1 refusal; the PII sweep masks the full check-2 catalogue (not only URL userinfo) before re-reading ADDED content, so a token immediately followed by "@domain" is not printed twice; a remote name carrying a glob or pipe character is refused outright; redact_url() and the generic basic-auth URL pattern go greedy past a second userinfo "@" and accept an empty password; a fixture marker's trailing whitespace before the marker still exempts the line, in both comment and markdown form; and the fail-closed rev-list abort names `git fetch` when a --force push's remote sha is not yet in this clone. v1.9 merges the main line's suite (v1.7 to v1.8): check 3 on a PR forge with a parsed, case-folded host and trailing root dots, the long credential URL that outlasts the pipe buffer, a deletion that passes and an addition that still blocks, a rename to a harmless name that blocks, a quoted non-ASCII path and a file added in the merge commit itself. v1.10 adds the v2.0 lineage's case that main lacked: a fixture marker mid-line does not exempt the token after it. v1.12 resolves a relative PRE_PUSH_HOOK before the first cd. v1.13 covers that relative branch with a case of its own. v1.14 makes that case end to end: a nested run with a relative candidate that records its calls. v1.15 lets the literal secret-scan companion follow the marker and proves a token after the companion still blocks. v1.16 pins the hook v1.18 fixes: a basic-auth password with an "@", query-string and ghu_/ghs_/ghr_ URL credentials, fixture markers scoped to their file and ref, copy detection, control characters and double quotes in names, an unreadable stdin, .env.<suffix> files, git-lfs for a pushed LFS ref and a token on a line starting with "++". v1.17 drops internal host names from the comments. v1.18 pins the hook v1.20 fixes: .env template names with any suffix, a refused push when git skips rename detection, and fixture keys under a user diff prefix.
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
IFS=$'\n\t'

# Defaults to the sibling hook, which is the installed master, so a bare run
# tests what actually executes. PRE_PUSH_HOOK points it at a candidate
# instead, which is the only way to test a change BEFORE installing it.
# Without the override, a candidate run silently re-tested the installed hook
# and reported a pass for code it had never read. Measured 2026-09-28 while
# grafting a hook the suite never saw.
# absolute before any cd: _setup_repo changes into a throwaway repository,
# where a relative candidate named nothing (design-system#99 review). a case
# at the end covers the relative branch, which a bare run and make lint never
# take.
_absolute_path() {
    if [[ "${1}" == /* ]]; then printf '%s' "${1}"; else printf '%s/%s' "${PWD}" "${1}"; fi
}
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_DIR
HOOK="$(_absolute_path "${PRE_PUSH_HOOK:-${SELF_DIR}/pre-push}")"
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
    # -b main on the BARE repo too. Without it the remote's HEAD follows the
    # machine's init.defaultBranch, so on a host that still defaults to master
    # a clone of this remote checks out nothing and the case that clones it
    # fails with "src refspec main does not match any". Passed on a
    # main-defaulting workstation, failed on a master-defaulting CI runner.
    git init -q --bare -b main "${ROOT}/remote.git"
    git init -q -b main "${ROOT}/work"
    cd "${ROOT}/work"
    git config user.email "test@example.invalid"
    git config user.name "test"
    git config commit.gpgsign false
    mkdir -p .githooks
    cp "${HOOK}" .githooks/pre-push
    # cp preserves the source mode, and git silently IGNORES a hook that is
    # not executable: it prints an advice line to stderr and runs the push
    # unguarded, so the suite reports a pass for every case whose guard never
    # executed. A candidate written by a redirect is mode 644. Measured
    # 2026-09-28: 45 of 105 cases "passed" that way.
    chmod +x .githooks/pre-push
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

    # the fixture marker exempts a line by its TIP text, not just the commit
    # that introduced it: a token added unmarked in one commit and marked
    # afterwards is still scanned in its unmarked form by the range walk, so
    # the exemption has to read the marker at the tip and reproduce the
    # pre-marker line exactly. markdown marks with `<!-- pre-push: fixture -->`,
    # not `#`, and a strip that only knows `#`/`;` leaves a dangling `<!--`
    # that never matches the unmarked line.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'TOKEN=ghp_%s\n' "$(printf 'D%.0s' {1..36})" > NOTES.md
    git add NOTES.md
    git commit -qm "token in markdown, unmarked"
    printf 'TOKEN=ghp_%s <!-- pre-push: fixture -->\n' "$(printf 'D%.0s' {1..36})" > NOTES.md
    git add NOTES.md
    git commit -qm "mark it as a fixture, markdown form"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o14")"
    _check "fixture marked afterwards in markdown is honoured" 0 "${rc}"

    # same shape, never marked: the marker machinery must not read as a
    # global weakening of the content scan.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'TOKEN=ghp_%s\n' "$(printf 'E%.0s' {1..36})" > README.md
    git add README.md
    git commit -qm "token in markdown, unmarked, never fixed up"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o15")"
    _check "unmarked markdown token still blocked" 1 "${rc}"

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

    # a push that creates a new remote ref has no remote-side sha, so its
    # base for "already published" must be every branch the remote has, not
    # just none. with push.default=current a branch whose upstream has
    # another name always pushes as a new ref, and a path every remote
    # branch already carries must not read as newly published just because
    # THIS ref is new. name-only also lists a path the range only DELETES.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'not actually a key\n' > server.pem
    git add server.pem
    git commit -qm "add pem on main"
    # bypass to seed the fixture: the hook correctly blocks server.pem's own
    # arrival on main (see "secret-shaped filename blocked" above), so the
    # documented escape hatch is the only way to get it onto the remote for
    # this scenario to publish it FROM.
    git push -q --no-verify origin main 2>/dev/null
    git checkout -qb feature
    git rm -q server.pem
    git commit -qm "remove pem on feature"
    rc="$(_rc git push -q origin feature 2>"${ROOT}/o12")"
    _check "new ref deleting a path every remote branch has is allowed" 0 "${rc}"
    _expect_output "already-published path warned, not blocked" yes "remote already has" "${ROOT}/o12"

    # a path no remote branch has yet must still block on a new ref: falling
    # back to "every branch" must not become "any branch passes it".
    _setup_repo
    git push -q origin main 2>/dev/null
    git checkout -qb feature2
    printf 'not actually a key\n' > only-here.pem
    git add only-here.pem
    git commit -qm "add pem only on the new branch"
    rc="$(_rc git push -q origin feature2 2>"${ROOT}/o13")"
    _check "new ref with a path no remote branch has is still blocked" 1 "${rc}"
    _expect_output "newly published path reported" yes "newly published" "${ROOT}/o13"

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

    # a blocked URL may carry a second secret in its query string.
    rc="$(_rc bash "${HOOK}" leaky "https://someone:hunter2@example.invalid/r.git?access_token=qtok7" < /dev/null 2>"${ROOT}/o11q")"
    _check "credential URL with a query token blocks the push" 1 "${rc}"
    _expect_output "query token not echoed" no "qtok7" "${ROOT}/o11q"
    _expect_output "path kept beside the masked query" yes "example.invalid/r.git" "${ROOT}/o11q"

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
    # not reproduced against v1.6 on one workstation, so this case passes
    # on both.
    # the credential sits early and a long path follows, so grep matches in
    # its first read and exits while printf is still writing; 100000 bytes
    # outlast the 64 KiB pipe buffer and stay under the 128 KiB argv limit
    _setup_repo
    local long_path
    long_path="$(printf 'p%.0s' {1..100000})"
    rc="$(_rc bash "${HOOK}" leaky "https://someone:hunter2@example.invalid/${long_path}" < /dev/null 2>"${ROOT}/m1")"
    _check "long credential URL still blocks (no SIGPIPE pass)" 1 "${rc}"

    # v1.7 check 3 on a PR forge. the hook reads ref updates on stdin, so feed
    # one directly: "<local ref> <local sha> <remote ref> <remote sha>".
    _setup_repo
    local head_sha zero
    head_sha="$(git rev-parse HEAD)"
    zero="0000000000000000000000000000000000000000"
    rc="$(_rc bash "${HOOK}" origin "git@GITHUB.COM:owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m2")"
    _check "upper-case GITHUB.COM main push refused" 1 "${rc}"
    _expect_output "refusal names the direct push" yes "refusing a direct push" "${ROOT}/m2"

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    rc="$(_rc bash "${HOOK}" origin "https://github.com/owner/repo.git" \
        <<< "refs/heads/trunk ${head_sha} refs/heads/trunk ${zero}" 2>"${ROOT}/m3")"
    _check "remote default branch trunk refused" 1 "${rc}"

    rc="$(_rc bash "${HOOK}" origin "https://notgithub.com.example/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m4")"
    _check "a host that only contains github.com is not a PR forge" 0 "${rc}"

    rc="$(_rc bash "${HOOK}" origin "https://github.com/owner/repo.git" \
        <<< "refs/heads/feature ${head_sha} refs/heads/feature ${zero}" 2>"${ROOT}/m5")"
    _check "feature branch push to github allowed" 0 "${rc}"

    # v1.8: the host is parsed, so github.com in a PATH is not a PR forge,
    # and GitHub's ssh-over-443 host and an https userinfo still are
    # -q: the ref may be absent, and errexit must not end the suite here
    git symbolic-ref -q --delete refs/remotes/origin/HEAD || true
    rc="$(_rc bash "${HOOK}" origin "https://git.example/github.com/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m6")"
    _check "github.com as a path segment is not a PR forge" 0 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "ssh://git@ssh.github.com:443/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m7")"
    _check "ssh.github.com main push refused" 1 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "https://someone@github.com/owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m8")"
    _check "https userinfo form main push refused" 1 "${rc}"
    # v1.10: the root dot names the same host
    rc="$(_rc bash "${HOOK}" origin "https://github.com./owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m9")"
    _check "trailing-dot github.com. main push refused" 1 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "git@ssh.github.com.:owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m10")"
    _check "trailing-dot ssh.github.com. main push refused" 1 "${rc}"
    rc="$(_rc bash "${HOOK}" origin "https://github.com../owner/repo.git" \
        <<< "refs/heads/main ${head_sha} refs/heads/main ${zero}" 2>"${ROOT}/m11")"
    _check "two trailing dots main push refused" 1 "${rc}"

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
    rc="$(_rc git push -q origin cleanup 2>"${ROOT}/m12")"
    _check "deleting a published secret-shaped path passes" 0 "${rc}"
    printf 'k\n' > id_rsa
    git add id_rsa
    git commit -qm "add a key name"
    rc="$(_rc git push -q origin cleanup 2>"${ROOT}/m13")"
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
    rc="$(_rc git push -q origin rename 2>"${ROOT}/m14")"
    _check "renaming a secret-shaped path to a harmless name blocks" 1 "${rc}"
    _expect_output "rename reported under both names" yes "id_rsa renamed to backup.txt" "${ROOT}/m14"

    # v1.11: git quotes a non-ASCII path; the quotes must not hide the name
    _setup_repo
    git switch -q -c quoted
    mkdir -p "schlüssel"
    printf 'k\n' > "schlüssel/id_rsa"
    git add "schlüssel/id_rsa"
    git commit -qm "add a key under a non-ascii directory"
    rc="$(_rc git push -q origin quoted 2>"${ROOT}/m15")"
    _check "a quoted non-ascii secret-shaped path blocks" 1 "${rc}"

    # v1.11: a file added in the merge commit itself is scanned
    _setup_repo
    git switch -q -c side
    printf 's\n' > side.md
    git add side.md
    git commit -qm "side"
    git switch -q main
    git switch -q -c evil
    printf 'm\n' >> readme.md
    git commit -qam "m2"
    git merge -q --no-ff --no-commit side
    printf 'k\n' > id_rsa
    git add id_rsa
    git commit -qm "merge with an added key"
    rc="$(_rc git push -q origin evil 2>"${ROOT}/m16")"
    _check "a secret-shaped path added in a merge commit blocks" 1 "${rc}"

    # manual invocation without args is a no-op, not a check of origin.
    # only stderr is silenced: _rc reports the exit code on stdout, and
    # redirecting that would capture nothing (the hook writes its usage
    # to stderr, so stdout stays clean for the code).
    rc="$(_rc bash "${HOOK}" 2>/dev/null)"
    _check "manual no-arg invocation is a no-op" 0 "${rc}"

    # v1.8 fix 1 (check 2): a basic-auth credential in pushed CONTENT used to
    # leak twice: the content-scan redaction sliced the MATCH into a 4+4
    # prefix/suffix, which for a short match leaks the password's tail
    # ("er2@"); and the advisory PII sweep re-read the unmasked ADDED lines,
    # so the email-shaped part of "user:hunter2@host" printed the password in
    # full a second time. two files, two shapes of the same defect.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'endpoint: ftp://user:hunter2@example.com\n' > ftp-leak.txt
    printf 'contact bob:pw@example.com for access\n' > basic-auth.txt
    git add ftp-leak.txt basic-auth.txt
    git commit -qm "basic-auth credentials in content"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o20")"
    _check "basic-auth content blocked" 1 "${rc}"
    _expect_output "password not echoed by the content-scan redaction" no "hunter2" "${ROOT}/o20"
    _expect_output "content-scan redaction does not leak a trailing slice" no "er2@" "${ROOT}/o20"
    _expect_output "second credential fragment not echoed" no ":pw@" "${ROOT}/o20"
    _expect_output "match shown as a whole redaction, not a slice" yes "REDACTED" "${ROOT}/o20"

    # v1.8 fix 2 (check 2): --no-merges dropped merge commits from BOTH git
    # log walks, so content added only while resolving a merge (a conflict
    # resolution, or `merge --no-commit --no-ff` then `git add`) was never
    # diffed and never scanned. --diff-merges=first-parent still shows what
    # the merge changed relative to the branch it landed on.
    _setup_repo
    git push -q origin main 2>/dev/null
    git checkout -qb side
    printf 'side content\n' > side.txt
    git add side.txt
    git commit -qm "side commit"
    git checkout -q main
    git merge -q --no-commit --no-ff side
    printf 'TOKEN=ghp_%s\n' "$(printf 'F%.0s' {1..36})" > leak.txt
    printf 'not actually a key\n' > leak.pem
    git add leak.txt leak.pem
    git commit -qm "merge side, resolve with a leak"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o21")"
    _check "content added while resolving a merge is scanned" 1 "${rc}"
    _expect_output "merge-added token reported" yes "secret-shaped content added" "${ROOT}/o21"
    _expect_output "merge-added filename reported" yes "secret-shaped path" "${ROOT}/o21"

    # a clean merge (nothing added during the merge itself) must stay allowed;
    # first-parent diffing a merge is not the same as blocking every merge.
    _setup_repo
    git push -q origin main 2>/dev/null
    git checkout -qb side2
    printf 'side2 content\n' > side2.txt
    git add side2.txt
    git commit -qm "side2 commit"
    git checkout -q main
    git merge -q --no-ff side2 -m "merge side2 cleanly"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o22")"
    _check "clean merge still allowed" 0 "${rc}"

    # v1.8 fix 3: a new-ref push used to exclude commits reachable from ANY
    # configured remote's tracking refs (`--not --remotes`), not just the
    # remote being pushed to. a token already fetched from origin then read
    # as "covered" on the first push of the same commit to a second remote
    # that had never seen it. seed the token via a hook-less clone (plain
    # `git clone` carries no core.hooksPath), fetch it into the guarded work
    # tree, then push the same history to a brand-new second remote.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        printf 'TOKEN=ghp_%s\n' "$(printf 'G%.0s' {1..36})" > seeded-token.txt
        git add seeded-token.txt
        git commit -qm "seed token, no hook here"
        git push -q origin main
    )
    git fetch -q origin
    git merge -q --ff-only origin/main
    git init -q --bare "${ROOT}/pub.git"
    git remote add pub "${ROOT}/pub.git"
    rc="$(_rc git push -q pub main 2>"${ROOT}/o23")"
    _check "a token already on origin still blocks a first push to a second remote" 1 "${rc}"
    _expect_output "content flagged for the second remote" yes "secret-shaped content added" "${ROOT}/o23"

    # pushing a clean new branch to the same second remote must still work;
    # the fix scopes the exclusion, it does not remove it.
    git checkout -qb clean-branch main~1
    rc="$(_rc git push -q pub clean-branch 2>"${ROOT}/o24")"
    _check "clean new branch to the second remote still allowed" 0 "${rc}"

    # v1.8 fix 4: the fixture marker's exemption used to be a substring test
    # (`grep -vFf`, no -x), so a marked placeholder whose stripped text was a
    # PREFIX of an unrelated real secret line waved the real secret through
    # too. real.txt reuses the same "export GITHUB_TOKEN=ghp_" prefix as the
    # marked line in tmpl.md, with a real 36-char token appended.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'export GITHUB_TOKEN=ghp_ <!-- pre-push: fixture -->\n' > tmpl.md
    printf 'export GITHUB_TOKEN=ghp_%s\n' "$(printf 'J%.0s' {1..36})" > real.txt
    git add tmpl.md real.txt
    git commit -qm "template plus a real leak sharing its prefix"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o25")"
    _check "fixture prefix does not exempt an unrelated real secret" 1 "${rc}"

    # the marked template on its own, with no unrelated line to smuggle past
    # it, is still exempt.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'export GITHUB_TOKEN=ghp_ <!-- pre-push: fixture -->\n' > tmpl.md
    git add tmpl.md
    git commit -qm "template alone"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o26")"
    _check "marked template alone allowed" 0 "${rc}"

    # v1.8 fix 5: a non-ASCII path was octal-quoted ("\303\244-key.pem") by
    # git's default core.quotePath, which put a closing quote right after the
    # extension and defeated every `\.ext$` branch of SECRET_PATH_PATTERN.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'not actually a key\n' > 'ä-key.pem'
    git add 'ä-key.pem'
    git commit -qm "non-ASCII secret filename"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o27")"
    _check "non-ASCII secret filename blocked" 1 "${rc}"
    _expect_output "non-ASCII path reported" yes "secret-shaped path" "${ROOT}/o27"

    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'just some notes\n' > 'ä-notes.txt'
    git add 'ä-notes.txt'
    git commit -qm "non-ASCII harmless filename"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o28")"
    _check "non-ASCII harmless filename allowed" 0 "${rc}"

    # v1.8 fix 6: a `**/<basename>` glob in SCAN_EXCLUDE_PATHS matched that
    # basename at ANY depth, so an attacker-planted `anywhere/<basename>`
    # was excluded from the content scan too. the exclusion is now exact
    # repo-relative paths.
    _setup_repo
    git push -q origin main 2>/dev/null
    mkdir -p anywhere
    printf 'TOKEN=ghp_%s\n' "$(printf 'K%.0s' {1..36})" > anywhere/check-hook-guards.sh
    git add anywhere/check-hook-guards.sh
    git commit -qm "planted basename at another depth"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o29")"
    _check "a catalogue basename planted at another depth is not exempt" 1 "${rc}"
    _expect_output "planted-path content flagged" yes "secret-shaped content added" "${ROOT}/o29"

    # the real excluded path (repo root, matching SCAN_EXCLUDE_PATHS exactly)
    # must still skip the content scan, or the fix is a global tightening
    # wearing a narrow disguise.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'TOKEN=ghp_%s\n' "$(printf 'K%.0s' {1..36})" > check-hook-guards.sh
    git add check-hook-guards.sh
    git commit -qm "real excluded path"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o30")"
    _check "the real excluded path still skips the content scan" 0 "${rc}"
    _expect_output "skipped content scan reported" yes "content scan skipped" "${ROOT}/o30"

    # v1.8 fix 7: "already published" used to mean the PATH existed at the
    # base, not that its CONTENT did, so a placeholder secret-shaped file
    # could be swapped for the real thing and only warn. seed a placeholder
    # via a hook-less clone, then exercise a changed blob at the tip.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        printf 'placeholder\n' > api.token
        git add api.token
        git commit -qm "seed placeholder secret path, no hook here"
        git push -q origin main
    )
    git fetch -q origin
    git merge -q --ff-only origin/main
    printf 'REALSECRETVALUE\n' > api.token
    git add api.token
    git commit -qm "swap the placeholder for a real secret"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o31")"
    _check "changed content at an already-published secret path blocks" 1 "${rc}"
    _expect_output "changed content reported as newly published" yes "newly published" "${ROOT}/o31"

    # v1.9 fix: the check above compared only the TIP blob to the base, so a
    # placeholder swapped for a real secret and swapped BACK within the same
    # range compared equal at the tip and only warned, even though the real
    # blob sits in an intermediate commit of the pushed history. every
    # commit in the range that touches the path is now resolved, not just
    # the tip.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        printf 'placeholder\n' > api.token
        git add api.token
        git commit -qm "seed placeholder secret path, no hook here"
        git push -q origin main
    )
    git fetch -q origin
    git merge -q --ff-only origin/main
    printf 'REALSECRETVALUE\n' > api.token
    git commit -qam "swap the placeholder for a real secret"
    printf 'placeholder\n' > api.token
    git commit -qam "swap it back before the tip"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o32")"
    _check "a blob swapped to a real secret and back within the range still blocks" 1 "${rc}"
    _expect_output "intermediate blob reported as newly published" yes "newly published" "${ROOT}/o32"

    # content that genuinely never leaves the base's blob is still allowed:
    # delete the path, then recreate it with byte-identical content. git
    # gives the recreated blob the SAME object sha as the original (content
    # addressing), so this is the "every range blob is already in the base
    # set" branch, not the "path is only deleted" one: the path IS touched
    # by a non-deleting commit here, and that commit's blob is still known.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        printf 'placeholder\n' > api.token
        git add api.token
        git commit -qm "seed placeholder secret path, no hook here"
        git push -q origin main
    )
    git fetch -q origin
    git merge -q --ff-only origin/main
    git rm -q api.token
    git commit -qm "delete api.token"
    printf 'placeholder\n' > api.token
    git add api.token
    git commit -qm "recreate api.token with the identical published content"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o33")"
    _check "content recreated identical to the base blob is allowed" 0 "${rc}"
    _expect_output "already-has warning shown for unchanged content" yes "remote already has" "${ROOT}/o33"

    # a path only deleted in the range publishes nothing new, whatever base
    # it started from.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        printf 'placeholder\n' > api.token
        git add api.token
        git commit -qm "seed placeholder secret path, no hook here"
        git push -q origin main
    )
    git fetch -q origin
    git merge -q --ff-only origin/main
    git rm -q api.token
    git commit -qm "delete the already-published secret path"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o34")"
    _check "deleting an already-published secret path is allowed" 0 "${rc}"
    _expect_output "already-has warning shown for deletion" yes "remote already has" "${ROOT}/o34"

    # v1.9 fix: the check stopped at the FIRST remote base (sorted by
    # refname) that held the path, so branch sort order, not the actual
    # publication history, decided whether a blob counted as known. seed
    # two remote branches with two different blobs for the same
    # secret-shaped path ("a" before "b" by refname), then push a brand-new
    # third branch whose blob matches "b", the LATER-sorted one: it must
    # still warn, because every base is now checked, not only the first.
    _setup_repo
    git push -q origin main 2>/dev/null
    rm -rf "${ROOT}/hookless"
    git clone -q "${ROOT}/remote.git" "${ROOT}/hookless"
    (
        cd "${ROOT}/hookless"
        git config user.email "test@example.invalid"
        git config user.name "test"
        git config commit.gpgsign false
        git checkout -qb a
        printf 'A\n' > foo.key
        git add foo.key
        git commit -qm "blob A on branch a"
        git push -q origin a
        git checkout -qb b main
        printf 'B\n' > foo.key
        git add foo.key
        git commit -qm "blob B on branch b"
        git push -q origin b
    )
    git fetch -q origin
    git checkout -qb c origin/main
    printf 'B\n' > foo.key
    git add foo.key
    git commit -qm "same blob as origin/b, pushed as a new ref"
    rc="$(_rc git push -q origin c 2>"${ROOT}/o35")"
    _check "a new-ref blob matching a later-sorted remote branch warns, not blocks" 0 "${rc}"
    _expect_output "already-has warning shown for the matching blob" yes "remote already has" "${ROOT}/o35"

    # same two-branch base, but the pushed blob matches NEITHER: checking
    # every base (the fix above) must not turn into "any base passes it".
    git checkout -qb d origin/main
    printf 'C\n' > foo.key
    git add foo.key
    git commit -qm "blob matching no base, pushed as a new ref"
    rc="$(_rc git push -q origin d 2>"${ROOT}/o36")"
    _check "a new-ref blob matching no base still blocks" 1 "${rc}"
    _expect_output "unmatched blob reported as newly published" yes "newly published" "${ROOT}/o36"

    # v1.8 low-severity cleanup: check-1's redaction excluded "/" from the
    # userinfo character class, so a userinfo containing a slash broke the
    # sed match entirely and the whole URL, token included, was echoed
    # verbatim. exclude only "@", the delimiter that ends the userinfo.
    _setup_repo
    rc="$(_rc bash "${HOOK}" leaky "https://u%3Aghp_x/y@example.invalid/r.git" < /dev/null 2>"${ROOT}/o34")"
    _check "credential URL with a slash in userinfo blocks the push" 1 "${rc}"
    _expect_output "userinfo token fragment not echoed" no "ghp_x" "${ROOT}/o34"
    _expect_output "userinfo redacted" yes "REDACTED" "${ROOT}/o34"

    # v1.9 fix (item 2): a push target given as a bare URL ($1 with no
    # configured remote name: git's own contract is "if a named remote is
    # not being used both values will be the same") used to reach every
    # output line that prints REMOTE_DISPLAY verbatim, including the
    # "remote:" line inside a check-1 refusal: the one place a URL is most
    # likely to carry the credential that triggered the refusal in the
    # first place.
    _setup_repo
    rc="$(_rc bash "${HOOK}" "https://user:hunter2@example.invalid/r.git" "https://user:hunter2@example.invalid/r.git" < /dev/null 2>"${ROOT}/o40")"
    _check "URL push target blocks the push" 1 "${rc}"
    _expect_output "password not echoed when \$1 is the URL" no "hunter2" "${ROOT}/o40"
    _expect_output "userinfo redacted" yes "REDACTED" "${ROOT}/o40"
    _expect_output "host still identifiable" yes "example.invalid" "${ROOT}/o40"

    # same fix, reached through a real push instead of a direct hook call.
    # url.<base>.insteadOf rewrites the TRANSPORT target (so the push
    # actually lands locally), but git still passes the ORIGINAL argument as
    # $1; the rewritten $2 carries no credential, so this exercises
    # REMOTE_DISPLAY on the "scanning" line independently of check 1.
    _setup_repo
    FAKE_URL="https://user:hunter2@example.invalid/r.git"
    git config "url.file://${ROOT}/remote.git.insteadOf" "${FAKE_URL}"
    rc="$(_rc git push -q "${FAKE_URL}" main 2>"${ROOT}/o41")"
    _check "push to a URL target with insteadOf rewriting succeeds" 0 "${rc}"
    _expect_output "password not echoed in the scanning line" no "hunter2" "${ROOT}/o41"
    _expect_output "userinfo redacted in the scanning line" yes "REDACTED" "${ROOT}/o41"
    _expect_output "host still identifiable in the scanning line" yes "example.invalid" "${ROOT}/o41"

    # v1.9 fix (item 3): the PII sweep used to mask only URL userinfo before
    # re-reading ADDED lines, so a blocked token sitting directly in front of
    # an "@domain.tld" in plain, non-URL content printed the token in full a
    # second time under an advisory heading.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_L="$(printf 'L%.0s' {1..36})"
    printf 'contact=ghp_%s@example.invalid\n' "${TOK_L}" > pii-adjacent.txt
    git add pii-adjacent.txt
    git commit -qm "token immediately followed by an email-shaped domain"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o42")"
    _check "token adjacent to an email domain blocks the push" 1 "${rc}"
    _expect_output "full token not echoed under the PII heading" no "ghp_${TOK_L}" "${ROOT}/o42"
    _expect_output "content scan still reports the token" yes "secret-shaped content" "${ROOT}/o42"

    # the same fix must not turn the PII sweep into a no-op: a plain email
    # with no adjacent secret pattern still warns.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'reach alice@example.invalid for details\n' > pii-plain.txt
    git add pii-plain.txt
    git commit -qm "plain personal email"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o43")"
    _check "plain email push allowed" 0 "${rc}"
    _expect_output "plain email still warned" yes "personal identifier" "${ROOT}/o43"

    # v1.9 fix (item 4): a remote name carrying *, ?, [ or | changes how this
    # hook scopes its OWN scan, as a glob in the new-ref exclusion
    # (--glob=refs/remotes/NAME/*) or by breaking the "|"-packed range
    # string, so it is refused outright before either mechanism runs.
    # reachable via `git config remote.<name>.url` naming an odd remote,
    # not just argv.
    _setup_repo
    git push -q origin main 2>/dev/null
    git config "remote.*.url" "${ROOT}/remote.git"
    rc="$(_rc git push '*' main 2>"${ROOT}/o44")"
    _check "remote name '*' is refused" 1 "${rc}"
    _expect_output "refusal names the scoping reason" yes "changes how this hook scopes its scan" "${ROOT}/o44"

    _setup_repo
    git push -q origin main 2>/dev/null
    git config "remote.a|b.url" "${ROOT}/remote.git"
    rc="$(_rc git push 'a|b' main 2>"${ROOT}/o45")"
    _check "remote name 'a|b' is refused" 1 "${rc}"
    _expect_output "refusal names the scoping reason" yes "changes how this hook scopes its scan" "${ROOT}/o45"

    # an ordinary remote name is unaffected by the guard.
    printf 'more3\n' >> readme.md
    git commit -qam "more3"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o46")"
    _check "ordinary remote name origin still allowed" 0 "${rc}"

    # v1.9 fix (item 5): redact_url() and the check-1 refusal used to stop at
    # the FIRST "@" in a userinfo, leaking everything after a second one.
    _setup_repo
    rc="$(_rc bash "${HOOK}" leaky "https://user:p@ss@example.invalid/r.git" < /dev/null 2>"${ROOT}/o47")"
    _check "userinfo with a second @ blocks the push" 1 "${rc}"
    _expect_output "password fragment before the second @ not echoed" no "p@ss" "${ROOT}/o47"
    _expect_output "password tail after the second @ not echoed" no "ss@" "${ROOT}/o47"
    _expect_output "userinfo redacted" yes "REDACTED" "${ROOT}/o47"

    # the generic basic-auth pattern used to require a non-empty password, so
    # "user:@host" was not basic-auth shaped; a token as the username with an
    # empty password and an unescaped second "@" right after it matched
    # neither the known-token pattern (needs "@" right after the token) nor
    # the old basic-auth pattern.
    TOK_M="$(printf 'M%.0s' {1..36})"
    rc="$(_rc bash "${HOOK}" leaky "https://ghp_${TOK_M}:@x@example.invalid/r.git" < /dev/null 2>"${ROOT}/o48")"
    _check "token userinfo with an empty password and a second @ blocks the push" 1 "${rc}"
    _expect_output "token not echoed" no "ghp_${TOK_M}" "${ROOT}/o48"

    # v1.9 fix (item 6): a fixture-marked line with trailing whitespace
    # before its marker could not be exempted, because the diff-added
    # unmarked copy kept its trailing spaces while the TIP copy's marker-strip
    # trimmed them, and the whole-line compare never matched. "append the
    # marker, do not reflow the line" means the trailing spaces the unmarked
    # commit had stay right where they were.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_N="$(printf 'N%.0s' {1..36})"
    printf 'TOKEN=ghp_%s   \n' "${TOK_N}" > ws-hash.sh
    git add ws-hash.sh
    git commit -qm "hash-comment fixture candidate, unmarked, trailing whitespace"
    printf 'TOKEN=ghp_%s   # pre-push: fixture\n' "${TOK_N}" > ws-hash.sh
    git add ws-hash.sh
    git commit -qm "mark it, hash-comment form, trailing whitespace preserved"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o49")"
    _check "fixture marked after trailing whitespace, hash-comment form, is honoured" 0 "${rc}"

    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_P="$(printf 'P%.0s' {1..36})"
    printf 'TOKEN=ghp_%s   \n' "${TOK_P}" > ws-md.md
    git add ws-md.md
    git commit -qm "markdown fixture candidate, unmarked, trailing whitespace"
    printf 'TOKEN=ghp_%s   <!-- pre-push: fixture -->\n' "${TOK_P}" > ws-md.md
    git add ws-md.md
    git commit -qm "mark it, markdown form, trailing whitespace preserved"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o50")"
    _check "fixture marked after trailing whitespace, markdown form, is honoured" 0 "${rc}"

    # the marker must END the line. A substring test exempted any added line
    # that merely contained the text, so a real token could ride along in the
    # part after it.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_M="$(printf 'M%.0s' {1..36})"
    printf 'note pre-push: fixture and then TOKEN=ghp_%s\n' "${TOK_M}" > midline.sh
    git add midline.sh
    git commit -qm "marker mid-line with a live token after it"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o65")"
    _check "a marker mid-line does not exempt what follows it" 1 "${rc}"

    # the end-of-line rule must not start to require a comment introducer:
    # whitespace alone before the marker still exempts the line.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_B="$(printf 'B%.0s' {1..36})"
    printf 'TOKEN=ghp_%s   pre-push: fixture\n' "${TOK_B}" > bare.sh
    git add bare.sh
    git commit -qm "marker introduced by whitespace alone, no comment character"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o66")"
    _check "a marker introduced by whitespace alone is still honoured" 0 "${rc}"

    # the companion marker of secret-scan.sh may follow the fixture marker:
    # a redaction library wrote it that way in a published commit.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_C="$(printf 'C%.0s' {1..36})"
    printf 'TOKEN=ghp_%s  # pre-push: fixture, secret-scan:allow\n' "${TOK_C}" > companion.sh
    git add companion.sh
    git commit -qm "fixture marker followed by the secret-scan companion"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o66c")"
    _check "the secret-scan companion after the marker is honoured" 0 "${rc}"

    # ... and only the companion: a token after it still blocks.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_E="$(printf 'E%.0s' {1..36})"
    printf 'x  # pre-push: fixture, secret-scan:allow ghp_%s\n' "${TOK_E}" > companion-tail.sh
    git add companion-tail.sh
    git commit -qm "companion marker with a live token after it"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o66d")"
    _check "a token after the companion marker still blocks" 1 "${rc}"

    # same shape, never marked: the trim must not become a global weakening
    # that exempts any token with trailing whitespace.
    _setup_repo
    git push -q origin main 2>/dev/null
    TOK_Q="$(printf 'Q%.0s' {1..36})"
    printf 'TOKEN=ghp_%s   \n' "${TOK_Q}" > ws-unmarked.sh
    git add ws-unmarked.sh
    git commit -qm "trailing whitespace, never marked"
    rc="$(_rc git push -q origin main 2>"${ROOT}/o51")"
    _check "unmarked token with trailing whitespace still blocked" 1 "${rc}"

    # item 7: a failed rev-list (the common cause is a --force push whose
    # remote sha was never fetched into this clone) must abort with a reason
    # naming `git fetch`, not read as "0 commits, nothing to scan". this is
    # the v1.4 fail-closed guard, not a v1.9 fix, so it predates the range
    # under test above; it has simply never had a test of its own.
    _setup_repo
    git push -q origin main 2>/dev/null
    LOCAL_SHA="$(git rev-parse HEAD)"
    UNKNOWN_SHA="$(printf '%040d' 1234567890)"
    rc="$(_rc bash "${HOOK}" origin "${ROOT}/remote.git" \
        < <(printf '%s %s %s %s\n' "refs/heads/main" "${LOCAL_SHA}" "refs/heads/main" "${UNKNOWN_SHA}") \
        2>"${ROOT}/o52")"
    _check "an unfetched remote sha refuses the push" 1 "${rc}"
    _expect_output "abort reason names fetching the remote" yes "fetch the remote" "${ROOT}/o52"

    # v1.16 (hook v1.18): the review findings on hook v1.17.
    local TOK_H
    TOK_H="$(printf 'H%.0s' {1..36})"

    # (a) a password containing "@": the content redaction stopped at the
    # first "@", and the PII sweep printed the rest as an e-mail address.
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'url = https://user:pw@tailsecret9@example.invalid/r\n' > at-pass.txt
    git add at-pass.txt
    git commit -qm "basic-auth password with an at sign"
    rc="$(_rc git push -q origin main 2>"${ROOT}/h1")"
    _check "(a) basic-auth URL with an @ in the password blocks" 1 "${rc}"
    _expect_output "(a) password tail not echoed" no "tailsecret9" "${ROOT}/h1"

    # (b) a token in the query string, with no userinfo at all
    for QS in "access_token=${TOK_H}" "token=${TOK_H}" "private_token=${TOK_H}"; do
        rc="$(_rc bash "${HOOK}" leaky "https://example.invalid/r.git?${QS}" < /dev/null 2>"${ROOT}/h2")"
        _check "(b) query-string credential '${QS%%=*}=' blocks" 1 "${rc}"
        _expect_output "(b) query-string token not echoed" no "${TOK_H}" "${ROOT}/h2"
    done

    # (c) a fixture marked in one file exempts that file only
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'TOKEN=ghp_%s  # pre-push: fixture\n' "${TOK_H}" > marked.sh
    printf 'TOKEN=ghp_%s\n' "${TOK_H}" > other.sh
    git add marked.sh other.sh
    git commit -qm "same token, marked in one file only"
    rc="$(_rc git push -q origin main 2>"${ROOT}/h3")"
    _check "(c) a fixture marker does not exempt another file" 1 "${rc}"

    # (c) and the tip of one ref does not exempt another ref
    _setup_repo
    git push -q origin main 2>/dev/null
    git switch -q -c unmarked
    printf 'TOKEN=ghp_%s\n' "${TOK_H}" > same.sh
    git add same.sh
    git commit -qm "token, never marked on this ref"
    git switch -q main
    git switch -q -c marked
    printf 'TOKEN=ghp_%s  # pre-push: fixture\n' "${TOK_H}" > same.sh
    git add same.sh
    git commit -qm "token, marked on this ref"
    rc="$(_rc git push -q origin marked unmarked 2>"${ROOT}/h4")"
    _check "(c) a fixture marker does not exempt another ref" 1 "${rc}"

    # (d) a copy of a secret-shaped path counts under both names
    _setup_repo
    printf 'k\nk\nk\n' > id_rsa
    git add id_rsa
    git commit -qm "publish a key name"
    git push -q --no-verify origin main 2>/dev/null
    git switch -q -c copy
    cp id_rsa backup.txt
    git add backup.txt
    git commit -qm "copy the key to a harmless name"
    rc="$(_rc git push -q origin copy 2>"${ROOT}/h5")"
    _check "(d) copying a secret-shaped path to a harmless name blocks" 1 "${rc}"
    _expect_output "(d) copy reported under both names" yes "id_rsa copied to backup.txt" "${ROOT}/h5"

    # (e) git C-quotes a name with a control character or a double quote
    # even with core.quotePath=false, and the closing quote hid the extension
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'k\n' > $'esc\033[2Jname.pem'
    git add -A
    git commit -qm "control character in a key name"
    rc="$(_rc git push -q origin main 2>"${ROOT}/h6")"
    _check "(e) a path with a control character blocks" 1 "${rc}"
    _expect_output "(e) the control character is not echoed raw" no $'\033' "${ROOT}/h6"
    _setup_repo
    git push -q origin main 2>/dev/null
    printf 'k\n' > 'quo"te.pem'
    git add -A
    git commit -qm "double quote in a key name"
    rc="$(_rc git push -q origin main 2>"${ROOT}/h7")"
    _check "(e) a secret-shaped path with a double quote blocks" 1 "${rc}"

    # (f) an unreadable stdin (here a directory, which read(2) refuses with
    # EISDIR) is not an empty ref-update list
    _setup_repo
    rc="$(_rc bash "${HOOK}" origin "${ROOT}/remote.git" < / 2>"${ROOT}/h8")"
    _check "(f) an unreadable stdin refuses the push" 1 "${rc}"

    # (g) .env.<anything> is secret-shaped; .env.example and .env.sample are not
    local ENV_NAME ENV_WANT
    for ENV_NAME in .env.local:1 app/.env.production:1 .env.example:0 .env.sample:0; do
        ENV_WANT="${ENV_NAME##*:}"
        ENV_NAME="${ENV_NAME%:*}"
        _setup_repo
        git push -q origin main 2>/dev/null
        mkdir -p "$(dirname "${ENV_NAME}")"
        printf 'PORT=8080\n' > "${ENV_NAME}"
        git add -f "${ENV_NAME}"
        git commit -qm "add ${ENV_NAME}"
        rc="$(_rc git push -q origin main 2>"${ROOT}/h9")"
        _check "(g) ${ENV_NAME} rc=${ENV_WANT}" "${ENV_WANT}" "${rc}"
    done

    # (h) git-lfs runs when a PUSHED ref uses LFS, whatever the checkout holds
    _setup_repo
    git push -q origin main 2>/dev/null
    mkdir -p "${ROOT}/fakebin"
    printf '#!/bin/sh\ncat > /dev/null\n: > %q\n' "${ROOT}/lfs-called" > "${ROOT}/fakebin/git-lfs"
    chmod +x "${ROOT}/fakebin/git-lfs"
    rm -f "${ROOT}/lfs-called"
    git switch -q -c lfs
    printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
    git add .gitattributes
    git commit -qm "track binaries in lfs"
    git switch -q main
    rc="$(_rc env GIT_CONFIG_GLOBAL=/dev/null PATH="${ROOT}/fakebin:${PATH}" git push -q origin lfs 2>"${ROOT}/h10")"
    _check "(h) push of an LFS ref from a non-LFS checkout passes" 0 "${rc}"
    if [[ -f "${ROOT}/lfs-called" ]]; then
        printf '[pass] (h) git-lfs pre-push ran for the pushed LFS ref\n'
        _PASS=$(( _PASS + 1 ))
    else
        printf '[fail] (h) git-lfs pre-push ran for the pushed LFS ref\n'
        _FAIL=$(( _FAIL + 1 ))
    fi

    # (i) every GitHub token prefix in a URL userinfo, not only gho_ and ghp_
    local PFX
    for PFX in ghu_ ghs_ ghr_; do
        rc="$(_rc bash "${HOOK}" leaky "https://${PFX}${TOK_H}@example.invalid/r.git" < /dev/null 2>"${ROOT}/h11")"
        _check "(i) ${PFX} token in a URL userinfo blocks" 1 "${rc}"
    done

    # an added line that itself starts with "++" reads as "+++" in the diff,
    # which the header filter dropped unscanned
    _setup_repo
    git push -q origin main 2>/dev/null
    printf '++TOKEN=ghp_%s\n' "${TOK_H}" > plusplus.txt
    git add plusplus.txt
    git commit -qm "token on a line starting with two plus signs"
    rc="$(_rc git push -q origin main 2>"${ROOT}/h12")"
    _check "a token on a line starting with ++ blocks" 1 "${rc}"

    # v1.18 (hook v1.20): the review findings on hook v1.18.
    # an .env template name passes whatever its suffix order; a value file
    # with a template-looking infix still blocks
    for ENV_NAME in .env.dist:0 .env.template:0 .env.local.example:0 config/.env.example:0 \
        .env.example.local:1; do
        ENV_WANT="${ENV_NAME##*:}"
        ENV_NAME="${ENV_NAME%:*}"
        _setup_repo
        git push -q origin main 2>/dev/null
        mkdir -p "$(dirname "${ENV_NAME}")"
        printf 'PORT=8080\n' > "${ENV_NAME}"
        git add -f "${ENV_NAME}"
        git commit -qm "add ${ENV_NAME}"
        rc="$(_rc git push -q origin main 2>"${ROOT}/j1")"
        _check "${ENV_NAME} rc=${ENV_WANT}" "${ENV_WANT}" "${rc}"
    done

    # past diff.renameLimit git skips exhaustive rename and copy detection
    # with only a warning, and an edited key renamed to a harmless name then
    # reads as a delete plus an unrelated add. with the limit at 1, two
    # inexact renames in one commit are enough to make the warning fire.
    _setup_repo
    printf 'k\nk\nk\nk\nk\n' > id_rsa
    printf 'o\no\no\no\no\n' > other.txt
    git add id_rsa other.txt
    git commit -qm "publish a key name"
    git push -q --no-verify origin main 2>/dev/null
    git config diff.renameLimit 1
    git mv id_rsa backup.txt
    printf 'k\n' >> backup.txt
    git mv other.txt moved.txt
    printf 'o\n' >> moved.txt
    git add backup.txt moved.txt
    git commit -qm "rename the key to a harmless name and edit it"
    rc="$(_rc git push -q origin main 2>"${ROOT}/j2")"
    _check "a skipped rename detection refuses the push" 1 "${rc}"
    _expect_output "the refusal names the rename limit" yes "renameLimit" "${ROOT}/j2"

    # the fixture path key must not depend on the user's diff prefixes
    local PFX_CFG
    for PFX_CFG in diff.dstPrefix=z/ diff.noprefix=true; do
        _setup_repo
        git push -q origin main 2>/dev/null
        mkdir -p b
        printf 'TOKEN=ghp_%s\n' "${TOK_H}" > b/fx.sh
        git add b/fx.sh
        git commit -qm "fixture, not yet marked"
        printf 'TOKEN=ghp_%s  # pre-push: fixture\n' "${TOK_H}" > b/fx.sh
        git add b/fx.sh
        git commit -qm "mark the fixture"
        rc="$(_rc git -c "${PFX_CFG}" push -q origin main 2>"${ROOT}/j3")"
        _check "a fixture marked later still exempts under ${PFX_CFG}" 0 "${rc}"
    done

    # a relative candidate reaches the hook, end to end: the suite runs again
    # with a relative PRE_PUSH_HOOK naming a copy of the hook that records
    # each call, and must pass with the record present. a bare run and make
    # lint pass no candidate, so this is the one run that takes the relative
    # branch (copilot reviews of research-academic#155 and talks#143). the
    # nested run carries a candidate, so it does not nest again.
    if [[ -z "${PRE_PUSH_HOOK:-}" ]]; then
        mkdir "${ROOT}/candidate"
        {
            head -n 1 "${HOOK}"
            printf ': > %q\n' "${ROOT}/candidate/called"
            tail -n +2 "${HOOK}"
        } > "${ROOT}/candidate/pre-push"
        chmod +x "${ROOT}/candidate/pre-push"
        if (cd "${ROOT}" && PRE_PUSH_HOOK=candidate/pre-push bash "${SELF_DIR}/${BASH_SOURCE[0]##*/}" >/dev/null 2>&1) \
           && [[ -f "${ROOT}/candidate/called" ]]; then
            printf '[pass] a relative PRE_PUSH_HOOK reaches the hook\n'
            _PASS=$(( _PASS + 1 ))
        else
            printf '[fail] a relative PRE_PUSH_HOOK reaches the hook\n'
            _FAIL=$(( _FAIL + 1 ))
        fi
    fi

    printf '\n[info] %d passed, %d failed\n' "${_PASS}" "${_FAIL}"
    [[ "${_FAIL}" -eq 0 ]]
}

main "$@"
