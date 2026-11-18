# GoNinja quality targets (included from Makefile)
.PHONY: quality-setup quality-lint quality-scan quality-hooks-update

quality-setup:        ## One-time developer setup
	pip install -r requirements-dev.txt
	pre-commit install --install-hooks
	@echo "GoNinja hooks installed."

quality-lint:
	ruff check . --fix && ruff format .

quality-scan:         ## Every local check on the whole repo
	pre-commit run --all-files --hook-stage pre-commit
	pre-commit run --all-files --hook-stage pre-push

quality-hooks-update: ## Monthly: bump pinned hook versions
	pre-commit autoupdate
