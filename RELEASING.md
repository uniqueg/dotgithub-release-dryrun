# Releasing

The composite actions in `actions/<name>/` are used by the other
repositories of the organisation, which pin them to the commit of a release:

```yaml
- uses: elixir-cloud-aai/.github/actions/<name>@<40-character SHA> # vX.Y.Z
```

Releases are automatic: there is nothing to do by hand. Dependabot
(`github-actions` ecosystem) in each calling repository then proposes to bump
the pin to the commit of the latest release and updates the `# vX.Y.Z`
comment. A change here reaches a repository only when that repository merges
the bump, so every release must be safe to adopt on its own.

## How releases happen

When CI passes for a push to `main` (a merged pull request), the `Release`
workflow (`.github/workflows/release.yml`) runs
`.github/scripts/release.sh`:

1. **Whether to release:** only if a commit since the last release changed a
   file under `actions/` other than Markdown, i.e., something that callers
   run. Changes to docs, CI, tests or workflow templates alone don't release,
   so that callers get no Dependabot pull requests for them; they appear in
   the notes of the next release.
2. **The version** follows the [Conventional
   Commits](https://www.conventionalcommits.org/) messages (the pull request
   titles) of the commits that changed the actions: a breaking change (`!`
   after the type or scope, or a `BREAKING CHANGE:` footer) gives a new major
   version, `feat` a new minor version, any other type a new patch version.
   The first release is `v1.0.0`.
3. **The release:** the workflow creates the tag `vX.Y.Z` on the commit and a
   GitHub release with notes in the organisation's format (below), both via
   the GitHub API, so that nothing is pushed to `main`.

A run that finds no changes to release, or a commit that is already part of
a release, ends without creating anything. If the release step fails (e.g.,
because of a tag ruleset), nothing is created; rerun the failed workflow run
once the cause is fixed, or leave it to the next push to `main` or to the
weekly run of the workflow (Mondays), which releases the latest commit of
`main` that passed CI.

Changes to the actions are released as soon as they are merged; a release
covers all commits since the last release (several, if several pull requests
were merged in quick succession). Milestones are therefore not used here: a
change must be complete and safe for callers when it is merged. The tags are
lightweight tags that the release API creates, not signed annotated tags.
Tags and releases are never changed or reused: a release with a mistake
(e.g., a wrong version) is fixed by the next release.
Don't create `vX.Y.Z` tags or releases by hand: the workflow computes the
next version from the release tags on `main` (pull requests are
squash-merged, so tags on other branches never become part of `main`), and
fails if the next version exists as a tag elsewhere.

## Versions

- Releases are semantic versions, `vMAJOR.MINOR.PATCH`, for the repository
  as a whole (not per action).
- Breaking changes, such as a new required input, a removed input or output,
  or changed check semantics, only go into a new major version: mark them in
  the pull request title (e.g., `feat(gate)!: …`) and say in its description
  what callers have to change.
- New actions and new inputs are features (`feat`), even if they only serve
  CI.
- There are no moving tags (`v1`, `latest`). Callers pin commits, and
  Dependabot bumps a pin `@<SHA> # vX.Y.Z` whose commit carries a version tag
  to the commit of the latest version tag. It moves a pin to a commit
  without a version tag to the latest commit of `main` instead, and leaves
  the comment as it was, so pin the commit of a release.

## Release notes

The workflow writes the notes from the commits since the last release:

1. An intro paragraph that names the changed actions and, for a major
   release, points to the breaking changes.
2. Grouped sections, empty ones left out, in this order:
   `## Breaking changes`, `## Features`, `## Security`, `## Fixes`,
   `## Documentation`, `## Maintenance`. Each commit goes into one section:
   breaking changes of the actions (as for the version) into
   `## Breaking changes`; otherwise scope `security` into `## Security`,
   `feat` into `## Features`, `fix` into `## Fixes`, `docs` into
   `## Documentation`, and all other types (also `perf`, `refactor`,
   `revert` and subjects without a type) into `## Maintenance`, where
   Dependabot's updates (`build(deps)`) share one bullet. Each bullet is the
   description of a pull request title and ends with the issues that the
   pull request closes and its number.
3. `## Commits`: GitHub's generated notes, without their `## What's Changed`
   header.
4. The last line is GitHub's generated `**Full Changelog**: …` line.

Edit the notes of a release afterwards if they need more context, e.g., for
the migration steps of a major release.
