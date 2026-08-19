# Developer task runner. These run on a workstation or CI, never on the router.
LINT_FILES := scripts/*.sh tests/*.sh pc/*.sh config/settings.sh agent/install-agent.sh agent/cgi/sbproxy agent/sbproxy-healthd

.PHONY: help lint test docs docs-check check version

help:
	@echo "make lint        # shellcheck the shell scripts"
	@echo "make test        # run all POSIX, desktop, Agent, and healthd tests"
	@echo "make docs        # regenerate docs/*.html from docs/*.md"
	@echo "make docs-check  # fail if docs/*.html are out of date"
	@echo "make check       # lint + test + docs-check (what CI runs)"
	@echo "make version     # print the project version"

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck chưa cài"; exit 1; }
	shellcheck -S warning $(LINT_FILES)

test:
	sh tests/run-all.sh

docs:
	node tools/build-docs.js

docs-check: docs
	@git diff --quiet -- docs/ || { echo "docs/*.html chưa build lại — chạy 'make docs' rồi commit"; exit 1; }

check: lint test docs-check

version:
	@cat VERSION
