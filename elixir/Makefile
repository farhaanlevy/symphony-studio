# Downstream modification notice (2026-07-14): Symphony Studio verifies its
# committed Codex schema contract as part of every full quality gate.
.PHONY: help all setup deps build fmt fmt-check lint schema test coverage ci dialyzer e2e

MIX ?= mix
PYTHON ?= python3

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, schema, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

schema:
	$(PYTHON) ../scripts/run_codex_schema_tests.py
	$(PYTHON) ../scripts/codex_schema.py verify-source-bound-prepublication
	$(PYTHON) ../scripts/codex_schema.py regenerate-check --codex codex

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format dialyzer

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs --exclude release_5_remote

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) schema
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
