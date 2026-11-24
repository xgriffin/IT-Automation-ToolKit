# IT Automation Toolkit

Practical automation for the repetitive parts of IT support and systems administration: user lifecycle, ticket triage, and endpoint health. Each project is self-contained, with its own README.

| Project | Language | What it automates |
|---|---|---|
| [**Entra ID User Lifecycle**](./entra-user-lifecycle) | PowerShell + Microsoft Graph | Bulk onboarding from CSV (accounts, groups, licenses, manager) and offboarding (block sign-in, revoke sessions, remove access, with an access snapshot so it can be undone) |
| [**AI-Assisted Ticket Triage**](./ai-ticket-triage) | Python + Claude API | Categorizes and prioritizes help desk tickets, matches knowledge-base articles, and drafts first replies. Has an offline rules mode and an AI mode. |
| [**Endpoint Health Report**](./endpoint-health-report) | PowerShell | Checks Windows PCs for low disk space, pending reboots, Defender and BitLocker status, and patch age, then builds a color-coded HTML report |

## Principles behind these tools
- **Safe to run.** Changes support `-WhatIf` dry runs, destructive actions ask for confirmation, and offboarding saves a snapshot first.
- **Logged.** Every run leaves an audit trail.
- **Handles failure per item.** One bad row, unreachable PC or failed API call doesn't stop the batch.
- **Keeps a human in the loop.** AI drafts are suggestions for a technician to review, never sent automatically.

## About
Built by Griffin, an IT support specialist working toward systems administration and security. These tools come from problems I run into supporting office, warehouse and manufacturing environments: onboarding new hires, keeping shop-floor PCs healthy, and getting urgent tickets to the top of the queue.

AI-assisted development (Claude Code) was used while building these projects.
