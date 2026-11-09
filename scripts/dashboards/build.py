#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Generate, check or live-verify the Grafana boards.

    build.py                  write services/monitoring/grafana/dashboards/**.json
    build.py --check          fail if the committed JSON differs from the generator
    build.py --verify-live    run every Prometheus query against the lab and list
                              errors and unexpected empty results (default URL below)
    build.py --list           board uid, path and panel count

The boards are Python in boards/*.py (each module defines boards() ->
list[Board]); the rules they follow are docs/standards/dashboards.md and are
enforced by lib.Board.render(). Standard library only.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lib  # noqa: E402

ROOT = HERE.parents[1]
OUT = ROOT / "services/monitoring/grafana/dashboards"
PROM_URL = "http://10.10.10.16:9090"


def load_boards(modules: list[str] | None = None) -> list[lib.Board]:
    """All boards, or only those of the named boards/<module>.py files."""
    boards: list[lib.Board] = []
    for f in sorted((HERE / "boards").glob("*.py")):
        if f.name.startswith("_") or (modules and f.stem not in modules):
            continue
        spec = importlib.util.spec_from_file_location(f"boards_{f.stem}", f)
        if spec is None or spec.loader is None:
            raise lib.LintError(f"cannot load {f}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        boards.extend(mod.boards())
    uids = [b.uid for b in boards]
    paths = [b.path for b in boards]
    for kind, seq in (("uid", uids), ("path", paths)):
        dup = {x for x in seq if seq.count(x) > 1}
        if dup:
            raise lib.LintError(f"duplicate board {kind}: {sorted(dup)}")
    return boards


def render_all(boards: list[lib.Board]) -> dict[str, str]:
    errors = []
    out: dict[str, str] = {}
    for b in boards:
        try:
            out[b.path] = json.dumps(b.render(), indent=2, ensure_ascii=False) + "\n"
        except lib.LintError as e:
            errors.append(str(e))
    if errors:
        raise lib.LintError("\n".join(errors))
    return out


def on_disk() -> set[str]:
    return {str(p.relative_to(OUT)) for p in OUT.rglob("*.json")} if OUT.exists() else set()


def cmd_write(boards: list[lib.Board], partial: bool = False) -> int:
    rendered = render_all(boards)
    for rel, text in rendered.items():
        p = OUT / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists() or p.read_text() != text:
            p.write_text(text)
            print(f"wrote   {rel}")
    for rel in sorted(set() if partial else on_disk() - set(rendered)):
        (OUT / rel).unlink()
        print(f"removed {rel}")
    for d in sorted((p for p in OUT.rglob("*") if p.is_dir()), reverse=True):
        if not any(d.iterdir()):
            d.rmdir()
    print(f"{len(rendered)} boards")
    return 0


def cmd_check(boards: list[lib.Board], partial: bool = False) -> int:
    rendered = render_all(boards)
    bad = []
    for rel, text in rendered.items():
        p = OUT / rel
        if not p.exists():
            bad.append(f"missing  {rel}")
        elif p.read_text() != text:
            bad.append(f"differs  {rel}")
    # with --module only some boards are loaded: the rest is not stale
    for rel in sorted(set() if partial else on_disk() - set(rendered)):
        bad.append(f"stale    {rel} (no generator produces it)")
    if bad:
        print("dashboards: committed JSON does not match the generator:\n  "
              + "\n  ".join(bad) + "\nrun: scripts/dashboards/build.py", file=sys.stderr)
        return 1
    print(f"dashboards: {len(rendered)} boards OK")
    return 0


def cmd_list(boards: list[lib.Board]) -> int:
    for b in boards:
        print(f"{b.uid:34} {b.path:46} {len(b.all_panels()):3} panels")
    return 0


# --- live verification ----------------------------------------------------------

BUILTIN_SUBST = {
    "__rate_interval": "5m", "__interval": "1m", "__range": "6h",
    "__range_s": "21600", "__range_ms": "21600000", "__interval_ms": "60000",
}


def prom_get(url: str, path: str, params: dict | None = None, post: bool = False) -> dict:
    """GET by default: /api/v1/label/<name>/values accepts nothing else (405).
    Queries pass post=True so a long expression is not limited by URL length."""
    qs = urllib.parse.urlencode(params or {}, doseq=True)
    if post:
        req = urllib.request.Request(f"{url}{path}", data=qs.encode())
    else:
        req = urllib.request.Request(f"{url}{path}" + (f"?{qs}" if qs else ""))
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def variable_values(url: str, var: dict) -> list[str]:
    q = var.get("definition", "")
    m = re.fullmatch(r"label_values\((.*),\s*([A-Za-z_][A-Za-z0-9_]*)\)", q.strip())
    try:
        if m:
            sel, label = m.groups()
            res = prom_get(url, f"/api/v1/label/{label}/values", {"match[]": sel})
        else:
            m = re.fullmatch(r"label_values\(([A-Za-z_][A-Za-z0-9_]*)\)", q.strip())
            if not m:
                return []
            res = prom_get(url, f"/api/v1/label/{m.group(1)}/values")
    except (urllib.error.URLError, OSError):
        return []
    vals = res.get("data", [])
    rx = var.get("regex")
    if rx:
        vals = [v for v in vals if re.search(rx.strip("/"), v)]
    return vals


def substitute(expr: str, variables: dict[str, list[str]]) -> str:
    for name, vals in variables.items():
        if not vals:
            continue
        joined = "|".join(vals)
        # =~"$name" takes every value; anything else takes the first
        expr = re.sub(r'=~\s*"(\$\{?%s\}?)"' % re.escape(name), f'=~"{joined}"', expr)
        expr = re.sub(r"\$\{?%s\}?" % re.escape(name), vals[0], expr)
    for k, v in BUILTIN_SUBST.items():
        expr = re.sub(r"\$\{?%s\}?" % k, v, expr)
    return expr


def cmd_verify(boards: list[lib.Board], url: str, only: str | None, strict: bool,
               verbose: bool = False) -> int:
    errors = empties = ok = skipped = 0
    for b in boards:
        if only and b.uid != only:
            continue
        variables = {v["name"]: variable_values(url, v) for v in b.variables}
        for name, vals in variables.items():
            if not vals:
                print(f"  note  {b.uid}: variable ${name} resolved no values")
        for p in b.all_panels():
            for t in p.spec.get("targets", []):
                if t.get("datasource", {}).get("uid") != "prometheus":
                    skipped += 1
                    continue
                expr = substitute(t["expr"], variables)
                try:
                    res = prom_get(url, "/api/v1/query", {"query": expr}, post=True)
                except urllib.error.HTTPError as e:
                    body = e.read().decode(errors="replace")[:200]
                    errors += 1
                    print(f"ERROR  {b.uid} / {p.spec['title']} [{t['refId']}]: HTTP {e.code} {body}\n         {expr[:140]}")
                    continue
                except (urllib.error.URLError, OSError) as e:
                    print(f"cannot reach {url}: {e}", file=sys.stderr)
                    return 2
                result = res.get("data", {}).get("result", [])
                vals = []
                for r in result:
                    v = r.get("value", [None, "NaN"])[1] if "value" in r else "range"
                    vals.append(v)
                if not result or all(v == "NaN" for v in vals):
                    if p.empty_ok:
                        ok += 1
                    else:
                        empties += 1
                        print(f"EMPTY  {b.uid} / {p.spec['title']} [{t['refId']}]\n         {expr[:140]}")
                else:
                    ok += 1
                    if verbose:
                        shown = ", ".join(
                            f"{','.join(f'{k}={v}' for k, v in r['metric'].items() if k not in ('__name__', 'job'))[:40] or 'value'}"
                            f"={float(r['value'][1]):.4g}" for r in result[:3] if "value" in r)
                        print(f"  ok  {b.uid} / {p.spec['title']} [{t['refId']}] "
                              f"{len(result)} series: {shown}")
    print(f"verify-live: {ok} ok, {empties} unexpected empty, {errors} errors, "
          f"{skipped} non-Prometheus queries skipped")
    if errors or (strict and empties):
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--list", action="store_true")
    g.add_argument("--verify-live", nargs="?", const=PROM_URL, metavar="URL")
    ap.add_argument("--board", help="with --verify-live: one board uid")
    ap.add_argument("--module", action="append", metavar="NAME",
                    help="only boards/NAME.py (repeatable); write mode then never removes other files")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="with --verify-live: print the first values of every query")
    ap.add_argument("--strict", action="store_true",
                    help="with --verify-live: unexpected empty results fail too")
    a = ap.parse_args()
    try:
        boards = load_boards(a.module)
        render_all(boards)  # lint everything first, whatever the mode
    except lib.LintError as e:
        print(f"dashboards: standard violated:\n{e}", file=sys.stderr)
        return 1
    if a.check:
        return cmd_check(boards, partial=bool(a.module))
    if a.list:
        return cmd_list(boards)
    if a.verify_live:
        return cmd_verify(boards, a.verify_live, a.board, a.strict, a.verbose)
    return cmd_write(boards, partial=bool(a.module))


if __name__ == "__main__":
    sys.exit(main())
