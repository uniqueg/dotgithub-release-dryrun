#!/usr/bin/env bash
# Checks the results of the jobs a CI gate needs. Input in the environment:
# GATE_NEEDS (`toJSON(needs)`) and GATE_ALLOW_SKIPPED (job IDs that may be
# skipped, separated by whitespace). Fails when there are no results, when a
# job did not succeed and was not an allowed skip; lists the offending jobs
# in the log and, if available, the step summary
set -euo pipefail

needs="${GATE_NEEDS:-}"
read -r -d "" -a allowed <<< "${GATE_ALLOW_SKIPPED:-}" || true

if ! jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<< "${needs}"; then
  echo "::error title=Gate::No job results (is \`needs\` empty?)"
  exit 1
fi

allowed_json="$(jq -cn '$ARGS.positional' --args "${allowed[@]}")"
offending="$(jq -r --argjson allowed "${allowed_json}" '
  to_entries[]
  | select((.value | type) != "object" or .value.result != "success")
  | select((.value | type) != "object" or .value.result != "skipped"
      or (.key | IN($allowed[]) | not))
  | "\(.key): \(if (.value | type) == "object" then .value.result else "malformed" end)"' <<< "${needs}")"

if [[ -n "${offending}" ]]; then
  # Strip characters that could start a workflow command
  offending="${offending//::/}"
  echo "::error title=Gate::Jobs did not pass: ${offending//$'\n'/, }"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Jobs that did not pass"
      echo
      while IFS= read -r line; do echo "- ${line}"; done <<< "${offending}"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi
echo "All needed jobs passed"

# Dry run of the release workflow
