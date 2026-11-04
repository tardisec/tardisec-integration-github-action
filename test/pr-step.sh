#!/bin/bash
# Runs the real "Open pull request" script from action.yml against a stubbed gh, with the flags
# GitHub runs a `shell: bash` step under. Needs bash, git and jq. Run from anywhere.
#   ACTION_YML=path/to/copy.yml bash test/pr-step.sh   tests a mutated copy of the action
set -u

cd "$(dirname "$0")/.." || exit 1
ACTION_YML=${ACTION_YML:-action.yml}
ROOT=$(mktemp -d)  # every scenario gets its own directory, the OS cleans the rest up
STEP="${ROOT}/pr-step.sh"
STUBS="${ROOT}/bin"
HEADLINE="chore: sync tardisec config"
BASE_OID=basesha000

# The run: block is everything indented deeper than `run: |`, up to the next line that is not.
awk '
  /^    - name: Open pull request$/ { in_step = 1; next }
  in_step && /^      run: \|$/      { in_run = 1; next }
  in_run && /^$/                    { print ""; next }
  in_run && /^        /             { print substr($0, 9); next }
  in_run                            { exit }
' "${ACTION_YML}" > "${STEP}"
if ! grep -q 'gh pr create' "${STEP}"; then
  echo "FAIL: no Open pull request script found in ${ACTION_YML}"
  exit 1
fi

mkdir -p "${STUBS}"
# Mimics real gh: an HTTP error prints the JSON body to stdout, `gh: <msg> (HTTP <code>)` to
# stderr, and exits 1. Lines in $GH_LOG record every call.
cat > "${STUBS}/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "${GH_LOG}"
http_error() {
  printf '{"message":"%s","status":"%s"}' "$2" "$1"
  echo "gh: $2 (HTTP $1)" >&2
  exit 1
}
ref_exists() {
  case " ${STUB_REFS:-} " in *" $1 "*) return 0 ;; esac
  return 1
}
case "$*" in
  "api user "*)
    tries=$(($(cat "${GH_LOG}.user" 2>/dev/null || echo 0) + 1))
    echo "${tries}" > "${GH_LOG}.user"
    if [ "${tries}" -le "${STUB_USER_FAILS:-0}" ]; then
      http_error 403 "Resource not accessible by integration"
    fi
    echo "alice 123"
    ;;
  "api repos/o/r/git/ref/heads/"*)
    name=${2#repos/o/r/git/ref/heads/}
    if [ -n "${STUB_REF_LOOKUP_CODE:-}" ] && [ "${name}" != "${BASE}" ]; then
      http_error "${STUB_REF_LOOKUP_CODE}" "Server Error"
    fi
    if [ "${name}" = "${BASE}" ] && [ -z "${STUB_NO_BASE:-}" ]; then
      echo "${STUB_BASE_OID}"
    elif ref_exists "${name}"; then
      echo "branchsha111"
    else
      http_error 404 "Not Found"
    fi
    ;;
  "api repos/o/r/contents/"*)
    file=${2#repos/o/r/contents/}
    file=${file%%\?*}
    if [ "${file}" = "${STUB_CONTENTS_ERROR_FILE:-}" ]; then
      http_error "${STUB_CONTENTS_ERROR_CODE}" "Server Error"
    fi
    if [ -f "${BASETREE}/${file}" ]; then
      git hash-object "${BASETREE}/${file}"
    else
      http_error 404 "Not Found"
    fi
    ;;
  "api repos/o/r/compare/"*)
    if [ -n "${STUB_COMPARE_CODE:-}" ]; then
      http_error "${STUB_COMPARE_CODE}" "${STUB_COMPARE_MESSAGE:-Server Error}"
    fi
    [ -n "${STUB_COMPARE_JSON:-}" ] || http_error 404 "Not Found"
    echo "${STUB_COMPARE_JSON}"
    ;;
  "api -X PATCH repos/o/r/git/refs/heads/"*)
    name=${4#repos/o/r/git/refs/heads/}
    ref_exists "${name}" || http_error 422 "Reference does not exist"
    echo '{}'
    ;;
  "api -X POST repos/o/r/git/refs "*)
    echo '{}'
    ;;
  "api graphql --input -")
    cat > "${GH_LOG}.graphql"
    echo '{"data":{}}'
    ;;
  "pr list "*)
    echo "${STUB_OPEN_PR:-}"
    ;;
  "pr create "*)
    echo "https://github.com/o/r/pull/1"
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 64
    ;;
esac
STUB
# The backoff is asserted, not waited out.
cat > "${STUBS}/sleep" <<'STUB'
#!/bin/bash
echo "$1" >> "${GH_LOG}.sleep"
STUB
chmod +x "${STUBS}/gh" "${STUBS}/sleep"

# Binary, CRLF, no trailing newline, and long enough that base64 wraps its output.
exact_bytes() {
  printf 'crlf\r\n\377\376\000binary\n'
  printf '%0200d' 0
}

failures=0
passes=0
n=0
scenario=""
fail() {
  failures=$((failures + 1))
  echo "  FAIL [${scenario}] $1"
  if [ -f "${DIR}/out" ]; then sed 's/^/    | /' "${DIR}/out"; fi
}
ok() {
  passes=$((passes + 1))
}
assert_eq() {  # label expected actual
  if [ "$2" = "$3" ]; then ok; else fail "$1: expected '$2', got '$3'"; fi
}
assert_called() {  # fixed string that must appear in the gh log
  if grep -qF -- "$1" "${LOG}"; then ok; else fail "no gh call containing '$1'"; fi
}
assert_not_called() {
  if grep -qF -- "$1" "${LOG}"; then fail "unexpected gh call containing '$1'"; else ok; fi
}
assert_out() {  # fixed string that must appear in the step's output
  if grep -qF -- "$1" "${DIR}/out"; then ok; else fail "no output containing '$1'"; fi
}
assert_no_writes() {
  if grep -qE 'git/refs|graphql|pr create' "${LOG}"; then
    fail "expected no writes, got: $(grep -E 'git/refs|graphql|pr create' "${LOG}" | tr '\n' ';')"
  else
    ok
  fi
}
assert_exit() {
  assert_eq "exit status" "$1" "${RC}"
}
assert_failed() {  # for failures that surface a tool's own exit status
  if [ "${RC}" -ne 0 ]; then ok; else fail "expected a failure, got exit 0"; fi
}
user_calls() {
  grep -c '^gh api user ' "${LOG}"
}
mutation() {  # jq filter over the graphql mutation's input
  jq -r ".variables.input | $1" "${LOG}.graphql"
}
compare_json() {  # ahead_by, then one commit message per remaining argument
  local ahead=$1
  shift
  jq -n --argjson ahead "${ahead}" \
    '{ahead_by: $ahead, commits: ($ARGS.positional | map({commit: {message: .}}))}' --args "$@"
}

# Sets DIR, LOG and RC. Base holds same.json and changed.json; the checkout changes one of them
# and adds added.json. Arguments are extra env assignments for the step.
run_step() {
  scenario=$1
  shift
  n=$((n + 1))
  DIR="${ROOT}/s${n}"
  LOG="${DIR}/temp/gh.log"
  mkdir -p "${DIR}/work" "${DIR}/base" "${DIR}/temp"
  git init -q "${DIR}/work"
  printf 'same\n' > "${DIR}/base/same.json"
  printf 'same\n' > "${DIR}/work/same.json"
  printf 'old\n' > "${DIR}/base/changed.json"
  exact_bytes > "${DIR}/work/changed.json"
  printf 'first\n' > "${DIR}/work/added.json"
  printf 'same.json\nchanged.json\nadded.json\n' > "${DIR}/temp/tardisec-fetched"
  : > "${LOG}"
  (
    cd "${DIR}/work" || exit 99
    if [ -n "${PREPARE:-}" ]; then "${PREPARE}"; fi
    env PATH="${STUBS}:${PATH}" GH_LOG="${LOG}" BASETREE="${DIR}/base" STUB_BASE_OID="${BASE_OID}" \
      RUNNER_TEMP="${DIR}/temp" GITHUB_REPOSITORY=o/r GH_TOKEN=stub \
      TOKEN_IS_DEFAULT=false BRANCH=tardisec-config BASE=main "$@" \
      bash --noprofile --norc -eo pipefail "${STEP}"
  ) > "${DIR}/out" 2>&1 < /dev/null
  RC=$?
  if grep -q 'stub gh: unexpected call' "${DIR}/out"; then
    fail "the step made a call the stub does not model"
  fi
}

SYNC_MESSAGE="${HEADLINE}

Signed-off-by: alice <123+alice@users.noreply.github.com>"

# --- token identity
run_step "default token signs off as the bot" TOKEN_IS_DEFAULT=true
assert_exit 0
assert_eq "/user calls" 0 "$(user_calls)"
assert_eq "signoff" 'Signed-off-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>' \
  "$(mutation .message.body)"
assert_eq "headline" "${HEADLINE}" "$(mutation .message.headline)"
assert_called "pr create"

run_step "PAT signs off from /user, commits only what differs"
assert_exit 0
assert_eq "/user calls" 1 "$(user_calls)"
assert_eq "signoff" 'Signed-off-by: alice <123+alice@users.noreply.github.com>' "$(mutation .message.body)"
assert_eq "paths" "added.json changed.json" "$(mutation '[.fileChanges.additions[].path] | join(" ")')"
assert_eq "expectedHeadOid" "${BASE_OID}" "$(mutation .expectedHeadOid)"
assert_eq "branchName" tardisec-config "$(mutation .branch.branchName)"
mutation '.fileChanges.additions[] | select(.path == "changed.json").contents' \
  | base64 --decode > "${DIR}/decoded"
exact_bytes > "${DIR}/expected"
if cmp -s "${DIR}/expected" "${DIR}/decoded"; then ok; else fail "contents do not decode to the file's bytes"; fi
# GNU base64 wraps at 76 columns, and decoding would not notice.
assert_eq "base64 is one line" false "$(mutation '[.fileChanges.additions[].contents | contains("\n")] | any')"
assert_eq "new file contents" first "$(mutation '.fileChanges.additions[] | select(.path == "added.json").contents' | base64 --decode)"

run_step "non-default token, /user 403 on every attempt" STUB_USER_FAILS=99
assert_exit 1
assert_eq "/user calls" 3 "$(user_calls)"
assert_eq "backoff" "5 10" "$(tr '\n' ' ' < "${LOG}.sleep" | sed 's/ $//')"
assert_out "::error::tardisec: could not read the token identity"
assert_no_writes

run_step "non-default token, /user recovers on a retry" STUB_USER_FAILS=1
assert_exit 0
assert_eq "/user calls" 2 "$(user_calls)"
assert_eq "signoff" 'Signed-off-by: alice <123+alice@users.noreply.github.com>' "$(mutation .message.body)"

# --- nothing to do, and refusing to start
base_matches_work() {
  cp changed.json ../base/changed.json
  cp added.json ../base/added.json
}
PREPARE=base_matches_work run_step "nothing differs"
assert_exit 0
assert_eq "/user calls" 0 "$(user_calls)"
assert_no_writes

run_step "branch equals base" BRANCH=main
assert_exit 1
assert_out "::error::tardisec: branch and base are both 'main'"
assert_no_writes

run_step "base branch missing" STUB_NO_BASE=1
assert_exit 1
assert_out "::error::tardisec: base branch 'main' not found"
assert_no_writes

# --- contents API. added.json sorts first, so the failure has later files to be masked by.
run_step "contents API 500" STUB_CONTENTS_ERROR_FILE=added.json STUB_CONTENTS_ERROR_CODE=500
assert_exit 1
assert_out "::error::tardisec: could not read added.json from 'main'"
assert_no_writes

run_step "contents API 403" STUB_CONTENTS_ERROR_FILE=changed.json STUB_CONTENTS_ERROR_CODE=403
assert_exit 1
assert_out "::error::tardisec: could not read changed.json from 'main'"
assert_no_writes

run_step "contents API 404 is a new file"
assert_exit 0
assert_called "contents/added.json?ref=${BASE_OID}"
assert_eq "new file in the mutation" added.json "$(mutation '[.fileChanges.additions[].path | select(. == "added.json")][0]')"

remove_listed_file() {
  mv added.json ../moved-away
}
PREPARE=remove_listed_file run_step "listed file gone from disk stops the step"
assert_failed
assert_no_writes

# --- branch guard
run_step "guard: foreign commit" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 1 "feat: real work")"
assert_exit 1
assert_out "::error::tardisec: branch 'tardisec-config' has commits this action did not make"
assert_out "delete or rename"
assert_no_writes

run_step "guard: foreign commit among sync commits" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 2 "${SYNC_MESSAGE}" "feat: real work")"
assert_exit 1
assert_no_writes

run_step "guard: headline on a later line is not the headline" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 1 "feat: real work

${HEADLINE}")"
assert_exit 1
assert_no_writes

run_step "guard: more commits ahead than the API lists" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 251 "${SYNC_MESSAGE}")"
assert_exit 1
assert_no_writes

run_step "guard: only sync commits, reset proceeds" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 2 "${SYNC_MESSAGE}" "${SYNC_MESSAGE}")"
assert_exit 0
assert_called "compare/${BASE_OID}...tardisec-config"
assert_called "-X PATCH repos/o/r/git/refs/heads/tardisec-config -f sha=${BASE_OID} -F force=true"
assert_not_called "-X POST"
assert_called "api graphql"

run_step "guard: no commits ahead, reset proceeds" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 0)"
assert_exit 0
assert_called "-X PATCH repos/o/r/git/refs/heads/tardisec-config"

# The PR's "Update branch" button leaves a merge on top of the sync commit.
MERGE_COMMIT='{"parents":[{},{}],"commit":{"message":"Merge branch main into tardisec-config"}}'
run_step "guard: merge from Update branch, reset proceeds" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 2 "${SYNC_MESSAGE}" | jq -c --argjson merge "${MERGE_COMMIT}" '.commits += [$merge]')"
assert_exit 0
assert_called "-X PATCH repos/o/r/git/refs/heads/tardisec-config"

run_step "guard: a merge does not vouch for the work it brings in" STUB_REFS=tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 3 "${SYNC_MESSAGE}" "feat: real work" | jq -c --argjson merge "${MERGE_COMMIT}" '.commits += [$merge]')"
assert_exit 1
assert_no_writes

run_step "guard: absent branch is created"
assert_exit 0
assert_called "-X POST repos/o/r/git/refs -f ref=refs/heads/tardisec-config -f sha=${BASE_OID}"
assert_called "api graphql"

run_step "guard: orphan branch answers compare 404 but is not absent" STUB_REFS=tardisec-config \
  STUB_COMPARE_CODE=404 STUB_COMPARE_MESSAGE="No common ancestor between main and tardisec-config."
assert_exit 1
assert_out "::error::tardisec: branch 'tardisec-config' has commits this action did not make"
assert_no_writes

run_step "guard: compare 500" STUB_REFS=tardisec-config STUB_COMPARE_CODE=500
assert_exit 1
assert_out "::error::tardisec: could not compare 'tardisec-config' with 'main'"
assert_no_writes

run_step "guard: compare 404, ref lookup 500" STUB_COMPARE_CODE=404 STUB_REF_LOOKUP_CODE=500
assert_exit 1
assert_out "::error::tardisec: could not look up branch 'tardisec-config'"
assert_no_writes

run_step "guard: malformed compare response" STUB_REFS=tardisec-config STUB_COMPARE_JSON='{}'
assert_failed
assert_no_writes

# --- branch names
run_step "slash in an existing branch" BRANCH=chore/tardisec-config STUB_REFS=chore/tardisec-config \
  STUB_COMPARE_JSON="$(compare_json 1 "${SYNC_MESSAGE}")"
assert_exit 0
assert_called "compare/${BASE_OID}...chore/tardisec-config"
assert_called "-X PATCH repos/o/r/git/refs/heads/chore/tardisec-config"
assert_eq "branchName" chore/tardisec-config "$(mutation .branch.branchName)"
assert_called "--head chore/tardisec-config"

run_step "slash in an absent branch" BRANCH=chore/tardisec-config
assert_exit 0
assert_called "git/ref/heads/chore/tardisec-config"
assert_called "-X POST repos/o/r/git/refs -f ref=refs/heads/chore/tardisec-config"

run_step "slash in a branch with a foreign commit" BRANCH=chore/tardisec-config \
  STUB_REFS=chore/tardisec-config STUB_COMPARE_JSON="$(compare_json 1 "feat: real work")"
assert_exit 1
assert_no_writes

# A # would otherwise end the URL path, and the guard would be comparing some other branch.
run_step "branch name that needs encoding" 'BRANCH=chore/a#b' 'STUB_REFS=chore/a%23b' \
  STUB_COMPARE_JSON="$(compare_json 1 "${SYNC_MESSAGE}")"
assert_exit 0
assert_called "compare/${BASE_OID}...chore/a%23b"
assert_called "-X PATCH repos/o/r/git/refs/heads/chore/a%23b"
assert_eq "branchName" 'chore/a#b' "$(mutation .branch.branchName)"

# --- pull request
run_step "no open PR opens one"
assert_exit 0
assert_called "pr create --title ${HEADLINE} --head tardisec-config"
assert_called "--base main"

run_step "existing open PR is left to the commit" STUB_OPEN_PR=7
assert_exit 0
assert_called "api graphql"
assert_not_called "pr create"

echo "pr-step: ${passes} passed, ${failures} failed (${n} scenarios)"
[ "${failures}" -eq 0 ]
