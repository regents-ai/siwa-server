.DEFAULT_GOAL := help
.PHONY: help check
help:
	@echo "Run make check for every gate before a commit; it is mix precommit."
	@echo "Release with scripts/deploy.sh once the commit is on origin/main (README.md, Deployment)."
# mix precommit compiles with warnings as errors, checks unused locks, formatting,
# Credo, Sobelow, the usage rules, the served services contract, the agent
# clients and the compile-connected xref graph, then installs TypeScript and
# typechecks the site example's TypeScript declarations (typecheck/).
check:
	mix precommit
