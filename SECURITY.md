# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| `main`  | Yes       |
| `develop` | Yes (pre-release) |
| All others | No     |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Use one of the following private channels:

1. **GitHub Security Advisories (GHSA):** Navigate to *Security → Advisories → New draft advisory* in this repository and submit a private advisory. This is the preferred channel.
2. **Email:** Send details to `security@example.com` (replace with the real address before going public). Encrypt with our PGP key if the content is sensitive.

Include as much detail as possible:
- Description of the vulnerability and its potential impact.
- Steps to reproduce or a proof-of-concept (PoC).
- Affected versions / environments.
- Any suggested mitigations.

## Response timeline

| Milestone | Target |
|-----------|--------|
| Initial acknowledgement | Within 48 hours |
| Severity assessment & triage | Within 5 business days |
| Fix for **critical** issues | Within 7 days of triage |
| Fix for **high** issues | Within 30 days of triage |
| Fix for **medium / low** | Scheduled in next regular release |

We will keep you informed of progress throughout the process.

## Coordinated disclosure

We follow a coordinated disclosure model. Once a fix is ready and deployed, we will:

1. Publish a GitHub Security Advisory (GHSA) with full details.
2. Credit the reporter (unless they prefer anonymity).
3. Tag a new patch release that includes the fix.

We ask that you allow us a reasonable time to fix and release before any public disclosure.
