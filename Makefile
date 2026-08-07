# Every linter runs in a digest-pinned container, so a local run and the CI job execute
# the same tool at the same version. The workflows call these targets, so CI and local
# runs cannot drift. Requires: docker.
.PHONY: lint test test-lint test-lint-actionlint test-lint-yamllint test-lint-shellcheck \
        test-sast test-sast-trivy test-sast-trivy-license test-sast-semgrep \
        test-sast-gitleaks test-sast-trufflehog

DOCKER_RUN = docker run --rm -v "$(CURDIR)":/repo -w /repo

# https://hub.docker.com/r/rhysd/actionlint/tags
ACTIONLINT_IMAGE = rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 # v1.7.12
# https://hub.docker.com/r/pipelinecomponents/yamllint/tags
YAMLLINT_IMAGE = pipelinecomponents/yamllint@sha256:5ab5eb7da0ed5e606b07c1723fc8b275e925189f70ac259b26b7329cb5f8f44d # v1.37.1
# https://hub.docker.com/r/koalaman/shellcheck-alpine/tags
SHELLCHECK_IMAGE = koalaman/shellcheck-alpine@sha256:c82fe42504fbc9fc68f15d36638e5ee2324ebb8b94e96a3c4e395bf361c49183 # v0.11.0
# https://hub.docker.com/r/aquasec/trivy/tags
TRIVY_IMAGE = aquasec/trivy@sha256:cffe3f5161a47a6823fbd23d985795b3ed72a4c806da4c4df16266c02accdd6f # v0.72.0
# https://hub.docker.com/r/semgrep/semgrep/tags, keep in step with test-sast.yml
SEMGREP_IMAGE = semgrep/semgrep@sha256:3e6e5065d9e68abffddffdb536a8db2d79a8fa92dc424daa48d3a4b7d9bc65d0 # v1.111.0
# https://hub.docker.com/r/zricethezav/gitleaks/tags
GITLEAKS_IMAGE = zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f # v8.30.1
# https://hub.docker.com/r/trufflesecurity/trufflehog/tags
TRUFFLEHOG_IMAGE = trufflesecurity/trufflehog@sha256:aa821cf4ace8861c7d096d83818cdf7bb9719028a52d37a52eaad44086a52577 # v3.96.0

# Any file whose first line is a shell shebang, whatever its extension. Catching these by
# shebang rather than by name is what covers extensionless hooks such as hooks/command.
SHELL_FILES = $(shell find . -path ./.git -prune -o -type f -print \
  | while read -r f; do \
      head -n 1 "$$f" 2>/dev/null | grep -qE '^\#!.*sh([[:space:]]|$$)' && echo "$$f"; \
    done | sort -u)

# *.sh with no shebang: fragments meant to be sourced, embedded or run as `sh file`.
# shellcheck refuses to guess a dialect for these (SC2148), so they are checked separately
# with --shell=sh. They cannot simply be handed to the pass above: --shell overrides a
# shebang rather than filling in for a missing one, which would check every bash script
# as POSIX sh.
SHELL_FRAGMENTS = $(shell find . -path ./.git -prune -o -type f -name '*.sh' -print \
  | while read -r f; do \
      head -n 1 "$$f" 2>/dev/null | grep -qE '^\#!' || echo "$$f"; \
    done | sort -u)

test: test-lint test-sast

# There is nothing to autoformat in a config-only repo; lint is the same as test-lint.
lint: test-lint

test-lint: test-lint-actionlint test-lint-yamllint test-lint-shellcheck

# actionlint resolves workflows from the repository root, so it needs a git repository.
# It also runs shellcheck over every `run:` block it finds.
test-lint-actionlint:
	$(DOCKER_RUN) $(ACTIONLINT_IMAGE) -color

# --strict promotes yamllint warnings to failures; .yamllint.yml turns off the two rules
# that pipeline YAML cannot satisfy.
test-lint-yamllint:
	$(DOCKER_RUN) $(YAMLLINT_IMAGE) yamllint --strict -c .yamllint.yml .

# Two passes: scripts are checked as the shell their shebang declares, fragments as sh.
# shellcheck exits non-zero when handed no files, so a repo with no shell is not a failure.
test-lint-shellcheck:
	if [ -n "$(SHELL_FILES)" ]; then \
	  $(DOCKER_RUN) $(SHELLCHECK_IMAGE) shellcheck --color=always $(SHELL_FILES); \
	fi
	if [ -n "$(SHELL_FRAGMENTS)" ]; then \
	  $(DOCKER_RUN) $(SHELLCHECK_IMAGE) shellcheck --shell=sh --color=always $(SHELL_FRAGMENTS); \
	fi
	@test -n "$(SHELL_FILES)$(SHELL_FRAGMENTS)" || echo 'shellcheck: no shell files'

# Local mirror of test-sast.yml. CI runs the pinned actions; these targets run the same
# tools from pinned images so a finding can be reproduced without pushing a branch.
# Two CI jobs have no target here: zizmor publishes no container image, and trufflehog is
# opt-in below because --only-verified sends secret candidates to third-party APIs.
test-sast: test-sast-trivy test-sast-trivy-license test-sast-semgrep test-sast-gitleaks

test-sast-trivy:
	$(DOCKER_RUN) $(TRIVY_IMAGE) fs --scanners vuln --ignore-unfixed --exit-code 1 .

test-sast-trivy-license:
	$(DOCKER_RUN) $(TRIVY_IMAGE) fs --scanners license --exit-code 0 .

test-sast-semgrep:
	$(DOCKER_RUN) $(SEMGREP_IMAGE) semgrep scan --config=auto --error .

test-sast-gitleaks:
	$(DOCKER_RUN) $(GITLEAKS_IMAGE) dir --no-banner /repo

# Not part of test-sast: verification posts candidate secrets to the services that issued
# them. Run it deliberately.
test-sast-trufflehog:
	$(DOCKER_RUN) $(TRUFFLEHOG_IMAGE) filesystem /repo --only-verified --results=verified,unknown --fail
