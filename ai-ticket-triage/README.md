# AI-Assisted Ticket Triage

A Python tool that takes a batch of incoming help desk tickets and, for each one:

- **Categorizes it:** Security, Account/Access, Network, Hardware, Printer, Email, Software, or General
- **Assigns a priority** from P1 to P4, based on impact ("everyone", "production line") and urgency ("down", "can't work")
- **Finds the best knowledge-base article** for the issue
- **Drafts a first reply** for the technician to review and send

It outputs a CSV for importing into a ticketing system and a Markdown summary of the queue, sorted by priority.

## Why
On a busy help desk, a lot of time goes to reading each ticket, deciding where it goes, and typing the same first response again. Automating that first pass means P1s like a phishing click or a warehouse wifi outage rise to the top right away, and users get a useful self-help article instead of a generic "we got your ticket."

## Two modes

| Mode | How it works | Needs |
|---|---|---|
| `rules` (default) | Keyword scoring for category and priority, plus cosine similarity to match KB articles. Offline, free and explainable. | Nothing |
| `ai` | Sends each ticket and the KB to Claude, which returns structured JSON. Any ticket whose API call fails falls back to rules mode, so no ticket gets dropped. | `ANTHROPIC_API_KEY` |

Design choices worth noting:
- **Security always wins.** A phishing report that mentions "password" goes to Security as a P1, not to the password-reset queue.
- **AI output is validated.** If the model returns a KB article ID that doesn't exist, it's discarded.
- **A human stays in the loop.** Replies are drafts for a technician to review, and the prompt tells the model never to ask users for passwords.

## Quick start
```bash
pip install -r requirements.txt

# Offline rules mode
python triage.py sample_data/tickets.csv

# AI mode
export ANTHROPIC_API_KEY=sk-ant-...       # PowerShell: $env:ANTHROPIC_API_KEY="sk-ant-..."
python triage.py sample_data/tickets.csv --mode ai
```

Example output (rules mode, from the sample tickets):
```
P1  Security        #1002  Weird email asking for gift cards
P1  Network         #1003  Wifi down in the warehouse
P2  Network         #1007  VPN won't connect from home
P3  Account/Access  #1001  Locked out of my account
P3  Printer         #1004  Printer jammed again
P3  Email           #1005  Outlook keeps asking for password
P3  Hardware        #1009  Laptop won't turn on
P4  Hardware        #1006  Second monitor request
P4  Software        #1008  Need Excel installed
```

## Using your own data
- **Tickets:** a CSV or JSON file with `id`, `requester`, `subject` and `description` fields. Most ticketing systems can export this.
- **Knowledge base:** one Markdown file per article in `kb/`, with the title as the first `#` heading.
- **Options:** `--kb` (KB folder), `--out` (output folder), `--model` (or the `TRIAGE_MODEL` env var).

## Tests
```bash
python -m pytest -q
```
The tests cover classification, priority rules, KB matching, reply drafting, and AI-mode JSON parsing (using a fake client, so no API key is needed).

## Ideas for extending it
- Pull tickets straight from the Jira Service Management, Freshservice or Zendesk API instead of a CSV
- Post P1s to a Slack or Teams channel through a webhook
- Run it on a schedule with n8n or Task Scheduler
- Track triage accuracy against what technicians actually changed
