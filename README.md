<br />

<div align="center">
  <a href="https://tardisec.com"><img src="docs/img/tardisec.svg" alt="tardisec" height="32"></a>
  &nbsp;&nbsp;&times;&nbsp;&nbsp;
  <img src="docs/img/logo.svg" alt="GitHub Actions" height="36">
</div>

<br />

# tardisec sync — GitHub Action

Type: `sync` — pulls your domain's recommended security config files from tardisec and
opens a pull request. Authenticates with the workflow's OIDC token: **no secret to store**,
tardisec holds no credentials for your repo.

<!-- tardisec:authn -->
## Authentication

**workload OIDC** (JWT). The forge mints a short-lived token per run and tardisec verifies it against the forge's published keys.

- **Secret stored:** none.
- **Calls:** `GET /v1/...` directly. This path does not use `POST /oauth/token`.
- **Scope:** the repo bound to the domain in app.tardisec.com.
<!-- /tardisec:authn -->

## Setup

1. On [app.tardisec.com](https://app.tardisec.com): domain → **Settings → Integrations →
   Config sync** → provider **GitHub**, repo `owner/name`.
2. Add `.github/workflows/tardisec.yml`:

```yaml
name: tardisec
on:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch: {}

permissions: {}

jobs:
  sync:
    runs-on: ubuntu-latest
    permissions:
      id-token: write       # mint the OIDC token tardisec verifies
      contents: write       # create the sync branch and commit
      pull-requests: write  # open the PR
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false  # nothing is pushed; the commit goes over the API
      - uses: tardisec/tardisec-integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: |
            .tardisec.json
            .tardisec.sveltekit.json
```

`files` is one filename per line; see
[files you can pull](https://tardisec.com/docs/integrations#files-you-can-pull) for available
filenames. Runs weekly and on demand; when nothing changed, no PR. Re-runs reset the same
`tardisec-config` branch, so an open PR just updates.

The PR targets the branch that triggered the run. To target another one, set `base`. The
sync branch starts from the tip of `base`, whatever the checkout holds. `branch` renames the
sync branch. Every run force-resets that branch to `base`, so the step fails if the branch
holds any commit ahead of `base` other than merges and its own
`chore: sync tardisec config` commits. To clear that, pick another `branch`, or delete or
rename that one:

```yaml
        with:
          domain: example.com
          base: develop
          branch: chore/tardisec-config
```

`path` applies to every file in the block, so files that belong in different directories
need a block each. A static site publishing `.well-known/` out of `static/`:

```yaml
      - uses: tardisec/tardisec-integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: .tardisec.json
          pull-request: "false"   # let the last block open the PR
      - uses: tardisec/tardisec-integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: .well-known/tardisec-verification.txt
          path: static
```

The PR step commits the files from every block, so both blocks land in one commit.

## Matching your formatter

The API cannot serve a body that is clean under every formatter at once: biome wants tabs,
prettier wants two spaces, and both collapse short arrays that `JSON.stringify` expands. The
served files are tab-indented with a trailing newline, and `format` hands them to your own
formatter before they are committed:

```yaml
        with:
          domain: example.com
          files: .tardisec.json
          format: npx biome format --write
```

The fetched file paths are appended to the command, so only the synced files are touched;
passing a directory would drag your whole repo into the sync PR. Formatting is
deterministic, so a re-run produces identical bytes and no spurious diff. Without `format`,
a repo that enforces formatting in CI will fail that check on the sync PR.

One trade-off worth knowing. Each run offers the file it already has as a validator, so an
unchanged file answers `304` and is not transferred again. That validator is the sha256 of
the file on disk, which is exactly what the API computes its ETag from, so `format` opts you
out of it: once your formatter has rewritten the bytes they no longer match what the API
serves, and every run is a full `200` refetch. Nothing breaks and nothing is lost, you
simply do not get the conditional request. If the saved transfer matters more than matching
your formatter, drop `format` and exclude the synced paths from your CI format check
instead.

The commit is created through GitHub's API rather than pushed from the runner, so it is
**Verified** (signed server-side, still no secret to store) and carries a `Signed-off-by`
trailer for DCO. The trailer comes from the token's identity on `GET /user`. A failed lookup
falls back to `github-actions[bot]`, which is correct for the default `github.token` since it
cannot read `/user`, so no secret is needed. With any other token, a failed lookup means the
trailer names the bot rather than the commit's author.

## Inputs

| Input          | Default                    |                                              |
| -------------- | -------------------------- | -------------------------------------------- |
| `domain`       | — (required)               | Domain as configured on app.tardisec.com     |
| `files`        | `.tardisec.json`           | Config filenames, one per line               |
| `path`         | `.`                        | Directory to write them into                 |
| `format`       | — (none)                   | Command run over the fetched files pre-commit |
| `api`          | `https://api.tardisec.com` | API origin / OIDC audience                   |
| `pull-request` | `true`                     | Set `false` to only fetch the files          |
| `token`        | `${{ github.token }}`      | Token for the commit + PR create             |
| `base`         | `${{ github.ref_name }}`   | Branch the PR targets and the sync starts from |
| `branch`       | `tardisec-config`          | Sync branch, reset to `base` on every run    |

## Test

`test/e2e.sh` runs the action locally with [act](https://github.com/nektos/act) against a
mock API + mock OIDC issuer (requires docker, node, act). It skips the PR step.

`test/pr-step.sh` runs the PR step's script against a stubbed `gh` (requires bash, git, jq).
The stub only knows what GitHub's API is expected to answer, so it does not replace a run on
a real repo.
