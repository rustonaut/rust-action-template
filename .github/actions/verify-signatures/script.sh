#!/usr/bin/env bash

#FIXME un-bashify, maybe Type Script Action?
# I went with bash because it's mostly calling gpg/git and
# bash does that well and it's only ~150 lines. But when
# writing tests I remembered why bash succes, so it's
# better to rewrite this. Well that's why I also didn't
# bother adding to much additional documentation.

set -euo pipefail

FAILURE_EXIT_CODE=1

GPG=gpg2
GIT=git

# = core.debug(message)
function debug() {
    echo "::debug::$(escapeMessage "$1")"
}

# = core.warning(message)
function warn() {
    echo "::warning::$(escapeMessage "$1")"
}

# = core.error(message), but can cause exit with error exit code
function error() {
    echo "::error::$(escapeMessage "$1")"
}

# = startGroup(name)
function startGroup() {
    echo "::group::$(escapeMessage "$1")"
}

# = endGroup()
function endGroup() {
    echo "::endgroup::"
}

# escape messages for debug/warn/error
function escapeMessage() {
    local TMP=${1//%/%25}
    local TMP=${TMP//$'\r'/%0D}
    echo ${TMP//$'\n'/%0A}
}


function showDetails() {
    local TYPE="$1"
    local ENTITY="$2"
    warn "$($GIT show $ENTITY 2>&1 || true)"
}

# Given a entity type and id verifies if it's signature is valid
#
# The type must be `tag` or `commit` depending on it either the
# variables `REQUIRE_SIGNED_TAGS` and `REQUIRE_TAG_SIGNING_FPR` or
# the variables `REQUIRE_SIGNED_COMMITS` and `REQUIRE_COMMIT_SIGNING_FPR`
# are used.
#
# This will run `git verify-tag`/`verify-commit` with the `--raw` option
# set and then post process the GPG output.
#
# The `REQUIRE_SIGNED_*` option determiens if a (valid) signature is required
# if not invalid signatures will still cause errors but missing signatures
# won't.
#
# If `REQUIRE_*_SIGNING_FPR` is not empty then if the tag is signed the FPR
# (fingerprint) of the primary key associated with the signing key must be
# the value of that environment variable.
function verify_entity() {
    local TYPE="${1:?require tag or commit type}"
    local ENTITY="${2:?require tag name or commit hash}"

    if [ "$TYPE" = "tag" ] ; then
        local SIGNING_REQUIRED="$REQUIRE_SIGNED_TAGS"
        local REQUIRED_FPR="$REQUIRE_TAG_SIGNING_FPR"
    elif [ "$TYPE" = "commit" ] ; then
        local SIGNING_REQUIRED="$REQUIRE_SIGNED_COMMITS"
        local REQUIRED_FPR="$REQUIRE_COMMIT_SIGNING_FPR"
    else
        error "(internal) Only support verify tag/commit but not $ENTITY"
        return $FAILURE_EXIT_CODE
    fi

    PIPE_IT="$(gpg_output_for_git_verify_entity $ENTITY 2>&1 1>/dev/null)"

    if [ "${#PIPE_IT}" = "0" ] ; then
        if [  "$SIGNING_REQUIRED" = "true" ] ; then
            error "The $TYPE $ENTITY needs to be signed"
            showDetails "$TYPE" "$ENTITY"
            return $FAILURE_EXIT_CODE
        else
            debug "Skipping non signed $TYPE"
            return 0
        fi
    fi

    local EXIT_CODE=0
    gpg_verify "$TYPE" "$ENTITY" "$REQUIRED_FPR" <<<"$PIPE_IT" || EXIT_CODE=$?

    if [ ! "$EXIT_CODE" = 0 ] ; then
        debug "$PIPE_IT"
    fi

    return $EXIT_CODE;
}

# Runs git verify-tag/verify-commit --raw
#
# The exit code is always 0, use the output to determine details.
function gpg_output_for_git_verify_entity() {
    # We use the output exit code doesn't matter
    $GIT verify-$TYPE --raw -- $1 || true
}

# Verifies if a output of `git verify-tag/commit --raw` indicates a valid signature.
#
# If the output was empty it indicates not signature exists and this function MUST NOT
# be called if signing is not required.
#
# Looks for `'[GNUGPG:] GOODSIG '` entries.
# If no are found an error is returned.
# If a specific FPR is required a valid but mismatched signature will cause an
# warning and is otherwise treated as if it doesn't exist.
#
# The `gpg2 --locate-keys` command is used to lookup the FRP for the given key id.
function gpg_verify() {
    local TYPE="$1"
    local ENTITY="$2"
    local REQUIRED_FPR="$3"

    local EXIT_CODE=0

    filterGoodSignEntriesFromStdin | (
        EXIT_CODE=1
        while read KEY; do
            debug "Good signature with key: $KEY"
            FPR=$(lookupFPR $KEY)
            if [ ! "$REQUIRED_FPR" = "" ] && [ ! "$FPR" = "$REQUIRED_FPR" ] ; then
                warn "Signed $TYPE $ENTITY with wrong key. Expected $REQUIRED_FPR, found $FPR"
            else
                EXIT_CODE=0
            fi
        done
        return $EXIT_CODE
    ) || EXIT_CODE=$?

    if [ ! "$EXIT_CODE" = 0 ] ; then
        error "Failed to find good signature for $TYPE $ENTITY"
        showDetails "$TYPE" "$ENTITY"
    fi

    return $EXIT_CODE
}

# Filter git gpg2 output.
function filterGoodSignEntriesFromStdin() {
    grep  '^\[GNUPG:\] GOODSIG ' | cut -d' ' -f3 | tr -d ' '
}

# Lookup FPR by (sub)keyid
function lookupFPR() {
    $GPG --locate-keys $1 | head -n 2 | tail -n1 | tr -d ' '
}

# Verify all commits and tags attached to them in the commit range between $1..$2.
#
function verify() {
    local FROM="$1"
    local TO="$2"
    $GIT rev-list "$FROM..$TO" -- | (
        local EXIT_CODE=0
        while read commit; do
            startGroup "commit: $commit"
            verify_entity commit $commit
            EXIT_CODE=$((EXIT_CODE|$?))
            $GIT tag --points-at $commit | (
                local EXIT_CODE=0
                while read tag; do
                    startGroup "tag: $tag"
                    verify_entity tag $tag
                    EXIT_CODE=$((EXIT_CODE|$?))
                    endGroup
                done
                return $EXIT_CODE
            )
            EXIT_CODE=$((EXIT_CODE|$?))
            endGroup
        done
        return $EXIT_CODE
    )
    return $?
}


# Sets some env variables based on other env variables (GITHUB_BASE_REF,GITHUB_REF)
function setup_env() {
    debug "GITHUB_BASE_REF=${GITHUB_BASE_REF:-**not set**}"
    debug "GITHUB_REF=${GITHUB_REF:-**not set**}"

    START_COMMIT="refs/remotes/origin/${GITHUB_BASE_REF:-nightly}"
    END_COMMIT="${GITHUB_REF:?GITHUB_REF is required}"

    if [ "${END_COMMIT:0:10}" = "refs/pull/" ] ; then
        END_COMMIT="refs/remotes/${END_COMMIT:5}"
    fi

    debug "START_COMMIT=$START_COMMIT"
    debug "END_COMMIT=$END_COMMIT"
}

# Sets env variables based on the github action `INPUT_` env variables.
#
# Checks that requiring FPR can only be used for tag/commit if signing is
# required for tag/commit.
function parse_input() {
    REQUIRE_SIGNED_COMMITS="${INPUT_REQUIRE_SIGNED_COMMITS:-false}"
    REQUIRE_COMMIT_SIGNING_FPR="${INPUT_REQUIRE_COMMIT_SIGNING_FPR:-}"
    REQUIRE_SIGNED_TAGS="${INPUT_REQUIRE_SIGNED_TAGS:-true}"
    REQUIRE_TAG_SIGNING_FPR="${INPUT_REQUIRE_TAG_SIGNING_FPR:-}"
    GPG_IMPORT_KEYS_DIR="${INPUT_GPG_IMPORT_KEYS_DIR:-${GITHUB_WORKSPACE:-.}/.gpg/import-keys}"

    if [ "$REQUIRE_SIGNED_COMMITS" = false ] && [ ! "$REQUIRE_COMMIT_SIGNING_FPR" = "" ] ; then
        error "Cannot require commit signing FPR but not require signing commits!"
        return $FAILURE_EXIT_CODE
    fi

    if [ "$REQUIRE_SIGNED_TAGS" = false ] && [ ! "$REQUIRE_TAG_SIGNING_FPR" = "" ] ; then
        error "Cannot require tag signing FPR but not require signing tags!"
        return $FAILURE_EXIT_CODE
    fi

    debug "Verify Settings:"
    debug "REQUIRE_SIGNED_COMMITS=$REQUIRE_SIGNED_COMMITS"
    debug "REQUIRE_SIGNED_TAGS=$REQUIRE_SIGNED_TAGS"
    debug "REQUIRE_TAG_SIGNING_FPR=$REQUIRE_TAG_SIGNING_FPR"
    debug "REQUIRE_COMMIT_SIGNING_FPR=$REQUIRE_COMMIT_SIGNING_FPR"
    debug "GPG_IMPORT_KEYS_DIR=$GPG_IMPORT_KEYS_DIR"
}

function import_keys() {
    debug "Scanning dir for gpg keys: $GPG_IMPORT_KEYS_DIR"
    for file in "$GPG_IMPORT_KEYS_DIR"/*.gpg ; do
        debug "Import key: $file"
        $GPG --import $file
    done

    debug "$($GPG --list-keys 2>&1)"
}

# Runs the verification process based on env variabes and inputs
function run() {
    setup_env
    parse_input
    import_keys
    verify "$START_COMMIT" "$END_COMMIT"
}

# Only run if we aren't currently testing.
if [ ! "${__TEST_MODE__:-}" = "enabled" ] ; then
    run
fi
