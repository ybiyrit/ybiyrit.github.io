#!/usr/bin/env bash
# -*- mode: sh -*-
# vi: set ft=sh ff=unix fenc=utf-8
# shellcheck shell=bash
#
# ---
# name: test-commit-msg
# version: v1.11.0
# created: 2026-09-08
# created_by: cl-bs
# updated: 2026-10-02
# updated_by: cl-bs
# description: fixture suite for the commit-msg hook; proves each agent token, watermark shape and subject rule is refused for its own reason and that ordinary messages pass
# type: test
# ---

#
#  Copyright 2026 the original author or authors.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# version history (moved out of the description field in v1.7.1):
# v1.6.1 joins the provenance trailer at runtime, so the file carries no
# literal one; v1.6.2 drops a branch name from a comment; v1.7.0 asserts the
# refusal reason and a silent accept; v1.7.1 moves this history out of the
# description field; v1.8.0 covers hook v1.1: comment lines per cleanup mode
# and comment character, and whole-word agent tokens; v1.8.1 covers hook
# v1.2: concatenated vendor names (ClaudeCode, GitHubCopilot, Claude4);
# v1.9.0 covers hook v1.3: all-caps names, core.commentString and its order
# against core.commentChar, a tr_TR locale, and runs every case in an empty
# repository without the caller's git config or editor; v1.10.0 covers hook
# v1.4: every vendor compound in lower case and in capitals; v1.11.0 covers
# hook v1.5: a capital-ending token before a capitalised word (OpenAIAgent).


# a guard list nobody exercises is decoration. the token list is read out of
# the hook rather than restated here, so a token added to the guard without a
# fixture cannot pass unnoticed.

set -o errexit -o nounset -o pipefail -o errtrace
IFS=$'\n\t'

# the hook reads commit.cleanup, the comment string and GIT_EDITOR. the
# caller's values inverted cases: commit.cleanup=verbatim or strip, a global
# core.commentString, or GIT_EDITOR=: in the environment (copilot reviews of
# fietsen#6, flux-compensator#7 and vscode-theme-lau#6). each case sets what
# it needs on top of this empty baseline.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_EDITOR GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SELF_DIR
# Defaults to the sibling hook, which is the installed master, so a bare run
# tests what actually executes. COMMIT_MSG_HOOK points it at a candidate,
# which is the only way to test a change before installing it and the only
# way to prove the crash check below can fire. Its absence in the pre-push
# suite meant every candidate run there silently re-tested the installed
# hook. Measured 2026-09-28.
# absolute before any cd: assert_drive_warn runs the hook from inside a
# throwaway repository, where a relative candidate named nothing (rc=127,
# design-system#99 review). a case at the end covers the relative branch,
# which a bare run and make lint never take.
absolute_path() {
    if [[ "${1}" == /* ]]; then printf '%s' "${1}"; else printf '%s/%s' "${PWD}" "${1}"; fi
}
HOOK="$(absolute_path "${COMMIT_MSG_HOOK:-${SELF_DIR}/commit-msg}")"
readonly HOOK

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
trap 'rm -rf "${WORK_DIR}"' EXIT
# the hook runs inside this empty repository, so the local config of the
# checkout the suite is started from does not reach it either
git init -q "${WORK_DIR}/repo"

FAILURES=0

# check_hook EXPECT NAME [REASON]
# runs the hook on ${WORK_DIR}/msg. EXPECT is "reject" or "accept". REASON,
# when given, is the text the hook must print after "[fail] commit-msg: ":
# without it a reject passes on ANY refusal, so a filler-verb case passed
# whether or not the filler-verb rule fired, because "Update" also fails the
# word count (copilot review, 2026-10-01).
check_hook() {
    local expect="$1" name="$2" reason="${3:-}" rc=0

    (cd "${WORK_DIR}/repo" && "${HOOK}" "${WORK_DIR}/msg") >/dev/null 2>"${WORK_DIR}/err" || rc=$?

    if [[ "${expect}" == "reject" && "${rc}" -eq 0 ]]; then
        printf '[fail] %s: hook accepted a message it must reject\n' "${name}" >&2
        FAILURES=$(( FAILURES + 1 ))
        return 0
    fi
    # a reject must be the hook's own refusal, not a crash: rc 1 and the
    # [fail] diagnostic. an unhandled error also exits non-zero.
    if [[ "${expect}" == "reject" ]] && { [[ "${rc}" -ne 1 ]] || ! grep -q '^\[fail\] commit-msg' "${WORK_DIR}/err"; }; then
        printf '[fail] %s: rejected without the hook diagnostic (rc=%s)\n' "${name}" "${rc}" >&2
        FAILURES=$(( FAILURES + 1 ))
        return 0
    fi
    if [[ "${expect}" == "reject" && -n "${reason}" ]] && ! grep -qxF -- "[fail] commit-msg: ${reason}" "${WORK_DIR}/err"; then
        printf '[fail] %s: rejected for another reason than "%s"\n' "${name}" "${reason}" >&2
        FAILURES=$(( FAILURES + 1 ))
        return 0
    fi
    # an accept must be silent about failure too: exit 0 with a [fail] line
    # is a refusal the exit status hides.
    if [[ "${expect}" == "accept" ]] && { [[ "${rc}" -ne 0 ]] || grep -q '^\[fail\]' "${WORK_DIR}/err"; }; then
        printf '[fail] %s: hook rejected a message it must accept, or printed [fail] (rc=%s)\n' "${name}" "${rc}" >&2
        FAILURES=$(( FAILURES + 1 ))
        return 0
    fi
    printf '[pass] %s\n' "${name}"
}

# assert_hook EXPECT NAME MESSAGE [REASON]
assert_hook() {
    printf '%s\n' "$3" >"${WORK_DIR}/msg"
    check_hook "$1" "$2" "${4:-}"
}

# every token in the guard gets a sample that must match
TOKEN_LINE="$(grep -E "^AGENT_TOKENS=" "${HOOK}" || true)"
TOKENS="${TOKEN_LINE#AGENT_TOKENS=\'}"
TOKENS="${TOKENS%\'}"
if [[ -z "${TOKENS}" || "${TOKENS}" == "${TOKEN_LINE}" ]]; then
    printf '[fail] could not read AGENT_TOKENS out of %s; the guard may have moved\n' "${HOOK}" >&2
    exit 1
fi

IFS='|' read -r -a TOKEN_LIST <<<"${TOKENS}"

# the trailer key is joined at runtime so the literal provenance trailer the
# hook refuses never appears in this file, which public repositories carry
TRAILER="Co-Authored""-By"
AGENT_TRAILER="${TRAILER}: Claude <noreply@anthropic.com>"
printf '[info] %s token(s) in the guard\n' "${#TOKEN_LIST[@]}"

for TOKEN in "${TOKEN_LIST[@]}"; do
    assert_hook reject "co-authored-by ${TOKEN}" \
        "agents: give every cli shim the same header

${TRAILER}: ${TOKEN} <noreply@example.com>"
done

assert_hook reject "generated with, robot emoji" \
    "agents: give every cli shim the same header

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

assert_hook reject "generated by, plain" \
    "agents: give every cli shim the same header

Generated by Mistral Vibe."

# controls: these must still pass, or the guard argues with prose and gets bypassed
assert_hook accept "plain message" \
    "agents: give every cli shim the same header and strict mode"

assert_hook accept "human co-author" \
    "agents: give every cli shim the same header

${TRAILER}: Ada Lovelace <ada@example.com>"

assert_hook accept "vendor name as a scope prefix" \
    "claude: re-apply the policy settings a Drive revert took back"

assert_hook accept "generated mid-sentence" \
    "policy: stop restating rules in the fragments

A rule edited in a generated fragment is discarded by the next run."

# a comment line is scanned too: git strips it only in the editor's cleanup
# mode, and `git commit -F` or `-m` keeps it, so this was an accept case
# that let the trailer land (copilot review of design-system#104,
# 2026-09-30).
assert_hook reject "provenance inside a comment line" \
    "agents: give every cli shim the same header

# ${AGENT_TRAILER}"

assert_hook reject "a watermark inside a comment line" \
    "agents: give every cli shim the same header

# Generated with Claude Code"

# a git-generated subject skips the subject checks, never the provenance scan
assert_hook reject "merge subject carrying an agent trailer" \
    "Merge branch 'feature' into main

${AGENT_TRAILER}"

assert_hook accept "plain revert subject" \
    "Revert \"x\""

# a generated-by line is provenance only when it names an agent
assert_hook accept "generated by a script, no agent named" \
    "schema: regenerate the fixtures after the column rename

Generated by the migration script."

# a trailer on a last line without a newline: `git commit -F <file>` need not
# end the file with one, and a bare `read` skipped exactly that line
printf 'agents: give every cli shim the same header\n\n%s' "${AGENT_TRAILER}" >"${WORK_DIR}/msg"
check_hook reject "trailer without a final newline" "agent provenance trailer"
printf 'agents: give every cli shim the same header\n\nno trailer on this last line' >"${WORK_DIR}/msg"
check_hook accept "last line without a final newline, no trailer"

# a long message: `grep | head -1` let head close the pipe early, grep died of
# SIGPIPE under pipefail, and a good message was refused with no diagnostic
LONG_BODY="$(for _ in $(seq 1 4000); do printf 'a line of ordinary prose that only makes the message long\n'; done)"
assert_hook accept "long message (SIGPIPE under pipefail)" \
    "agents: give every cli shim the same header

${LONG_BODY}"

# drive-written staged content: warned, never rejected, and a local edit is
# not warned about.
assert_drive_warn() {
    local expect="$1" name="$2" stamp="$3" repo="${WORK_DIR}/drive-repo" err rc=0
    rm -rf "${repo}"; git init -q "${repo}"
    printf 'x\n' >"${repo}/f.txt"
    touch -d "${stamp}" "${repo}/f.txt"
    git -C "${repo}" add f.txt
    printf 'drive: stage a file for the fixture\n' >"${WORK_DIR}/msg"
    err="$(cd "${repo}" && "${HOOK}" "${WORK_DIR}/msg" 2>&1 >/dev/null)" || rc=$?
    if (( rc != 0 )); then
        printf '[fail] %s: hook rejected (rc=%s); the drive check must only warn\n' "${name}" "${rc}" >&2
        FAILURES=$(( FAILURES + 1 )); return 0
    fi
    if [[ "${expect}" == "warn" && "${err}" != *"written by Synology Drive"*"f.txt"* ]] \
       || [[ "${expect}" == "quiet" && -n "${err}" ]]; then
        printf '[fail] %s: expected %s, got: %s\n' "${name}" "${expect}" "${err:-<nothing>}" >&2
        FAILURES=$(( FAILURES + 1 )); return 0
    fi
    printf '[pass] %s\n' "${name}"
}
assert_drive_warn warn "drive-written staged file is warned about" '2026-09-23 05:50:31'
assert_drive_warn quiet "locally edited staged file is not" '2026-09-23 05:50:31.123456789'

# a watermark shape behind a marker fails without a known agent token: the
# token list cannot be complete. prose that starts with a letter still passes
# (see "generated by a script, no agent named" above). merged from a
# parallel suite 2026-09-28.
assert_hook reject "generated with, emoji, unlisted tool" \
    "agents: give every cli shim the same header

🤖 Generated with some tool"

# a Markdown bullet is not a watermark: only a non-ASCII symbol (the robot
# emoji every agent CLI prints) marks an unnamed tool. Copilot review of
# research-general#141 found the bullet form rejected, 2026-09-29.
assert_hook accept "a dash bullet before generated-by, no agent named" \
    "schema: regenerate the fixtures after the column rename

- Generated by the migration script"

assert_hook accept "an asterisk bullet before generated-by, no agent named" \
    "schema: regenerate the fixtures after the column rename

* Generated with the fixture builder"

assert_hook reject "a bullet before generated-by naming an agent" \
    "schema: regenerate the fixtures after the column rename

- Generated with Claude Code"

# adversarial review of the narrowed rule, 2026-09-29: punctuation around the
# symbol must not hide it, and a bullet plus a symbol must not hide an agent.
assert_hook reject "a watermark inside a markdown link" \
    "schema: regenerate the fixtures after the column rename

[🤖 Generated with Foo](https://foo.dev)"

assert_hook reject "a bullet, a symbol and a named agent" \
    "schema: regenerate the fixtures after the column rename

- 🤖 Generated with [Claude Code](https://claude.com/claude-code)"

assert_hook reject "a symbol, a bullet and a named agent" \
    "schema: regenerate the fixtures after the column rename

🤖 - Generated with Claude Code"

assert_hook reject "a shortcode marker and a named agent" \
    "schema: regenerate the fixtures after the column rename

:robot: Generated with Claude Code"

# copilot review of research-academic#149: a bullet in front of the
# shortcode hid it, because the shortcode was allowed at the start only.
assert_hook reject "a bullet, a shortcode and a named agent" \
    "schema: regenerate the fixtures after the column rename

- :robot: Generated with Claude Code"

assert_hook reject "a shortcode, a bullet and a named agent" \
    "schema: regenerate the fixtures after the column rename

:robot: - Generated with Claude Code"

# a unicode space or an invisible character inside the watermark hid it (the
# hook's normalise_line comment has the measurement). the code points are
# listed here independently of the hook, so a typo in its byte list fails
# instead of testing itself: every non-ascii White_Space character (Unicode
# PropList.txt), then the invisible format characters the hook removes.
# printf encodes them under C.UTF-8; on a host without that locale it keeps
# the caller's, so a UTF-8 caller still gets the character and a C caller
# gets the escape unconverted, which fails the reject cases loudly. the hook
# runs under C here: under UTF-8, glibc's [[:space:]] covers 15 of the 19
# spaces, and a missing list entry for one of those would go unnoticed.
for HEX in 0085 00a0 1680 2000 2001 2002 2003 2004 2005 2006 2007 2008 2009 200a 2028 2029 202f 205f 3000; do
    LC_ALL=C.UTF-8 printf -v CHAR '%b' "\\u${HEX}"
    LC_ALL=C assert_hook reject "U+${HEX} between generated and with, named agent" \
        "schema: regenerate the fixtures after the column rename

Generated${CHAR}with Claude Code"
done
for HEX in 00ad 034f 061c 180e 200b 200c 200d 200e 200f 202a 202b 202c 202d 202e 2060 2061 2062 2063 2064 2066 2067 2068 2069 feff; do
    LC_ALL=C.UTF-8 printf -v CHAR '%b' "\\u${HEX}"
    LC_ALL=C assert_hook reject "U+${HEX} inside generated, named agent" \
        "schema: regenerate the fixtures after the column rename

Gene${CHAR}rated with Claude Code"
done

readonly NBSP=$'\xc2\xa0' NNBSP=$'\xe2\x80\xaf'
assert_hook reject "a no-break space after with, named agent" \
    "schema: regenerate the fixtures after the column rename

Generated with${NBSP}Claude Code"

assert_hook reject "a narrow no-break space behind a symbol, unlisted tool" \
    "schema: regenerate the fixtures after the column rename

🤖 Generated${NNBSP}with Foo"

assert_hook accept "a no-break space in prose, no agent named" \
    "schema: regenerate the fixtures after the column rename

Generated${NBSP}by the migration script from the old column map"

# a scissors line does not end the scan: `git commit -F` keeps it and every
# line below, so a hook that stopped there let this trailer land (reverted
# 2026-09-30, see the comment above the scan loop in the hook).
assert_hook reject "a trailer below a scissors-shaped line" \
    "docs: explain the watermark fixtures in the suite

# ------------------------ >8 ------------------------
${AGENT_TRAILER}"

# subject rules, one rejected sample each and the passing controls
assert_hook reject "filler verb alone" "Update" \
    "subject is a filler verb and records nothing"
assert_hook reject "filler verb with punctuation" "wip!!" \
    "subject is a filler verb and records nothing"
assert_hook accept "filler verb inside a real sentence" "update the drift check to reach zero"
assert_hook reject "two words" "tighten allowlist"
assert_hook reject "subject under 15 characters" "add a test"
assert_hook reject "message of comments only" "# only a comment
"
assert_hook accept "merge subject without a trailer" "Merge branch 'develop'"
assert_hook accept "fixup subject" "fixup! x"
assert_hook accept "vendor name mentioned in the body" \
    "agents: give every cli shim the same header

the copilot footer now reads the shared cache"

# comment lines: the hook sees the message before git strips it, and git
# strips comment lines only in the strip cleanup (an editor commit by
# default, or commit.cleanup=strip). with -m, git sets GIT_EDITOR=: for the
# hook and keeps "#123 ..." as the subject (measured 2026-10-01, git 2.53).
# GIT_CONFIG_COUNT pins the config the hook reads, whatever the caller's is.
GIT_EDITOR=: assert_hook accept "-m subject starting with an issue number" "#123 fix the drift check"
GIT_EDITOR=: assert_hook accept "-m comment-shaped subject is kept" "# only a comment"
assert_hook reject "editor: an issue-number line is a comment" "#123 fix the drift check" "empty subject"
GIT_EDITOR=: GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.cleanup GIT_CONFIG_VALUE_0=strip \
    assert_hook reject "-m under commit.cleanup=strip drops comments" "# only a comment" "empty subject"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.cleanup GIT_CONFIG_VALUE_0=verbatim \
    assert_hook accept "editor under commit.cleanup=verbatim keeps comments" "#123 fix the drift check"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=';' \
    assert_hook accept "editor with commentChar ; keeps a # subject" "#123 fix the drift check"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=';' \
    assert_hook reject "editor with commentChar ; strips ; lines" "; only a comment" "empty subject"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentString GIT_CONFIG_VALUE_0='//' \
    assert_hook reject "editor with commentString // strips // lines" "// only a comment" "empty subject"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentString GIT_CONFIG_VALUE_0='//' \
    assert_hook accept "editor with commentString // keeps a # subject" "#123 fix the drift check"
# both keys set one value and the last assignment wins (copilot reviews of
# delvrit#9 and languages#7)
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.commentString GIT_CONFIG_VALUE_0='//' \
    GIT_CONFIG_KEY_1=core.commentChar GIT_CONFIG_VALUE_1=';' \
    assert_hook accept "commentString then commentChar: // is a subject" "// keep the drift check subject"
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.commentString GIT_CONFIG_VALUE_0='//' \
    GIT_CONFIG_KEY_1=core.commentChar GIT_CONFIG_VALUE_1=';' \
    assert_hook reject "commentString then commentChar: ; is a comment" "; only a comment" "empty subject"
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=';' \
    GIT_CONFIG_KEY_1=core.commentString GIT_CONFIG_VALUE_1='//' \
    assert_hook accept "commentChar then commentString: ; is a subject" "; keep the drift check subject"
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=';' \
    GIT_CONFIG_KEY_1=core.commentString GIT_CONFIG_VALUE_1='//' \
    assert_hook reject "commentChar then commentString: // is a comment" "// only a comment" "empty subject"

# agent tokens match whole words: a human co-author named Devina passed
# nothing before, because "devin" matched inside her name
assert_hook accept "human co-author whose name contains a token" \
    "agents: give every cli shim the same header

${TRAILER}: Devina Smith <devina@example.com>"
assert_hook reject "co-authored-by token as a whole word" \
    "agents: give every cli shim the same header

${TRAILER}: Devin <devin@example.com>" "agent provenance trailer"

# the right boundary is "no lowercase letter", and a capital starts a token
# inside a word: concatenated vendor names passed a non-alphanumeric
# boundary on both sides (review of hook v1.1)
for NAME in ClaudeCode CopilotAgent GitHubCopilot OpenAICodex Claude4; do
    assert_hook reject "co-authored-by concatenated vendor name ${NAME}" \
        "agents: give every cli shim the same header

${TRAILER}: ${NAME} <bot@example.com>" "agent provenance trailer"
done
assert_hook reject "generated with a concatenated vendor name" \
    "agents: give every cli shim the same header

Generated with ClaudeCode" "agent provenance trailer"
assert_hook reject "generated by a vendor name with a digit" \
    "agents: give every cli shim the same header

Generated by Codex1" "agent provenance trailer"
assert_hook accept "generated by a word that contains a token in lowercase" \
    "agents: give every cli shim the same header

Generated by the precursor migration script"

# an all-caps token ends only at a non-letter: an upper-case continuation
# refused DEVINA and PRECURSOR (copilot reviews of delvrit#9 and dev-env#9)
assert_hook accept "human co-author in capitals whose name contains a token" \
    "agents: give every cli shim the same header

${TRAILER}: DEVINA SMITH <devina@example.com>"
assert_hook accept "generated by an all-caps word that contains a token" \
    "agents: give every cli shim the same header

Generated by the PRECURSOR migration script"
for NAME in CLAUDE CLAUDE4 DevinAI ChatGPT OpenAIAgent ChatGPTAgent CLAUDECode OpenAIAPI ChatGPTAPI OpenAIX; do
    assert_hook reject "co-authored-by vendor name ${NAME}" \
        "agents: give every cli shim the same header

${TRAILER}: ${NAME} <bot@example.com>" "agent provenance trailer"
done
# every listed compound fails in lower case and in capitals (copilot review
# of dhbw#18); the list is read out of the hook like the tokens
COMPOUND_LINE="$(grep -E "^AGENT_COMPOUNDS=" "${HOOK}" || true)"
COMPOUNDS="${COMPOUND_LINE#AGENT_COMPOUNDS=\'}"
COMPOUNDS="${COMPOUNDS%\'}"
if [[ -z "${COMPOUNDS}" || "${COMPOUNDS}" == "${COMPOUND_LINE}" ]]; then
    printf '[fail] could not read AGENT_COMPOUNDS out of %s; the guard may have moved\n' "${HOOK}" >&2
    exit 1
fi
IFS='|' read -r -a COMPOUND_LIST <<<"${COMPOUNDS}"
for NAME in "${COMPOUND_LIST[@]}"; do
    assert_hook reject "co-authored-by compound ${NAME}" \
        "agents: give every cli shim the same header

${TRAILER}: ${NAME} <bot@example.com>" "agent provenance trailer"
    # capitals in C: under a tr_TR caller ${NAME^^} gave GEMİNİCLİ, which the
    # hook rightly accepts, and the case failed for the wrong reason
    NAME_UP="$(printf '%s' "${NAME}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    assert_hook reject "generated by compound ${NAME_UP}" \
        "agents: give every cli shim the same header

Generated by ${NAME_UP}" "agent provenance trailer"
done

# a capital-ending token before a capitalised word fails (copilot review of
# talks#180), in a generated-by line too; capitals alone still pass above
assert_hook reject "generated by a capital-ending token and a capitalised word" \
    "agents: give every cli shim the same header

Generated by OpenAIAgent" "agent provenance trailer"
assert_hook accept "human co-author in capitals followed by a capitalised word" \
    "agents: give every cli shim the same header

${TRAILER}: DEVINA Smith <devina@example.com>"

# the known limit the hook names: an unlisted one-case concatenation passes
# on its own, and the vendor address beside it still fails
assert_hook accept "unlisted all-caps concatenation alone (known limit)" \
    "agents: give every cli shim the same header

${TRAILER}: CLAUDEBOT <bot@example.com>"
assert_hook reject "unlisted all-caps concatenation with a vendor address" \
    "agents: give every cli shim the same header

${TRAILER}: CLAUDEBOT <noreply@anthropic.com>" "agent provenance trailer"

# the token patterns do not follow the caller's locale: under tr_TR, "i"
# upper-cased to U+0130 and OpenAI passed (copilot reviews of delvrit#9,
# etc#7 and fietsen#6). the locale is built into the work directory; a host
# without localedef or the tr_TR source cannot run the case and says so.
mkdir -p "${WORK_DIR}/locale"
if command -v localedef >/dev/null 2>&1 \
   && localedef -i tr_TR -f UTF-8 "${WORK_DIR}/locale/tr_TR.UTF-8" >/dev/null 2>&1; then
    for NAME in OpenAI GEMINI AIDER; do
        LOCPATH="${WORK_DIR}/locale" LC_ALL=tr_TR.UTF-8 assert_hook reject "co-authored-by ${NAME} under tr_TR" \
            "agents: give every cli shim the same header

${TRAILER}: ${NAME} <bot@example.com>" "agent provenance trailer"
    done
else
    printf '[info] tr_TR cases not run: localedef or its tr_TR source is missing\n'
fi

# a relative candidate reaches the hook, end to end: the suite runs again
# with a relative COMMIT_MSG_HOOK naming a copy of the hook that records each
# call, and must pass with the record present. a bare run and make lint pass
# no candidate, so this is the one run that takes the relative branch
# (copilot reviews of research-academic#155 and talks#143). the nested run
# carries a candidate, so it does not nest again.
if [[ -z "${COMMIT_MSG_HOOK:-}" ]]; then
    mkdir "${WORK_DIR}/candidate"
    {
        head -n 1 "${HOOK}"
        printf ': > %q\n' "${WORK_DIR}/candidate/called"
        tail -n +2 "${HOOK}"
    } > "${WORK_DIR}/candidate/commit-msg"
    chmod +x "${WORK_DIR}/candidate/commit-msg"
    if (cd "${WORK_DIR}" && COMMIT_MSG_HOOK=candidate/commit-msg bash "${SELF_DIR}/${BASH_SOURCE[0]##*/}" >/dev/null 2>&1) \
       && [[ -f "${WORK_DIR}/candidate/called" ]]; then
        printf '[pass] a relative COMMIT_MSG_HOOK reaches the hook\n'
    else
        printf '[fail] a relative COMMIT_MSG_HOOK reaches the hook\n' >&2
        FAILURES=$((FAILURES + 1))
    fi
fi

if (( FAILURES > 0 )); then
    printf '[fail] %s assertion(s) failed\n' "${FAILURES}" >&2
    exit 1
fi
printf '[pass] commit-msg fixture suite clean\n'
