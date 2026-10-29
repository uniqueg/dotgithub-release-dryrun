#!/usr/bin/env bash
# Tests of `.github/scripts/release.sh`: builds a scratch repository with
# commits and tags, plans releases and renders release notes (with a fake
# `gh` for the GitHub API). Run from the repository root:
# `bash tests/release/test.sh`
set -euo pipefail

script="${PWD}/.github/scripts/release.sh"
failures=0
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# The scratch repository has no remote
export RELEASE_BRANCH=main

repo="${work}/repo"
git init -q -b main "${repo}"
cd "${repo}"

# commit <file> <message>: changes <file> and commits it
commit() {
  mkdir -p "$(dirname "$1")"
  echo "${RANDOM}" >> "$1"
  git add "$1"
  git commit -q -m "$2"
  git rev-parse HEAD
}

# expect_plan <commit> <expected output, lines joined by spaces>
expect_plan() {
  local got
  got="$(bash "${script}" plan "$1" | paste -sd ' ' -)" || got="error"
  if [[ "${got}" != "$2" ]]; then
    echo "NOT OK: plan $1: expected ${2@Q}, got ${got@Q}"
    failures=$((failures + 1))
  else
    echo "ok: plan: ${2:-no release}"
  fi
}

# expect_in <name> <expected substring> <text>: <text> contains the
# substring
expect_in() {
  if [[ "$3" != *"$2"* ]]; then
    echo "NOT OK: $1: expected ${2@Q} in:"
    echo "$3"
    failures=$((failures + 1))
  else
    echo "ok: $1"
  fi
}

# expect_not_in <name> <substring> <text>: <text> doesn't contain it
expect_not_in() {
  if [[ "$3" == *"$2"* ]]; then
    echo "NOT OK: $1: unexpected ${2@Q} in:"
    echo "$3"
    failures=$((failures + 1))
  else
    echo "ok: $1"
  fi
}

# The cases build on each other: each adds commits and tags to the same
# history, so add new cases at the end of their section

# No actions yet: docs and CI don't release
docs="$(commit README.md "docs: add README")"
expect_plan "${docs}" ""
ci="$(commit .github/workflows/ci.yml "ci: set up CI (#2)")"
expect_plan "${ci}" ""
# An action's README alone doesn't release
readme="$(commit actions/gate/README.md "docs: describe the gate (#3)")"
expect_plan "${readme}" ""

# The first release is v1.0.0, whatever the type
first="$(commit actions/gate/check.sh "ci: add the gate action (#5)")"
expect_plan "${first}" "tag=v1.0.0 previous="
git tag v1.0.0 "${first}"
expect_plan "${first}" ""

# Patch, minor and major bumps; the highest wins
fix="$(commit actions/gate/check.sh "fix(gate): handle null (#7)")"
expect_plan "${fix}" "tag=v1.0.1 previous=v1.0.0"
feat="$(commit actions/pr-title/action.yml "feat: add the pr-title action (#9)")"
expect_plan "${feat}" "tag=v1.1.0 previous=v1.0.0"
# Commits outside the actions don't count for the bump
outside="$(commit tests/x.sh "feat!: change the tests (#10)")"
expect_plan "${outside}" "tag=v1.1.0 previous=v1.0.0"
git tag v1.1.0 "${outside}"
bang="$(commit actions/gate/action.yml "refactor(gate)!: rename an input (#12)")"
expect_plan "${bang}" "tag=v2.0.0 previous=v1.1.0"
footer="$(commit actions/gate/check.sh "$(printf 'fix: tighten the gate (#14)\n\nBREAKING CHANGE: skips fail')")"
expect_plan "${footer}" "tag=v2.0.0 previous=v1.1.0"
# `feat` in a word or a body doesn't count; a `BREAKING CHANGE` mention
# that isn't a footer line doesn't either
featish="$(commit actions/gate/check.sh "$(printf 'chore: feature flags (#15)\n\nfeat: no\nnot a BREAKING CHANGE: no')")"
git tag v2.0.0 "${footer}"
expect_plan "${featish}" "tag=v2.0.1 previous=v2.0.0"

# Commits that are already released: an older commit after a newer release
expect_plan "${bang}" ""
expect_plan "${footer}" ""
# Tags other than vX.Y.Z don't count
git tag v9 "${featish}"
git tag v10.0.0-rc1 "${featish}"
# The dots are literal; no leading zeros
git tag v3x0x0 "${featish}"
git tag v2.08.0 "${featish}"
expect_plan "${featish}" "tag=v2.0.1 previous=v2.0.0"
# Only release tags on ancestors count: a stray tag elsewhere (e.g. on a
# side branch) neither blocks nor bumps releases of `main`
git switch -q -c side "${first}"
side="$(commit actions/gate/check.sh "fix: on a side branch (#16)")"
git tag v9.9.9 "${side}"
git switch -q main
expect_plan "${featish}" "tag=v2.0.1 previous=v2.0.0"
# A tag on a work branch doesn't count as a release of its ancestors
git switch -q -c work "${featish}"
wip="$(commit actions/gate/check.sh "wip: try something")"
git tag v0.0.9 "${wip}"
git switch -q main
expect_plan "${featish}" "tag=v2.0.1 previous=v2.0.0"
# The next version exists as a tag elsewhere: fail rather than release the
# commit of that tag
git tag v2.0.1 "${side}"
expect_plan "${featish}" "error"
git tag -d v2.0.1 > /dev/null
expect_plan "not-a-commit" "error"
RELEASE_BRANCH=no-such-branch expect_plan "${featish}" "error"

# Release notes, with a fake `gh` that answers like the GitHub API: PR 12
# closes issues 11 and 4 (and one in another repository), PR 7 closes issue
# 6, number 15 is no pull request, PR 99 fails; the others close none
mkdir "${work}/bin"
cat > "${work}/bin/gh" << 'EOF'
#!/usr/bin/env bash
issue() { printf '{"number": %s, "repository": {"nameWithOwner": "%s"}}' "$1" "$2"; }
pr() { printf '{"data": {"repository": {"pullRequest": {"closingIssuesReferences": {"nodes": [%s]}}}}}\n' "$1"; }
if [[ "$1 $2" == "api graphql" ]]; then
  case "$*" in
    *"number=12 "*) pr "$(issue 11 org/repo), $(issue 3 org/other), $(issue 4 org/repo)" ;;
    *"number=7 "*) pr "$(issue 6 org/repo)" ;;
    *"number=15 "*)
      echo '{"data": {"repository": {"pullRequest": null}}, "errors": [{"type": "NOT_FOUND"}]}'
      exit 1 ;;
    *"number=99 "*) echo '{"message": "Bad credentials"}'; exit 1 ;;
    *"number=98 "*) echo '{"data": null, "errors": [{"type": "RATE_LIMITED"}]}' ;;
    *) pr "" ;;
  esac
elif [[ "$2" == */releases/generate-notes ]]; then
  printf '%s\n' "## What's Changed" "* fix: a by @u in https://x/pull/7" "" \
    "## New Contributors" "* @u made their first contribution" "" \
    "**Full Changelog**: https://x/compare/v1.1.0...v2.0.0"
  echo "args: $*" >> "${GH_ARGS_LOG}"
else
  echo "unexpected gh call: $*" >&2
  exit 1
fi
EOF
chmod +x "${work}/bin/gh"
export GH_ARGS_LOG="${work}/gh-args"

# render_notes <tag> <previous> <commit>
render_notes() {
  : > "${GH_ARGS_LOG}"
  PATH="${work}/bin:${PATH}" GH_REPO=org/repo bash "${script}" notes "$@"
}

commit actions/gate/action.yml "build(deps): Bump actions/x from 1 to 2 (#17)" > /dev/null
commit actions/gate/action.yml "build(deps): Bump actions/y from 1 to 2" > /dev/null
commit actions/gate/check.sh "fix(security): quote job IDs (#18)" > /dev/null
commit actions/gate/README.md "docs(gate): explain skips (#19)" > /dev/null
# Breaking, but not for callers: changes no action
commit .github/workflows/ci.yml "ci!: require the new gate (#20)" > /dev/null
plain="$(commit actions/gate/check.sh "Merge something without a type")"
notes="$(render_notes v2.0.1 v2.0.0 "${plain}")" || notes="error"
expect_in "intro" "Release v2.0.1 of the shared actions of ELIXIR Cloud & AAI, with changes to \`gate\`. Callers pin" "${notes}"
expect_not_in "no breaking changes in a patch release" "reaking" "${notes}"
expect_in "fix with scope security" $'## Security\n\n- Quote job IDs (#18).' "${notes}"
expect_in "docs" $'## Documentation\n\n- Explain skips (#19).' "${notes}"
expect_in "maintenance (no PR for #15, deps last)" $'## Maintenance\n\n- Feature flags (#15).\n- Require the new gate (#20).\n- Merge something without a type.\n- Dependency updates (#17).' "${notes}"
expect_in "commits" $'## Commits\n\n* fix: a by @u in https://x/pull/7\n\n## New Contributors\n* @u made their first contribution\n\n**Full Changelog**: https://x/compare/v1.1.0...v2.0.0' "${notes}"
expect_not_in "no What's Changed" "What's Changed" "${notes}"
expect_in "generated notes: tag, commit and previous tag" \
  "tag_name=v2.0.1 -f target_commitish=${plain} -f previous_tag_name=v2.0.0" \
  "$(cat "${GH_ARGS_LOG}")"

# Breaking changes of the actions: section, intro; issues of the same
# repository, sorted, before the PR number
notes="$(render_notes v2.0.0 v1.1.0 "${footer}")" || notes="error"
expect_in "breaking intro" "It contains breaking changes" "${notes}"
expect_in "breaking section" $'## Breaking changes\n\n- Rename an input (#4, #11, #12).\n- Tighten the gate (#14).\n' "${notes}"

# A `!` outside the actions is no breaking change for callers
notes="$(render_notes v1.1.0 v1.0.0 "${outside}")" || notes="error"
expect_not_in "breaking outside the actions" "reaking" "${notes}"
expect_in "sections in order" $'## Features\n\n- Add the pr-title action (#9).\n- Change the tests (#10).\n\n## Fixes\n\n- Handle null (#6, #7).\n' "${notes}"
expect_in "two actions" "with changes to \`gate\` and \`pr-title\`." "${notes}"

# A breaking dependency update of an action is a breaking change; a
# dependency update without a PR number still gets a bullet
breaking_deps="$(commit actions/gate/action.yml "build(deps)!: Bump actions/z from 1 to 2 (#21)")"
notes="$(render_notes v3.0.0 v2.0.0 "${breaking_deps}")" || notes="error"
expect_in "breaking dependency update" $'## Breaking changes\n\n- Bump actions/z from 1 to 2 (#21).' "${notes}"
git switch -q -c deps-only "${featish}"
commit actions/gate/action.yml "build(deps): Bump actions/y from 1 to 2" > /dev/null
notes="$(render_notes v2.0.1 v2.0.0 HEAD)" || notes="error"
expect_in "dependency update without PR" $'## Maintenance\n\n- Feature flags (#15).\n- Dependency updates.' "${notes}"
git switch -q main

# The first release lists all actions
notes="$(render_notes v1.0.0 "" "${first}")" || notes="error"
expect_in "first intro" "The first release of the shared actions of ELIXIR Cloud & AAI: \`gate\`. Callers" "${notes}"
expect_in "first: maintenance" $'## Maintenance\n\n- Set up CI (#2).\n- Add the gate action (#5).' "${notes}"
expect_not_in "first: no previous tag" "previous_tag_name" "$(cat "${GH_ARGS_LOG}")"

# Failures: API errors of the issue lookup (failed call; errors in a
# successful response), no GH_REPO
for number in 99 98; do
  commit actions/gate/check.sh "fix: something (#${number})" > /dev/null
  if errors="$(render_notes v3.0.1 HEAD^ HEAD 2>&1 > /dev/null)"; then
    echo "NOT OK: notes should fail on an API error (#${number})"
    failures=$((failures + 1))
  else
    expect_in "notes fail on an API error (#${number})" \
      "Could not look up the issues closed by #${number}" "${errors}"
  fi
done
if GH_REPO="" bash "${script}" notes v1.0.0 "" "${first}" > /dev/null 2>&1; then
  echo "NOT OK: notes without GH_REPO should fail"
  failures=$((failures + 1))
else
  echo "ok: notes need GH_REPO"
fi

if ((failures > 0)); then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "All tests passed"
