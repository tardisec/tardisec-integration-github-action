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
      - uses: tardisec/integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: |
            .tardisec.json
            .tardisec.sveltekit.json
```


`files` is one filename per line; see the
[integration list](https://github.com/tardisec/integration-template) for available
filenames. Runs weekly and on demand; when nothing changed, no PR. Re-runs reset the same
`tardisec-config` branch, so an open PR just updates.

`path` applies to every file in the block, so files that belong in different directories
need a block each. A static site publishing `.well-known/` out of `static/`:

```yaml
      - uses: tardisec/integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: .tardisec.json
          pull-request: "false"   # let the last block open the PR
      - uses: tardisec/integration-github-action@c7cd9150af8f374c2999e974d903d680453d828b # v1
        with:
          domain: example.com
          files: .well-known/tardisec-verification.txt
          path: static
```

The PR step stages everything, so both blocks land in one commit.

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

The commit is created through GitHub's API rather than pushed from the runner, so it is
**Verified** (signed server-side, still no secret to store) and carries a `Signed-off-by`
trailer for DCO.

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

## Test

`test/e2e.sh` runs the action locally with [act](https://github.com/nektos/act) against a
mock API + mock OIDC issuer (requires docker, node, act). The PR step is exercised on a
real repo only.
