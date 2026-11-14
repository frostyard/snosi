# The make gate (frostyard/core ADR-0043, ADR-0044, ADR-0071 row B4).
# Image builds stay in the Justfile (`just --list`); they need root and run in
# GitHub Actions. These targets are credential-free and need no root.
#
#   make verify  the baseline gate: the template gate (agent symlinks, docs
#                index, risk-path list, corrections, vendored core copies),
#                its Node tests, and the repository policy tests. It does not
#                change the checkout.
#   make check   the developer gate; the same as verify.
#   make ci      verify, plus the corrections records check against BASE
#                when BASE is set (CI passes the pull request base commit).
#
# validate.yml still runs the full static suite (shellcheck and the fixture
# tests). docs/design/testing.md describes both.
NODE_MAJOR := $(shell node -p "process.versions.node.split('.')[0]" 2>/dev/null)

.PHONY: verify check ci

verify:
	@if ! command -v node >/dev/null 2>&1; then echo "FAIL: make verify requires Node.js 22 or later (mise install)"; exit 1; fi
	@if [ "$(NODE_MAJOR)" = "" ] || [ "$(NODE_MAJOR)" -lt 22 ]; then echo "FAIL: make verify requires Node.js 22 or later (found: $$(node --version 2>/dev/null || echo missing))"; exit 1; fi
	@if ! command -v python3 >/dev/null 2>&1; then echo "FAIL: make verify requires python3"; exit 1; fi
	node scripts/check-template.mjs
	node --test test/*.test.mjs
	python3 ./test/policy-as-code-test.py
	python3 ./test/risk-paths-test.py
	python3 ./test/build-workflow-permissions-test.py
	python3 ./test/workflow-pins-test.py
	python3 ./test/forky-publish-workflow-test.py

check: verify

ci: verify
	@if [ -n "$(BASE)" ]; then node scripts/check-corrections.mjs --base "$(BASE)"; fi
