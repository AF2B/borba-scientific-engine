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
