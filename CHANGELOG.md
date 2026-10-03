# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository foundation: SwiftPM package, Vapor 4 application skeleton and the `borba-scientific-engine` executable.
- Typed, environment-driven configuration for `development`, `test`, `staging` and `production`, with aggregated
  validation errors and redacted secrets.
- `GET /health` liveness endpoint.
- Makefile with the day-to-day developer workflow.
- Multi-stage container image and a Docker Compose stack with PostgreSQL.
- Architecture decision record describing the layered architecture.
- Calculation core, free of web and database frameworks, with nine modules: arithmetic, percentage, statistics,
  financial, scientific, conversion, expression, numerical and linear algebra.
- Typed parameter declarations that validate input, produce documentation metadata and give typed access to values.
- Calculation engine with a cooperative time budget, cancellation and results that are values rather than exceptions.
- Calculation history model, repository port, domain events and the use cases that run calculations with
  idempotency keys, event publication and bounded-concurrency batches.
- Typed error model with stable codes and an expected, application, infrastructure or unexpected classification.
- Architecture decision records for the module structure and the error handling strategy, and a guide to adding a
  calculation module.
- Architecture tests that keep the domain free of framework imports.
- PostgreSQL persistence adapter with versioned SQL migrations, check constraints, foreign keys, indexes, atomic
  idempotency and keyset pagination.
- Integration tests against a real PostgreSQL, one temporary database per test, sharing a repository contract suite
  with the in-memory test double.
- Database health probe that reports unreachable databases and pending migrations.
- `make test-integration`, which starts PostgreSQL when needed.
- Architecture decision record for the PostgreSQL persistence strategy.
