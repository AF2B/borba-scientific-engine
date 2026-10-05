# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private vulnerability reporting instead:
**Security → Report a vulnerability** on the repository. Include what you found, how to reproduce it and what it lets an
attacker do.

You can expect an acknowledgement within a few days and a fix or a mitigation plan for confirmed problems before the details
are made public.

## Supported versions

Until 1.0, only the latest release and the default branch are supported.

## What is in scope

The service's source, its container image and its pipelines. The assumptions and the known gaps (no authentication, no rate
limiting, no retention policy) are documented in [`Documentation/Operations/security.md`](Documentation/Operations/security.md);
a report that restates one of them is welcome as a reason to prioritize it, but is not a vulnerability in itself.
