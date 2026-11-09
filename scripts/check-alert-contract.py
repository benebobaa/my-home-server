#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml==6.0.2"]
# ///
"""Check the alert annotation contract (ADR 0036, decision 5).

    check-alert-contract.py                      check the real rules
    check-alert-contract.py --rules-dir DIR      ... a copy of them (negative tests)
                            --alerts-md FILE
                            --dashboards-dir DIR

Every `- alert:` rule in the rules directory must carry:

  * the annotations summary, description, runbook_url and dashboard_url, none
    of them blank, and a non-blank `severity` label (the Watchdog's is `none`;
    a Go-template value that computes it counts);
  * a runbook_url of the form
    https://github.com/benebobaa/my-home-server/blob/main/docs/runbooks/alerts.md#<anchor>
    where <anchor> is a heading of alerts.md (GitHub's anchor algorithm);
  * a dashboard_url of the form http://10.10.10.16:3000/d/<uid>, optionally
    followed by one `?viewPanel=<n>` or `?var-<name>=<value>`, where <uid> is
    the uid of a generated board JSON under the dashboards directory;
  * a name no other rule uses.

Prints one OK line and exits 0, or one `file: rule: problem` line per
violation and exits 1. Recording rules (`record:`) are not alerts and are
skipped. Requires PyYAML only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES = ROOT / "services/monitoring/prometheus/rules"
DEFAULT_ALERTS_MD = ROOT / "docs/runbooks/alerts.md"
DEFAULT_DASHBOARDS = ROOT / "services/monitoring/grafana/dashboards"

REQUIRED_ANNOTATIONS = ("summary", "description", "runbook_url", "dashboard_url")

RUNBOOK_BASE = "https://github.com/benebobaa/my-home-server/blob/main/docs/runbooks/alerts.md"
RUNBOOK_RE = re.compile(re.escape(RUNBOOK_BASE) + r"#(?P<anchor>.+)")

# One optional query parameter, never two: an `&` in an href must be
# `&amp;` for Telegram's HTML parse mode, and nothing needs two.
DASHBOARD_RE = re.compile(
    r"http://10\.10\.10\.16:3000/d/(?P<uid>[A-Za-z0-9_-]+)"
    r"(?:\?(?:viewPanel=\d+|var-[\w.-]+=[^&#\s]+))?"
)


def github_anchors(markdown: str) -> set[str]:
    """The anchors GitHub gives the headings of a Markdown document.

    GitHub lowercases the heading text, drops everything except letters,
    digits, `_`, `-` and spaces, turns each space into `-`, and suffixes a
    repeated anchor with `-1`, `-2`. Lines inside a fenced code block are not
    headings (alerts.md has shell comments starting with `#` in one).
    """
    anchors: set[str] = set()
    seen: Counter[str] = Counter()
    fence = None  # the fence string that opened the current code block
    for line in markdown.splitlines():
        stripped = line.lstrip()
        if fence is None and stripped.startswith(("```", "~~~")):
            fence = stripped[:3]
            continue
        if fence is not None:
            if stripped.startswith(fence):
                fence = None
            continue
        match = re.match(r"#{1,6}[ \t]+(?P<text>.+?)(?:[ \t]+#+)?[ \t]*$", line)
        if not match:
            continue
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", match["text"])  # [t](u) -> t
        slug = re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")
        n = seen[slug]
        seen[slug] += 1
        anchors.add(slug if n == 0 else f"{slug}-{n}")
    return anchors


def board_uids(dashboards_dir: Path) -> set[str]:
    """The uid of every board JSON below the dashboards directory."""
    uids: set[str] = set()
    for path in sorted(dashboards_dir.rglob("*.json")):
        try:
            uid = json.loads(path.read_text(encoding="utf-8")).get("uid")
        except (json.JSONDecodeError, AttributeError):
            continue  # not a board; the dashboard build and linter judge those
        if isinstance(uid, str) and uid:
            uids.add(uid)
    return uids


def alert_rules(rules_dir: Path) -> tuple[list[tuple[str, dict]], list[str]]:
    """Every (file name, rule dict) that is an alert, plus any load errors."""
    found: list[tuple[str, dict]] = []
    errors: list[str] = []
    for path in sorted(rules_dir.glob("*.yml")):
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            errors.append(f"{path.name}: not valid YAML: {exc}")
            continue
        for group in (doc or {}).get("groups") or []:
            for rule in group.get("rules") or []:
                if isinstance(rule, dict) and "alert" in rule:
                    found.append((path.name, rule))
    return found, errors


def blank(value: object) -> bool:
    return value is None or not str(value).strip()


def check_rule(rule: dict, anchors: set[str], uids: set[str]) -> list[str]:
    """The problems of one alert rule; an empty list means it is compliant."""
    problems: list[str] = []
    annotations = rule.get("annotations") or {}
    labels = rule.get("labels") or {}

    for key in REQUIRED_ANNOTATIONS:
        if key not in annotations:
            problems.append(f"annotation `{key}` is missing")
        elif blank(annotations[key]):
            problems.append(f"annotation `{key}` is blank")
    if blank(labels.get("severity")):
        problems.append("label `severity` is missing or blank")

    runbook = annotations.get("runbook_url")
    if not blank(runbook):
        match = RUNBOOK_RE.fullmatch(str(runbook).strip())
        if not match:
            problems.append(f"runbook_url `{runbook}` is not {RUNBOOK_BASE}#<anchor>")
        elif match["anchor"] not in anchors:
            problems.append(f"runbook_url anchor `#{match['anchor']}` is not a heading in alerts.md")

    dashboard = annotations.get("dashboard_url")
    if not blank(dashboard):
        match = DASHBOARD_RE.fullmatch(str(dashboard).strip())
        if not match:
            problems.append(
                f"dashboard_url `{dashboard}` is not http://10.10.10.16:3000/d/<uid>"
                " (optionally ?viewPanel=<n> or ?var-<name>=<value>)"
            )
        elif match["uid"] not in uids:
            problems.append(f"dashboard_url uid `{match['uid']}` is not the uid of a generated board")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check the alert annotation contract.")
    parser.add_argument("--rules-dir", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--alerts-md", type=Path, default=DEFAULT_ALERTS_MD)
    parser.add_argument("--dashboards-dir", type=Path, default=DEFAULT_DASHBOARDS)
    args = parser.parse_args(argv)

    for path, kind in ((args.rules_dir, "dir"), (args.dashboards_dir, "dir"), (args.alerts_md, "file")):
        if not (path.is_dir() if kind == "dir" else path.is_file()):
            print(f"alert-contract: {path} does not exist", file=sys.stderr)
            return 2

    anchors = github_anchors(args.alerts_md.read_text(encoding="utf-8"))
    uids = board_uids(args.dashboards_dir)
    rules, errors = alert_rules(args.rules_dir)

    first_seen: dict[str, str] = {}
    for filename, rule in rules:
        name = str(rule["alert"])
        if name in first_seen:
            errors.append(f"{filename}: {name}: name already used by a rule in {first_seen[name]}")
        else:
            first_seen[name] = filename
        errors.extend(f"{filename}: {name}: {p}" for p in check_rule(rule, anchors, uids))

    if not rules and not errors:
        errors.append(f"{args.rules_dir}: no alert rules found")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"alert-contract: FAILED, {len(errors)} problem(s)", file=sys.stderr)
        return 1
    print(f"alert-contract: {len(rules)} alert rules OK ({len(anchors)} runbook anchors, {len(uids)} boards)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
