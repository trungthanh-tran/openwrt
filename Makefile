# Developer task runner. These run on a workstation or CI, never on the router.
LINT_FILES := scripts/*.sh tests/*.sh pc/*.sh console/desktop/*.sh console/deployer/*.sh config/settings.sh agent/install-agent.sh agent/cgi/sbproxy agent/sbproxy-healthd agent/sbproxy-webauth

.PHONY: help lint test check version package package-linux

help:
	@echo "make lint        # shellcheck the shell scripts"
	@echo "make test        # run all POSIX, desktop, Agent, and healthd tests"
	@echo "make check       # lint + test (what CI runs)"
	@echo "make version     # print the project version"
	@echo "make package     # build dist/sbproxy-update-<version>.tar.gz for UI upload"
	@echo "make package-linux # build portable Linux deploy bundle in dist/release"

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck chưa cài"; exit 1; }
	shellcheck -S warning $(LINT_FILES)

test:
	sh tests/run-all.sh

check: lint test

version:
	@cat VERSION

package:
	sh pc/make-package.sh

package-linux:
	sh console/deployer/package-linux.sh
