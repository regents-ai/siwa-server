.DEFAULT_GOAL := help
.PHONY: help check
help:
	@echo "Run make check for every gate before a commit; it is mix precommit."
	@echo "Release with scripts/deploy.sh once the commit is on origin/main (README.md, Deployment)."
# mix precommit compiles with warnings as errors, checks unused locks, formatting,
# Credo, Sobelow, the usage rules, the served services contract, the agent
# clients and the compile-connected xref graph, installs the e2e libraries (the
# Node client's first-request test uses them), runs the tests with warnings as
# errors, then walks the Touch ID page in headless Chromium (e2e/).
check:
	mix precommit
