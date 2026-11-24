"""
AI-assisted help desk ticket triage.

Reads a batch of tickets, then for each one:
  * assigns a category (Account/Access, Network, Hardware, Printer, Email, Software, Security)
  * assigns a priority (P1-P4) based on impact and urgency signals
  * finds the most relevant knowledge-base article
  * drafts a first reply for the technician to review

Two modes:
  rules (default)  offline, deterministic keyword scoring - no API key needed
  ai               sends each ticket + the KB to Claude and gets structured JSON back;
                   falls back to rules mode for any ticket the API call fails on

Usage:
  python triage.py sample_data/tickets.csv
  python triage.py sample_data/tickets.csv --mode ai --out results
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

CATEGORIES: dict[str, list[str]] = {
    "Security": [
        "phishing", "suspicious", "hacked", "compromised", "virus", "malware",
        "ransomware", "scam", "gift card", "clicked a link", "mfa prompt", "unknown login",
    ],
    "Account/Access": [
        "password", "locked out", "locked", "login", "log in", "sign in", "mfa",
        "authenticator", "access", "permission", "reset", "account", "new hire", "onboard",
    ],
    "Network": [
        "wifi", "wi-fi", "internet", "network", "vpn", "connection", "disconnect",
        "slow", "ethernet", "dns", "no connection", "offline",
    ],
    "Printer": ["printer", "print", "printing", "toner", "paper jam", "scanner", "scan"],
    "Email": ["email", "outlook", "inbox", "mailbox", "calendar", "teams meeting", "shared mailbox"],
    "Hardware": [
        "laptop", "monitor", "keyboard", "mouse", "dock", "screen", "battery",
        "won't turn on", "broken", "headset", "tablet", "barcode", "charger",
    ],
    "Software": [
        "install", "application", "app", "software", "update", "crash", "error",
        "excel", "word", "license", "erp", "freezes",
    ],
}

# Words that raise impact (how many people) and urgency (how badly work is blocked).
HIGH_IMPACT = ["everyone", "whole team", "entire", "all users", "nobody", "whole floor",
               "production line", "line is down", "plant", "department"]
HIGH_URGENCY = ["down", "outage", "can't work", "cannot work", "urgent", "asap", "emergency",
                "stopped", "not working", "deadline", "customer"]
LOW_URGENCY = ["when you get a chance", "no rush", "not urgent", "request", "would like",
               "nice to have", "question"]

STOPWORDS = set("""a an and are as at be but by can cant for from has have i im in is it its
my me of on or our so that the this to was we were with you your not no do does
dont get got just when what how please hi hello thanks thank need help""".split())


@dataclass
class KBArticle:
    id: str
    title: str
    body: str
    tokens: Counter = field(default_factory=Counter, repr=False)


@dataclass
class TriageResult:
    ticket_id: str
    requester: str
    subject: str
    category: str
    priority: str
    kb_article: str
    suggested_reply: str
    reasoning: str
    mode: str


# ---------------------------------------------------------------- loading

def load_tickets(path: Path) -> list[dict]:
    if path.suffix.lower() == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    with path.open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def tokenize(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9']+", text.lower()) if w not in STOPWORDS and len(w) > 2]


def load_kb(folder: Path) -> list[KBArticle]:
    articles = []
    for md in sorted(folder.glob("*.md")):
        text = md.read_text(encoding="utf-8")
        first_line = text.splitlines()[0] if text else md.stem
        title = first_line.lstrip("# ").strip()
        articles.append(KBArticle(id=md.stem, title=title, body=text, tokens=Counter(tokenize(text))))
    return articles


# ---------------------------------------------------------------- rules engine

def _count_hits(text: str, phrases: list[str]) -> int:
    return sum(1 for p in phrases if re.search(r"\b" + re.escape(p) + r"\b", text))


def classify(text: str) -> tuple[str, dict[str, int]]:
    text = text.lower()
    scores = {cat: _count_hits(text, words) for cat, words in CATEGORIES.items()}
    # Security always wins if there's any real signal - a phishing report that
    # mentions a password should go to security, not to a password reset queue.
    if scores["Security"] >= 1:
        return "Security", scores
    best = max(scores, key=scores.get)
    return (best if scores[best] > 0 else "General"), scores


def prioritize(text: str, category: str) -> tuple[str, str]:
    text = text.lower()
    impact = _count_hits(text, HIGH_IMPACT)
    urgency = _count_hits(text, HIGH_URGENCY)
    low = _count_hits(text, LOW_URGENCY)

    if category == "Security":
        return "P1", "security reports are always handled immediately"
    if impact and urgency:
        return "P1", "multiple users affected and work is blocked"
    if impact or urgency >= 2:
        return "P2", "broad impact or a hard work stoppage"
    if urgency:
        return "P3", "single user, work partially blocked"
    if low:
        return "P4", "request / low urgency language"
    return "P3", "single user, standard issue"


def best_kb_match(text: str, kb: list[KBArticle]) -> KBArticle | None:
    """Cosine similarity over word counts - simple, explainable, no dependencies."""
    query = Counter(tokenize(text))
    if not query or not kb:
        return None

    def cosine(a: Counter, b: Counter) -> float:
        dot = sum(a[t] * b[t] for t in a if t in b)
        norm = math.sqrt(sum(v * v for v in a.values())) * math.sqrt(sum(v * v for v in b.values()))
        return dot / norm if norm else 0.0

    scored = sorted(((cosine(query, a.tokens), a) for a in kb), key=lambda x: x[0], reverse=True)
    score, article = scored[0]
    return article if score >= 0.15 else None


def first_name(requester: str) -> str:
    name = requester.split("@")[0].replace(".", " ").split()[0] if requester else "there"
    return name.capitalize()


REPLY_TEMPLATES = {
    "Security": ("Thanks for reporting this right away. Please don't click any links, open attachments, "
                 "or reply to the message. I'm looking into it now and will follow up shortly. If you "
                 "already entered your password anywhere, let me know immediately so I can reset it."),
    "Account/Access": "Thanks for reaching out. I'm looking into your account access now.",
    "Network": "Thanks for letting me know. I'm checking the network side of this now.",
    "Printer": "Thanks for the heads up. I'm taking a look at the printer issue.",
    "Email": "Thanks for reaching out. I'm looking into the email issue now.",
    "Hardware": "Thanks for reporting this. I'll take a look at the equipment.",
    "Software": "Thanks for reaching out. I'm looking into the application issue.",
    "General": "Thanks for reaching out. I've received your request and I'm looking into it.",
}


def draft_reply(ticket: dict, category: str, priority: str, article: KBArticle | None) -> str:
    lines = [f"Hi {first_name(ticket.get('requester', ''))},", "", REPLY_TEMPLATES.get(category, REPLY_TEMPLATES["General"])]
    if article and category != "Security":
        lines += ["", f'In the meantime, these steps fix this most of the time: "{article.title}" (KB: {article.id}).']
    if priority in ("P1", "P2"):
        lines += ["", "I've marked this as high priority and will update you within the hour."]
    lines += ["", "Thanks,", "IT Support"]
    return "\n".join(lines)


def triage_rules(ticket: dict, kb: list[KBArticle]) -> TriageResult:
    text = f"{ticket.get('subject', '')} {ticket.get('description', '')}"
    category, scores = classify(text)
    priority, why = prioritize(text, category)
    article = best_kb_match(text, kb)
    top = ", ".join(f"{c}={s}" for c, s in sorted(scores.items(), key=lambda x: -x[1]) if s)
    return TriageResult(
        ticket_id=str(ticket.get("id", "")),
        requester=ticket.get("requester", ""),
        subject=ticket.get("subject", ""),
        category=category,
        priority=priority,
        kb_article=article.id if article else "",
        suggested_reply=draft_reply(ticket, category, priority, article),
        reasoning=f"{why}; keyword scores: {top or 'none'}",
        mode="rules",
    )


# ---------------------------------------------------------------- AI mode

AI_SYSTEM_PROMPT = """You are a senior IT help desk technician triaging incoming tickets.
Categories: {categories}
Priorities:
  P1 = security incident, or many users fully blocked
  P2 = many users degraded, or one user fully blocked on time-critical work
  P3 = one user with a standard issue
  P4 = request, question, or no-rush item
Pick the single most relevant knowledge base article id from the list below, or "" if none fit.
Write a short, friendly first reply to the user (sign off as "IT Support"). Never ask for their password.

Knowledge base:
{kb}

Respond with ONLY a JSON object with keys: category, priority, kb_article, suggested_reply, reasoning."""


def triage_ai(ticket: dict, kb: list[KBArticle], client, model: str) -> TriageResult:
    kb_text = "\n\n".join(f"[{a.id}]\n{a.body[:1500]}" for a in kb)
    system = AI_SYSTEM_PROMPT.format(categories=", ".join(list(CATEGORIES) + ["General"]), kb=kb_text)
    user_msg = (f"Ticket ID: {ticket.get('id')}\nFrom: {ticket.get('requester')}\n"
                f"Subject: {ticket.get('subject')}\n\n{ticket.get('description')}")

    response = client.messages.create(
        model=model,
        max_tokens=800,
        system=system,
        messages=[{"role": "user", "content": user_msg}],
    )
    raw = "".join(block.text for block in response.content if block.type == "text")
    match = re.search(r"\{.*\}", raw, re.DOTALL)
    if not match:
        raise ValueError(f"model did not return JSON: {raw[:200]}")
    data = json.loads(match.group(0))

    valid_ids = {a.id for a in kb}
    return TriageResult(
        ticket_id=str(ticket.get("id", "")),
        requester=ticket.get("requester", ""),
        subject=ticket.get("subject", ""),
        category=data.get("category", "General"),
        priority=data.get("priority", "P3"),
        kb_article=data.get("kb_article", "") if data.get("kb_article") in valid_ids else "",
        suggested_reply=data.get("suggested_reply", ""),
        reasoning=data.get("reasoning", ""),
        mode="ai",
    )


# ---------------------------------------------------------------- output

PRIORITY_ORDER = {"P1": 0, "P2": 1, "P3": 2, "P4": 3}


def write_outputs(results: list[TriageResult], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    results = sorted(results, key=lambda r: (PRIORITY_ORDER.get(r.priority, 9), r.ticket_id))

    csv_path = out_dir / "triage_results.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(asdict(results[0]).keys()))
        writer.writeheader()
        writer.writerows(asdict(r) for r in results)

    md_path = out_dir / "triage_summary.md"
    by_pri = Counter(r.priority for r in results)
    by_cat = Counter(r.category for r in results)
    lines = ["# Ticket Triage Summary", "",
             f"**{len(results)} tickets** - " + ", ".join(f"{p}: {by_pri[p]}" for p in sorted(by_pri)), "",
             "| Category | Count |", "|---|---|"]
    lines += [f"| {c} | {n} |" for c, n in by_cat.most_common()]
    lines += ["", "## Queue (highest priority first)", "",
              "| ID | Priority | Category | Subject | KB |", "|---|---|---|---|---|"]
    lines += [f"| {r.ticket_id} | {r.priority} | {r.category} | {r.subject} | {r.kb_article or '-'} |" for r in results]
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return csv_path, md_path


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).parent
    parser = argparse.ArgumentParser(description="Triage help desk tickets.")
    parser.add_argument("tickets", type=Path, help="CSV or JSON file of tickets (id, requester, subject, description)")
    parser.add_argument("--kb", type=Path, default=here / "kb", help="folder of markdown KB articles")
    parser.add_argument("--out", type=Path, default=here / "output", help="output folder")
    parser.add_argument("--mode", choices=["rules", "ai"], default="rules")
    parser.add_argument("--model", default=os.environ.get("TRIAGE_MODEL", "claude-haiku-5-5"))
    args = parser.parse_args(argv)

    tickets = load_tickets(args.tickets)
    kb = load_kb(args.kb)
    if not tickets:
        print("No tickets found.", file=sys.stderr)
        return 1

    client = None
    if args.mode == "ai":
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("ANTHROPIC_API_KEY is not set - use --mode rules or set the key.", file=sys.stderr)
            return 1
        import anthropic  # only needed for AI mode
        client = anthropic.Anthropic()

    results = []
    for t in tickets:
        if client:
            try:
                results.append(triage_ai(t, kb, client, args.model))
                continue
            except Exception as exc:  # network error, bad JSON, etc. - never drop a ticket
                print(f"[warn] AI triage failed for ticket {t.get('id')}: {exc}; using rules", file=sys.stderr)
        results.append(triage_rules(t, kb))

    csv_path, md_path = write_outputs(results, args.out)
    for r in sorted(results, key=lambda r: PRIORITY_ORDER.get(r.priority, 9)):
        print(f"{r.priority}  {r.category:<15} #{r.ticket_id:<5} {r.subject}")
    print(f"\nWrote {csv_path} and {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
