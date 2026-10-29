#!/usr/bin/env bash
# Release steps of `.github/workflows/release.yml`; see RELEASING.md. Run
# from the root of a full clone (all commits and tags):
#
#   release.sh plan <commit>
#     Prints `tag=<vX.Y.Z>` and `previous=<last release or empty>` if
#     <commit> needs a release, nothing otherwise. A release is needed if a
#     commit since the last release (the highest `vX.Y.Z` tag on an ancestor
#     of <commit>) changed a file under `actions/` other than Markdown; the
#     bump follows the Conventional Commit messages of these commits: `!` or
#     a `BREAKING CHANGE:` footer gives a major, `feat` a minor, anything else
#     a patch release. The first release is v1.0.0. Prints nothing if
#     <commit> is already part of a release on the release branch
#     (RELEASE_BRANCH, by default `origin/main`); fails if the tag exists.
#
#   release.sh notes <tag> <previous release or ""> <commit>
#     Prints the release notes of <tag> in the organisation's format. Calls
#     `gh` for the issues that each pull request closes and for GitHub's
#     generated notes; needs GH_REPO (`<owner>/<repo>`) and a token.
set -euo pipefail

# The pathspec of the files that callers run: the actions, without docs
release_paths=(actions ':(exclude,glob)actions/**/*.md')
# The branch of the releases
release_branch="${RELEASE_BRANCH:-origin/main}"
# Release tags: SemVer `vX.Y.Z`, without leading zeros
tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

die() {
  echo "::error title=Release::$*" >&2
  exit 1
}

# The highest release tag on <commit> or its ancestors, or nothing. No early
# exit in the pipeline, so that `git tag` never gets SIGPIPE
last_release() {
  git tag --merged "$1" --list 'v*' --sort=-v:refname \
    | TAG_PATTERN="${tag_pattern}" awk '$0 ~ ENVIRON["TAG_PATTERN"] && !found { print; found = 1 }'
}

# Whether a release tag on the release branch points to <commit> or one of
# its descendants (tags elsewhere, e.g. on a work branch, don't count)
released() {
  git tag --contains "$1" --merged "${release_branch}" --list 'v*' \
    | TAG_PATTERN="${tag_pattern}" awk '$0 ~ ENVIRON["TAG_PATTERN"] { found = 1 } END { exit !found }'
}

# The range of commits from <previous release> (exclusive) to <commit>
commit_range() {
  if [[ -n "$1" ]]; then
    echo "$1..$2"
  else
    echo "$2"
  fi
}

# Parses the commit message <message> into the variables `type` (lowercase;
# empty if the subject is no Conventional Commit), `scope`, `description`
# (without the pull request number), `pr` (the number in a trailing
# `(#<number>)`, as in squash merges, or empty) and `breaking` (1 for `!` or
# a `BREAKING CHANGE:` footer, else 0)
parse_message() {
  local message="$1" subject
  subject="${message%%$'\n'*}"
  type="" scope="" pr="" breaking=0
  if [[ "${subject}" =~ \ \(#([0-9]+)\)$ ]]; then
    pr="${BASH_REMATCH[1]}"
    subject="${subject% (#*}"
  fi
  description="${subject}"
  if [[ "${subject}" =~ ^([A-Za-z]+)(\(([^\)]*)\))?(!?):\ +(.*)$ ]]; then
    type="${BASH_REMATCH[1],,}" scope="${BASH_REMATCH[3]}"
    description="${BASH_REMATCH[5]}"
    [[ -z "${BASH_REMATCH[4]}" ]] || breaking=1
  fi
  if grep -qE '^BREAKING[ -]CHANGE:' <<< "${message}"; then
    breaking=1
  fi
}

plan() {
  local commit previous level=0 message major minor patch tag
  local type scope description pr breaking
  [[ $# -eq 1 ]] || die "Usage: release.sh plan <commit>"
  commit="$(git rev-parse --verify --quiet "$1^{commit}")" \
    || die "Not a commit: $1"
  git rev-parse --verify --quiet "${release_branch}^{commit}" > /dev/null \
    || die "Release branch not found: ${release_branch}"
  # Already released, e.g. a run for an older push that waited while a
  # newer push was released
  if released "${commit}"; then
    return 0
  fi
  previous="$(last_release "${commit}")"
  while IFS= read -r -d '' message; do
    parse_message "${message}"
    if ((breaking)); then
      level=3
    elif [[ "${type}" == feat ]] && ((level < 2)); then
      level=2
    elif ((level < 1)); then
      level=1
    fi
  done < <(git log -z --format=%B "$(commit_range "${previous}" "${commit}")" \
    -- "${release_paths[@]}")
  ((level > 0)) || return 0
  if [[ -z "${previous}" ]]; then
    tag=v1.0.0
  else
    IFS=. read -r major minor patch <<< "${previous#v}"
    case "${level}" in
      3) tag="v$((10#${major} + 1)).0.0" ;;
      2) tag="v${major}.$((10#${minor} + 1)).0" ;;
      *) tag="v${major}.${minor}.$((10#${patch} + 1))" ;;
    esac
  fi
  # A tag elsewhere (e.g. set by hand on another branch) would make the
  # release API publish that tag's commit instead of <commit>
  if git rev-parse --verify --quiet "refs/tags/${tag}" > /dev/null; then
    die "The tag ${tag} exists but isn't on an ancestor of ${commit}"
  fi
  echo "tag=${tag}"
  echo "previous=${previous}"
}

# The numbers of the issues in this repository that pull request <number>
# closes (at most 100), space-separated. Nothing if <number> is no pull request (e.g., an
# issue named in a commit pushed directly); fails on other API errors
closed_issues() {
  local response
  # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
  if ! response="$(gh api graphql -F number="$1" -F owner="${GH_REPO%%/*}" \
    -F name="${GH_REPO#*/}" -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            closingIssuesReferences(first: 100) {
              nodes { number repository { nameWithOwner } }
            }
          }
        }
      }')"; then
    if jq -e '.data.repository.pullRequest == null
        and any(.errors[]?; .type == "NOT_FOUND")' \
        > /dev/null 2>&1 <<< "${response}"; then
      return 0
    fi
    die "Could not look up the issues closed by #$1: ${response}"
  fi
  if ! jq -e '(.errors // []) == [] and .data.repository.pullRequest != null' \
      > /dev/null 2>&1 <<< "${response}"; then
    die "Could not look up the issues closed by #$1: ${response}"
  fi
  jq -r --arg repo "${GH_REPO}" '
    [.data.repository.pullRequest.closingIssuesReferences.nodes[]
      | select(.repository.nameWithOwner == $repo) | .number]
    | sort | map(tostring) | join(" ")' <<< "${response}"
}

# Drops leading and trailing blank lines
trim_blank_lines() {
  awk '{ lines[NR] = $0 }
    NF && !first { first = NR }
    NF { last = NR }
    END { for (i = first; first && i <= last; i++) print lines[i] }'
}

# Joins the arguments as `#1, #2`
refs() {
  local out="" n
  for n in "$@"; do
    out+="${out:+, }#${n}"
  done
  echo "${out}"
}

# Joins the arguments as code spans: "`a`, `b` and `c`"
code_list() {
  local out="" i
  for ((i = 1; i <= $#; i++)); do
    if ((i > 1)); then
      if ((i == $#)); then out+=" and "; else out+=", "; fi
    fi
    out+="\`${!i}\`"
  done
  echo "${out}"
}

notes() {
  local tag previous commit range sha message heading generated issues
  local has_deps=0
  local type scope description pr breaking
  local -A sections=() relevant=()
  local -a deps=() changed=() numbers=()
  [[ $# -eq 3 ]] || die "Usage: release.sh notes <tag> <previous> <commit>"
  tag="$1" previous="$2" commit="$3"
  [[ -n "${GH_REPO:-}" ]] || die "GH_REPO is not set"
  range="$(commit_range "${previous}" "${commit}")"

  # Commits that changed the actions: only their breaking changes are
  # breaking for callers (as in `plan`)
  while IFS= read -r sha; do
    relevant[${sha}]=1
  done < <(git rev-list "${range}" -- "${release_paths[@]}")

  while IFS= read -r sha; do
    message="$(git log -1 --format=%B "${sha}")"
    parse_message "${message}"
    numbers=()
    if [[ -n "${pr}" ]]; then
      issues="$(closed_issues "${pr}")"
      read -r -a numbers <<< "${issues}"
      numbers+=("${pr}")
    fi
    if ((breaking)) && [[ -n "${relevant[${sha}]:-}" ]]; then
      heading="Breaking changes"
    elif [[ "${type}" == build && "${scope}" == deps ]]; then
      # Dependabot's updates share one bullet
      has_deps=1
      deps+=("${numbers[@]}")
      continue
    else
      case "${type}:${scope}" in
        *:security) heading=Security ;;
        feat:*) heading=Features ;;
        fix:*) heading=Fixes ;;
        docs:*) heading=Documentation ;;
        *) heading=Maintenance ;;
      esac
    fi
    description="${description^}"
    if ((${#numbers[@]} > 0)); then
      description+=" ($(refs "${numbers[@]}"))"
    fi
    sections[${heading}]+="- ${description}."$'\n'
  done < <(git rev-list --reverse "${range}")
  if ((${#deps[@]} > 0)); then
    sections[Maintenance]+="- Dependency updates ($(refs "${deps[@]}"))."$'\n'
  elif ((has_deps)); then
    sections[Maintenance]+="- Dependency updates."$'\n'
  fi

  # Intro: the actions whose files (other than docs) changed, and whether
  # the release is a major one
  mapfile -t changed < <(git diff --name-only \
    "${previous:-$(git hash-object -t tree /dev/null)}" "${commit}" \
    -- "${release_paths[@]}" | awk -F/ '{ print $2 }' | sort -u)
  if [[ -z "${previous}" ]]; then
    printf 'The first release of the shared actions of ELIXIR Cloud & AAI'
    ((${#changed[@]} == 0)) || printf ': %s' "$(code_list "${changed[@]}")"
  else
    printf 'Release %s of the shared actions of ELIXIR Cloud & AAI' "${tag}"
    ((${#changed[@]} == 0)) \
      || printf ', with changes to %s' "$(code_list "${changed[@]}")"
  fi
  # shellcheck disable=SC2016  # Markdown code spans, not expansions
  printf '. Callers pin `elixir-cloud-aai/.github/actions/<name>@<commit> # %s`; Dependabot proposes the update.' \
    "${tag}"
  if [[ -n "${previous}" && "${tag%%.*}" != "${previous%%.*}" ]]; then
    printf ' It contains breaking changes: see below for what callers have to change.'
  fi
  printf '\n'

  for heading in "Breaking changes" Features Security Fixes Documentation \
    Maintenance; do
    if [[ -n "${sections[${heading}]:-}" ]]; then
      printf '\n## %s\n\n%s' "${heading}" "${sections[${heading}]}"
    fi
  done

  # GitHub's generated notes: the list of pull requests (without its
  # heading) under `## Commits`, the `**Full Changelog**` line last
  local -a args=(-f tag_name="${tag}" -f target_commitish="${commit}")
  [[ -z "${previous}" ]] || args+=(-f previous_tag_name="${previous}")
  generated="$(gh api "repos/${GH_REPO}/releases/generate-notes" \
    "${args[@]}" --jq .body)"
  local commits changelog
  commits="$(grep -v -e "^## What's Changed" -e '^\*\*Full Changelog\*\*' \
    <<< "${generated}" | trim_blank_lines || true)"
  changelog="$(grep '^\*\*Full Changelog\*\*' <<< "${generated}" || true)"
  if [[ -n "${commits}" ]]; then
    printf '\n## Commits\n\n%s\n' "${commits}"
  fi
  if [[ -n "${changelog}" ]]; then
    printf '\n%s\n' "${changelog}"
  fi
}

case "${1:-}" in
  plan) shift; plan "$@" ;;
  notes) shift; notes "$@" ;;
  *) die "Usage: release.sh plan <commit> | notes <tag> <previous> <commit>" ;;
esac
