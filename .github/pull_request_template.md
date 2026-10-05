## What changes

<!-- The effect on the system, not the history of how it was reached. -->

## How it was verified

- [ ] `make ci` passes locally (format, lint, build, tests, security checks)
- [ ] New behaviour has tests; a fixed bug has a test that failed before the fix
- [ ] Public API changes are reflected in `Documentation/API/openapi.json` and `CHANGELOG.md`
- [ ] Anything that changes the architecture, a contract between components or a dependency has an ADR or updates one

## Risk

<!-- Migrations, new dependencies, configuration, anything that needs a particular order when it is deployed. -->
