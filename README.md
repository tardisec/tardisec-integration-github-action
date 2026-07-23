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

permissions:
  id-token: write       # mint the OIDC token tardisec verifies
  contents: write       # push the sync branch
  pull-requests: write  # open the PR

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tardisec/integration-github-action@v1
        with:
          domain: example.com
          files: .tardisec.sveltekit.json
```

`files` is space-separated; see the
[integration list](https://github.com/tardisec/integration-template) for available
filenames. Runs weekly and on demand; when nothing changed, no PR. Re-runs force-push the
same `tardisec-config` branch, so an open PR just updates.

## Inputs

| Input          | Default                    |                                              |
| -------------- | -------------------------- | -------------------------------------------- |
| `domain`       | — (required)               | Domain as configured on app.tardisec.com     |
| `files`        | `.tardisec.json`           | Space-separated config filenames             |
| `api`          | `https://api.tardisec.com` | API origin / OIDC audience                   |
| `pull-request` | `true`                     | Set `false` to only fetch the files          |
| `token`        | `${{ github.token }}`      | Token for branch push + PR create            |

## Test

`test/e2e.sh` runs the action locally with [act](https://github.com/nektos/act) against a
mock API + mock OIDC issuer (requires docker, node, act). The PR step is exercised on a
real repo only.
