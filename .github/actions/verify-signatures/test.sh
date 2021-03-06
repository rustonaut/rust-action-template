#!/usr/bin/env bash
set -euo pipefail

export __TEST_MODE__=enabled

source "$(dirname $0)/script.sh"

function __on_exit() {
    if [ "$?" == 0 ] ; then
        echo "SUCCESS"
    else
        echo "FAILED"
    fi
}

trap __on_exit EXIT


SCOPE="unknown"
SUB_SCOPE=""
function test() {
    SCOPE=$1
    SUB_SCOPE=${2:-}
    echo "-- Test $SCOPE $SUB_SCOPE --"
}


function assert_eq() {
    if [ ! "${1:-}" = "${2:-}" ] ; then
        echo "[$SCOPE::$SUB_SCOPE] Failed Comparsion \"${1:-}\" = \"${2:-}\"" 1>&2
        exit 1
    fi
}

function assert_fail() {
    echo "[$SCOPE::$SUB_SCOPE] $1" 1>&2
    exit 1
}

declare -A __FUNCTIONS_BACKUP

function backup_function() {
    NAME="${1:?require function name}"
    __FUNCTIONS_BACKUP[$NAME]="$(declare -f $NAME)"
}

function restore_function() {
    NAME="${1:?require function name}"
    DEV="${__FUNCTIONS_BACKUP[$NAME]:?function needed to be backuped before}"
    eval "function $DEV"
}


test escapeMessage
TEST_MESSAGE="%abcde%"$'\n'"%"$'\r'lol
assert_eq "$(escapeMessage "$TEST_MESSAGE")" "%25abcde%25%0A%25%0Dlol"

test debug
TEST_MESSAGE2="a%b"
assert_eq "$(debug "$TEST_MESSAGE2")" "::debug::a%25b"

test warn
assert_eq "$(warn "$TEST_MESSAGE2")" "::warning::a%25b"

test error
OUT="$(error "$TEST_MESSAGE2")"
assert_eq "$OUT" "::error::a%25b"

## Test: lookupFPR
test lookupFPR
_KEY=8F2CBBA19343C9EE
function gpg_locate_keys() {
    assert_eq $1 "--locate-keys"
    assert_eq $2 "$_KEY"
    assert_eq $# 2
    echo "pub   rsa4096 2020-08-18 [SC] [expires: 2022-08-18]
      F6911C8376111105830FDE32DC653E72D02B615E
uid           [ultimate] Philipp Korber <philipp@korber.dev>
sub   rsa4096 2020-08-18 [E] [expires: 2022-08-18]
sub   ed25519 2020-08-18 [S] [expires: 2022-08-18]
"
}
_GPG="$GPG"
GPG=gpg_locate_keys
FPR="$(lookupFPR $_KEY)"
assert_eq "$FPR" "F6911C8376111105830FDE32DC653E72D02B615E"

test gpg_verify valid_no_fpr_required
GPG_STATUS_MOCK_VALID="[GNUPG:] NEWSIG
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] SIG_ID 6a4u11111STC1111MzrxOFg50u4 2020-08-20 1511114790
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] GOODSIG 8F2CBBA19343C9EE Philipp Korber <philipp@korber.dev>
[GNUPG:] VALIDSIG 3819FE19A61C11111111D3788F2CBBA19343C9DD 2020-08-20 1511114790 0 4 0 22 8 00 F6911C8376111105830FDE32DC653E72D02B615E
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] TRUST_ULTIMATE 0 pgp
"

# We it only uses type+entity ($0,$1) for error messages.
OUT=$(gpg_verify tag v0 "" <<< "$GPG_STATUS_MOCK_VALID")
assert_eq $? 0
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE"

test gpg_verify vaid_fpr_required
OUT=$(gpg_verify tag v0 "F6911C8376111105830FDE32DC653E72D02B615E" <<< "$GPG_STATUS_MOCK_VALID")
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE"

test gpg_verify invalid_fpr_mismatch
function mock_git_show() {
    assert_eq $1 "show"
    echo "GIT_MOCK_SHOW for $2"
}
GIT=mock_git_show
EC=0
OUT=$(echo "$GPG_STATUS_MOCK_VALID" | gpg_verify tag v0 "nop-fpr-wrong") 2>&1 || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE
::warning::Signed tag v0 with wrong key. Expected nop-fpr-wrong, found F6911C8376111105830FDE32DC653E72D02B615E
::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0"

test gpg_verify invalid_empty_and_fpr_not_required
EC=0
OUT=$(echo "" | gpg_verify tag v0 "") 2>&1 || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0"

test gpg_verify invalid_empty_and_fpr_required
EC=0
OUT=$(echo "" | gpg_verify tag v0 "F6911C8376111105830FDE32DC653E72D02B615E") 2>&1 || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0"

test gpg_verify invalid_and_fpr_not_required
GPG_STATUS_MOCK_INVALID="[GNUPG:] NEWSIG
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] SIG_ID 6a4u11111STC1111MzrxOFg50u4 2020-08-20 1511114790
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] BADSIG 8F2CBBA19343C9EE Philipp Korber <philipp@korber.dev>
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0
[GNUPG:] TRUST_ULTIMATE 0 pgp
"

EC=0
OUT=$(echo "$GPG_STATUS_MOCK_INVALID" | gpg_verify tag v0 "") 2>&1 || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0"

test gpg_verify invalid_and_fpr_required
EC=0
OUT=$(echo "$GPG_STATUS_MOCK_INVALID" | gpg_verify tag v0 "F6911C8376111105830FDE32DC653E72D02B615E") 2>&1 || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0"


test verify_entity valid_fpr_required

backup_function gpg_output_for_git_verify_entity
declare __GPG_STATUS_MOCK
function gpg_output_for_git_verify_entity() {
    assert_eq $# 1
    echo "$__GPG_STATUS_MOCK" 1>&2
}
function set_gpg_status_mock() {
    __GPG_STATUS_MOCK="$1"
    assert_eq "$#" 1
}

set_gpg_status_mock "$GPG_STATUS_MOCK_VALID"

REQUIRE_SIGNED_TAGS="true"
REQUIRE_TAG_SIGNING_FPR="F6911C8376111105830FDE32DC653E72D02B615E"
OUT=$(verify_entity tag v0)
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE"

test verify_entity valid_fpr_not_required_on_commit
REQUIRE_SIGNED_COMMITS="true"
REQUIRE_TAG_SIGNING_FPR="bad"
REQUIRE_COMMIT_SIGNING_FPR=""
# As it's all mocked it doesn't matter that v0 isn't a proper commit hash
OUT=$(verify_entity commit v0)
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE"

test verify_entity valid_fpr_not_required
REQUIRE_SIGNED_COMMITS="true"
REQUIRE_TAG_SIGNING_FPR=""
OUT=$(verify_entity tag v0)
assert_eq "$OUT" "::debug::Good signature with key: 8F2CBBA19343C9EE"

test verify_entity invalid_signing_required_but_not_given
REQUIRE_SIGNED_TAGS="true"
REQUIRE_TAG_SIGNING_FPR=""
set_gpg_status_mock ""
EC=0
OUT="$(verify_entity tag v0)" || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::The tag v0 needs to be signed
::warning::GIT_MOCK_SHOW for v0"

test verify_entity valid_signing_not_required_and_not_given
REQUIRE_SIGNED_TAGS="false"
REQUIRE_TAG_SIGNING_FPR=""
set_gpg_status_mock ""
# No f* idea but somehow stdout is surpressed if it isn't run in a capturing subshell?
OUT=$(verify_entity tag v0)
assert_eq "$OUT" "::debug::Skipping non signed tag"



test verify_entity invalid_signing_not_required_but_malformed
REQUIRE_SIGNED_TAGS="false"
REQUIRE_TAG_SIGNING_FPR=""
set_gpg_status_mock "$GPG_STATUS_MOCK_INVALID"
EC=0
OUT=$(verify_entity tag v0) || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for tag v0
::warning::GIT_MOCK_SHOW for v0
::debug::[GNUPG:] NEWSIG%0A[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0%0A[GNUPG:] SIG_ID 6a4u11111STC1111MzrxOFg50u4 2020-08-20 1511114790%0A[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0%0A[GNUPG:] BADSIG 8F2CBBA19343C9EE Philipp Korber <philipp@korber.dev>%0A[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0%0A[GNUPG:] KEY_CONSIDERED F6911C8376111105830FDE32DC653E72D02B615E 0%0A[GNUPG:] TRUST_ULTIMATE 0 pgp"

test verify_entity bad_commit_signature
REQUIRE_SIGNED_COMMITS="false"
REQUIRE_SIGNED_TAGS="false"
REQUIRE_TAG_SIGNING_FPR=""
REQUIRE_COMMIT_SIGNING_FPR=""
set_gpg_status_mock "[GNUPG:] NEWSIG
[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9
[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23
"
EC=0
OUT=$(verify_entity commit v0) || EC=$?
assert_eq $EC 1
assert_eq "$OUT" "::error::Failed to find good signature for commit v0
::warning::GIT_MOCK_SHOW for v0
::debug::[GNUPG:] NEWSIG%0A[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9%0A[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23"


test verify iterates_properly
function mock_git() {
    case "$1" in
        "rev-list")
            assert_eq $2 "from_ref..to_ref"
            assert_eq $3 "--"
            assert_eq $# 3
            echo "cf968a8d04e7111cbebbe256dcfd9b77afd8133b"
            echo "aa968a8d04e7111cbebbe256dcfd9b77afd8133b"
            ;;
        "show")
            mock_git_show "$@"
            ;;
        "tag")
            assert_eq $2 "--points-at"
            case "$3" in
                "cf968a8d04e7111cbebbe256dcfd9b77afd8133b")
                    ;;
                "aa968a8d04e7111cbebbe256dcfd9b77afd8133b")
                    echo "v000"
                    ;;
                *)
                    assert_fail "unknown mock commit: $3"
            esac
            assert_eq $# 3
            ;;
        *)
            assert_fail "unknown git mock sub-command $1"
            ;;
    esac
}
_GIT="$GIT"
GIT=mock_git

backup_function verify_entity
function verify_entity() {
    case "$1" in
        "tag")
            assert_eq $2 v000
            assert_eq $# 2
            ;;
        "commit")
            case "$2" in
                "cf968a8d04e7111cbebbe256dcfd9b77afd8133b")
                    ;;
                "aa968a8d04e7111cbebbe256dcfd9b77afd8133b")
                    ;;
                *)
                    assert_fail "unknwon mock commit in verify_entity $2"
            esac
            assert_eq $# 2
            ;;
        *)
            assert_fail "bad parameters for verify_entity $@"
            ;;
    esac
}

OUT=$(verify from_ref to_ref)
assert_eq "$OUT" "::group::commit: cf968a8d04e7111cbebbe256dcfd9b77afd8133b
::endgroup::
::group::commit: aa968a8d04e7111cbebbe256dcfd9b77afd8133b
::group::tag: v000
::endgroup::
::endgroup::"

restore_function verify_entity


test verify_outputs_errors
REQUIRE_SIGNED_COMMITS="false"
REQUIRE_SIGNED_TAGS="false"
REQUIRE_TAG_SIGNING_FPR=""
REQUIRE_COMMIT_SIGNING_FPR=""
set_gpg_status_mock "[GNUPG:] NEWSIG
[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9
[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23
"
EC=0
OUT=$(verify from_ref to_ref) || EC=$?
assert_eq "$OUT" "::group::commit: cf968a8d04e7111cbebbe256dcfd9b77afd8133b
::error::Failed to find good signature for commit cf968a8d04e7111cbebbe256dcfd9b77afd8133b
::warning::GIT_MOCK_SHOW for cf968a8d04e7111cbebbe256dcfd9b77afd8133b
::debug::[GNUPG:] NEWSIG%0A[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9%0A[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23
::endgroup::
::group::commit: aa968a8d04e7111cbebbe256dcfd9b77afd8133b
::error::Failed to find good signature for commit aa968a8d04e7111cbebbe256dcfd9b77afd8133b
::warning::GIT_MOCK_SHOW for aa968a8d04e7111cbebbe256dcfd9b77afd8133b
::debug::[GNUPG:] NEWSIG%0A[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9%0A[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23
::group::tag: v000
::error::Failed to find good signature for tag v000
::warning::GIT_MOCK_SHOW for v000
::debug::[GNUPG:] NEWSIG%0A[GNUPG:] ERRSIG 4AEE18F83AFDEB23 1 8 00 1598024984 9%0A[GNUPG:] NO_PUBKEY 4AEE18F83AFDEB23
::endgroup::
::endgroup::"
assert_eq $EC 1