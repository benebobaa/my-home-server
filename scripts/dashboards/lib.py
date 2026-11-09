"""Helpers for the generated Grafana boards (docs/standards/dashboards.md).

Standard library only. A board module in boards/ builds `Board` objects from
the panel helpers below; build.py renders them to classic (v1) JSON.

The helpers carry the standard: every panel gets a description and a unit,
rate windows use $__rate_interval, variables are checked against the
queries that use them. `Board.render()` raises LintError when a board
breaks a rule, so a bad board never reaches the repo.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

SCHEMA_VERSION = 39  # what the proven boards use; Grafana migrates up on load

PROM = {"type": "prometheus", "uid": "prometheus"}
VLOGS = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}
TEMPO = {"type": "tempo", "uid": "traces"}
ALERTMANAGER = {"type": "alertmanager", "uid": "alertmanager"}
DATASOURCE_UIDS = {d["uid"] for d in (PROM, VLOGS, TEMPO, ALERTMANAGER)}

# Grafana's own interpolation tokens: valid in a query without a variable.
BUILTIN_VARS = {
    "__rate_interval", "__interval", "__interval_ms", "__range", "__range_s",
    "__range_ms", "__from", "__to", "__name", "__org", "__user", "__dashboard",
    "timeFilter", "__timeFilter",
}

FOLDERS = (
    "", "Infrastructure", "Network", "Platform services", "Kubernetes",
    "Applications", "Observability",
)
# uid = homelab-<token>-<name> (the Overview is just homelab-overview)
FOLDER_TOKEN = {
    "": "", "Infrastructure": "infra", "Network": "net", "Platform services": "platform",
    "Kubernetes": "k8s", "Applications": "apps", "Observability": "obs",
}
METHODS = ("overview", "use", "red", "slo", "explore")

GRID = 24
MAX_PANELS = 30  # the standard says "about 25"

RUN_BOOK_BASE = "https://github.com/benebobaa/my-home-server/blob/main/docs/runbooks/alerts.md"


class LintError(Exception):
    pass


# --- thresholds, mappings ----------------------------------------------------

def steps(*pairs: tuple[str, float | None]) -> dict:
    """steps(("green", None), ("orange", 80), ("red", 90))"""
    return {
        "mode": "absolute",
        "steps": [{"color": c, "value": v} for c, v in pairs],
    }


OK = steps(("green", None))
UP_DOWN = steps(("red", None), ("green", 1))        # 0 = down, 1 = up
ZERO_GOOD = steps(("green", None), ("red", 1))      # any count above 0 is bad
ZERO_WARN = steps(("green", None), ("orange", 1))   # any count above 0 is a note

UP_DOWN_MAP = [{
    "type": "value",
    "options": {
        "0": {"text": "DOWN", "color": "red", "index": 0},
        "1": {"text": "UP", "color": "green", "index": 1},
    },
}]


def hi_bad(warn: float, crit: float) -> dict:
    """Green below warn, orange to crit, red above (utilisation, temperature)."""
    return steps(("green", None), ("orange", warn), ("red", crit))


def lo_bad(warn: float, crit: float) -> dict:
    """Red below crit, orange to warn, green above (free space, runway)."""
    return steps(("red", None), ("orange", crit), ("green", warn))


# --- panels --------------------------------------------------------------------

# A target is a query string, (query, legend), or (query, legend, extra fields).

@dataclass
class Panel:
    spec: dict
    w: int
    h: int
    empty_ok: bool = False      # an empty result is normal (alert counts, ...)
    lint_ok: tuple = ()          # named rules this panel opts out of, with a reason in the board source
    has_unit: bool = True


def _targets(ds: dict, targets: Any, *, instant: bool, fmt: str | None = None) -> list[dict]:
    if isinstance(targets, str):
        targets = [targets]
    out = []
    for i, t in enumerate(targets):
        extra: dict = {}
        if isinstance(t, str):
            expr, legend = t, ""
        elif len(t) == 2:
            expr, legend = t
        else:
            expr, legend, extra = t
        d = {
            "refId": chr(ord("A") + i),
            "datasource": ds,
            "expr": expr,
            "legendFormat": legend,
            "instant": instant,
            "range": not instant,
        }
        if fmt:
            d["format"] = fmt
        d.update(extra)
        out.append(d)
    return out


def _links(links) -> list[dict]:
    return [{"title": t, "url": u, "targetBlank": True} for t, u in (links or [])]


def stat(title: str, expr, *, desc: str, unit: str = "short",
         thresholds: dict = OK, mappings: list | None = None,
         legend: str = "", w: int = 4, h: int = 4, graph: bool = False,
         color_mode: str = "background", decimals: int | None = None,
         no_value: str = "n/a", calcs: str = "lastNotNull",
         empty_ok: bool = False, lint_ok: tuple = (), links=None,
         min: float | None = None, max: float | None = None) -> Panel:
    """One number, coloured by thresholds. `expr` is one query (or a list)."""
    targets = [(expr, legend)] if isinstance(expr, str) else expr
    defaults: dict[str, Any] = {
        "unit": unit,
        "color": {"mode": "thresholds"},
        "thresholds": thresholds,
        "mappings": mappings or [],
        "noValue": no_value,
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    if min is not None:
        defaults["min"] = min
    if max is not None:
        defaults["max"] = max
    spec = {
        "type": "stat", "title": title, "description": desc,
        "datasource": PROM,
        "targets": _targets(PROM, targets, instant=not graph),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "colorMode": color_mode,
            "graphMode": "area" if graph else "none",
            "textMode": "auto",
            "justifyMode": "auto",
            "orientation": "auto",
            "reduceOptions": {"calcs": [calcs], "values": False, "fields": ""},
        },
        "links": _links(links),
    }
    return Panel(spec, w, h, empty_ok, lint_ok)


def up_stat(title: str, expr, *, desc: str, w: int = 4, h: int = 4, **kw) -> Panel:
    """0/1 query shown as DOWN/UP."""
    return stat(title, expr, desc=desc, unit="none", thresholds=UP_DOWN,
                mappings=UP_DOWN_MAP, w=w, h=h, **kw)


def problem_stat(title: str, expr, *, desc: str, w: int = 4, h: int = 4,
                 warn_only: bool = False, **kw) -> Panel:
    """A count of things that should be zero: green at 0, red (or orange) above."""
    kw.setdefault("empty_ok", True)
    kw.setdefault("no_value", "0")
    return stat(title, expr, desc=desc, unit="short",
                thresholds=ZERO_WARN if warn_only else ZERO_GOOD, w=w, h=h, **kw)


def timeseries(title: str, targets, *, desc: str, unit: str, w: int = 12,
               h: int = 8, thresholds: dict | None = None,
               threshold_style: str = "off", stack: bool = False,
               min: float | None = 0, max: float | None = None,
               fill: int = 10, legend: str = "list",
               legend_calcs: Sequence[str] = (), overrides: list | None = None,
               span_nulls: bool = False, empty_ok: bool = False,
               lint_ok: tuple = (), links=None, decimals: int | None = None,
               tooltip_sort: str = "desc") -> Panel:
    """Lines over time. `threshold_style` "dashed" draws the thresholds."""
    defaults: dict[str, Any] = {
        "unit": unit,
        "color": {"mode": "palette-classic"},
        "custom": {
            "drawStyle": "line", "lineWidth": 1, "fillOpacity": fill,
            "gradientMode": "none", "showPoints": "never",
            "spanNulls": span_nulls, "axisSoftMin": 0 if min == 0 else None,
            "stacking": {"mode": "normal" if stack else "none", "group": "A"},
            "thresholdsStyle": {"mode": threshold_style},
        },
        "thresholds": thresholds or OK,
        "mappings": [],
    }
    defaults["custom"] = {k: v for k, v in defaults["custom"].items() if v is not None}
    if min is not None:
        defaults["min"] = min
    if max is not None:
        defaults["max"] = max
    if decimals is not None:
        defaults["decimals"] = decimals
    spec = {
        "type": "timeseries", "title": title, "description": desc,
        "datasource": PROM,
        "targets": _targets(PROM, targets, instant=False),
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": {
            "legend": {
                "showLegend": legend != "hidden",
                "displayMode": "table" if legend == "table" else "list",
                "placement": "bottom",
                "calcs": list(legend_calcs),
            },
            "tooltip": {"mode": "multi", "sort": tooltip_sort},
        },
        "links": _links(links),
    }
    return Panel(spec, w, h, empty_ok, lint_ok)


def state_timeline(title: str, targets, *, desc: str, w: int = 12, h: int = 8,
                   mappings: list | None = None, thresholds: dict = UP_DOWN,
                   empty_ok: bool = False, lint_ok: tuple = ()) -> Panel:
    """Up/down (or any discrete state) per series over time."""
    spec = {
        "type": "state-timeline", "title": title, "description": desc,
        "datasource": PROM,
        "targets": _targets(PROM, targets, instant=False),
        "fieldConfig": {
            "defaults": {
                "unit": "none",
                "color": {"mode": "thresholds"},
                "thresholds": thresholds,
                "mappings": mappings if mappings is not None else UP_DOWN_MAP,
                "custom": {"fillOpacity": 70, "lineWidth": 0},
            },
            "overrides": [],
        },
        "options": {
            "mergeValues": True, "showValue": "never", "alignValue": "center",
            "rowHeight": 0.8,
            "legend": {"showLegend": False},
            "tooltip": {"mode": "single"},
        },
    }
    return Panel(spec, w, h, empty_ok, lint_ok)


def bargauge(title: str, targets, *, desc: str, unit: str, w: int = 8,
             h: int = 8, thresholds: dict = OK, min: float = 0,
             max: float | None = None, empty_ok: bool = False,
             lint_ok: tuple = (), mode: str = "gradient") -> Panel:
    """Compare a handful of things at one moment (per node, per disk)."""
    defaults: dict[str, Any] = {
        "unit": unit, "min": min, "color": {"mode": "thresholds"},
        "thresholds": thresholds, "mappings": [],
    }
    if max is not None:
        defaults["max"] = max
    spec = {
        "type": "bargauge", "title": title, "description": desc,
        "datasource": PROM,
        "targets": _targets(PROM, targets, instant=True),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "displayMode": mode, "orientation": "horizontal",
            "showUnfilled": True, "valueMode": "color", "minVizHeight": 16,
            "reduceOptions": {"calcs": ["lastNotNull"], "values": False, "fields": ""},
        },
    }
    return Panel(spec, w, h, empty_ok, lint_ok)


def table(title: str, targets, *, desc: str, columns: Sequence[tuple[str, str]],
          w: int = 24, h: int = 8, unit: str = "short",
          sort_by: str | None = None, descending: bool = True,
          overrides: list | None = None, empty_ok: bool = False,
          lint_ok: tuple = (), links=None) -> Panel:
    """Instant-query table. `columns` = (field, heading) in display order."""
    fields = [c for c, _ in columns]
    transformations: list[dict] = []
    if not isinstance(targets, str) and len(targets) > 1:
        transformations.append({"id": "merge", "options": {}})
    transformations.append({"id": "filterFieldsByName",
                            "options": {"include": {"names": fields}}})
    transformations.append({"id": "organize", "options": {
        "renameByName": {f: h_ for f, h_ in columns},
        "indexByName": {f: i for i, f in enumerate(fields)},
    }})
    options: dict[str, Any] = {"showHeader": True, "cellHeight": "sm"}
    if sort_by:
        options["sortBy"] = [{"displayName": sort_by, "desc": descending}]
    spec = {
        "type": "table", "title": title, "description": desc,
        "datasource": PROM,
        "targets": _targets(PROM, targets, instant=True, fmt="table"),
        "fieldConfig": {"defaults": {"unit": unit, "custom": {"align": "auto"}},
                        "overrides": overrides or []},
        "options": options,
        "transformations": transformations,
        "links": _links(links),
    }
    return Panel(spec, w, h, empty_ok, lint_ok)


def logs(title: str, expr: str, *, desc: str, w: int = 24, h: int = 12,
         max_lines: int = 200) -> Panel:
    """VictoriaLogs (LogsQL). Not verified by --verify-live."""
    spec = {
        "type": "logs", "title": title, "description": desc,
        "datasource": VLOGS,
        "targets": [{"refId": "A", "datasource": VLOGS, "queryType": "instant",
                     "maxLines": max_lines, "expr": expr}],
        "options": {"showTime": True, "wrapLogMessage": True,
                    "sortOrder": "Descending", "enableLogDetails": True},
    }
    return Panel(spec, w, h, True, (), has_unit=False)


def text(title: str, markdown: str, *, w: int = 24, h: int = 4) -> Panel:
    spec = {
        "type": "text", "title": title, "description": "Reading guide.",
        "options": {"mode": "markdown", "content": markdown},
    }
    return Panel(spec, w, h, True, (), has_unit=False)


# --- variables -----------------------------------------------------------------

def var_query(name: str, label: str, query: str, *, multi: bool = False,
              include_all: bool = False, regex: str = "", sort: int = 1) -> dict:
    """A query variable on the Prometheus data source. Use `=~"$name"` in queries:
    it works for a single value and for a multi-value selection alike."""
    v: dict[str, Any] = {
        "name": name, "label": label, "type": "query", "datasource": PROM,
        "query": {"query": query, "refId": "v"}, "definition": query,
        "refresh": 2, "sort": sort, "regex": regex,
        "includeAll": include_all, "multi": multi,
    }
    if include_all:
        v["allValue"] = ".*"
        v["current"] = {"selected": True, "text": "All", "value": "$__all"}
    return v


# --- boards --------------------------------------------------------------------

@dataclass
class _Row:
    title: str
    panels: list[Panel]
    collapsed: bool


@dataclass
class Board:
    """One generated dashboard. `folder` must be in FOLDERS ("" = Overview, root)."""
    uid: str
    title: str
    folder: str
    description: str
    method: str
    filename: str
    variables: list[dict] = field(default_factory=list)
    time_from: str = "now-6h"
    refresh: str = "1m"
    alerts_annotation: bool = True
    extra_tags: tuple = ()
    rows: list[_Row] = field(default_factory=list)

    def row(self, title: str, panels: Iterable[Panel], collapsed: bool = False) -> "Board":
        self.rows.append(_Row(title, list(panels), collapsed))
        return self

    # path under the dashboards directory
    @property
    def path(self) -> str:
        return f"{self.folder}/{self.filename}.json" if self.folder else f"{self.filename}.json"

    def all_panels(self) -> list[Panel]:
        return [p for r in self.rows for p in r.panels]

    # -- layout and render --------------------------------------------------
    def render(self) -> dict:
        self._lint()
        pid = 0
        y = 0
        panels_out: list[dict] = []
        for row in self.rows:
            pid += 1
            row_spec: dict[str, Any] = {
                "id": pid, "type": "row", "title": row.title,
                "collapsed": row.collapsed,
                "gridPos": {"x": 0, "y": y, "w": GRID, "h": 1},
                "panels": [],
            }
            y += 1
            placed: list[dict] = []
            x = 0
            line_h = 0
            for p in row.panels:
                if x + p.w > GRID:
                    y += line_h
                    x, line_h = 0, 0
                pid += 1
                spec = dict(p.spec)
                spec["id"] = pid
                spec["gridPos"] = {"x": x, "y": y, "w": p.w, "h": p.h}
                placed.append(spec)
                x += p.w
                line_h = max(line_h, p.h)
            y += line_h
            if row.collapsed:
                row_spec["panels"] = placed
                panels_out.append(row_spec)
            else:
                panels_out.append(row_spec)
                panels_out.extend(placed)
        tags = ["homelab", self.folder.lower().replace(" ", "-") or "overview",
                self.method, *self.extra_tags]
        board: dict[str, Any] = {
            "uid": self.uid, "title": self.title, "description": self.description,
            "tags": list(dict.fromkeys(tags)),
            "editable": False, "graphTooltip": 1, "timezone": "browser",
            "schemaVersion": SCHEMA_VERSION, "refresh": self.refresh,
            "time": {"from": self.time_from, "to": "now"},
            "fiscalYearStartMonth": 0, "liveNow": False, "weekStart": "",
            "links": [{
                "type": "dashboards", "title": "Homelab boards", "tags": ["homelab"],
                "asDropdown": True, "includeVars": False, "keepTime": True,
                "icon": "external link",
            }],
            "annotations": {"list": self._annotations()},
            "templating": {"list": self.variables},
            "panels": panels_out,
        }
        return board

    def _annotations(self) -> list[dict]:
        out = [{
            "builtIn": 1, "type": "dashboard", "name": "Annotations & Alerts",
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
        }]
        if self.alerts_annotation:
            out.append({
                "name": "Firing alerts", "datasource": PROM, "enable": True,
                "iconColor": "red", "step": "60s",
                "expr": 'ALERTS{alertstate="firing", severity=~"critical|warning"}',
                "titleFormat": "{{alertname}}", "textFormat": "{{instance}} {{severity}}",
            })
        return out

    # -- the standard, as checks ------------------------------------------------
    def _lint(self) -> None:
        errs: list[str] = []
        b = self.title
        if self.folder not in FOLDERS:
            errs.append(f"{b}: folder {self.folder!r} not in {FOLDERS}")
        else:
            prefix = "homelab-" + (FOLDER_TOKEN[self.folder] + "-" if self.folder else "")
            if not re.fullmatch(re.escape(prefix) + r"[a-z0-9]+(-[a-z0-9]+)*", self.uid):
                errs.append(f"{b}: uid {self.uid!r} must start with {prefix!r} and use a-z0-9 and dashes")
        if self.method not in METHODS:
            errs.append(f"{b}: method {self.method!r} not in {METHODS}")
        if len(self.description.strip()) < 30:
            errs.append(f"{b}: description must say what question the board answers")
        panels = self.all_panels()
        if not panels:
            errs.append(f"{b}: no panels")
        if len(panels) > MAX_PANELS:
            errs.append(f"{b}: {len(panels)} panels, the standard allows about 25 (max {MAX_PANELS})")
        defined = {v["name"] for v in self.variables}
        titles: set[str] = set()
        for p in panels:
            s = p.spec
            t = s.get("title", "")
            where = f"{b} / {t!r}"
            if not t:
                errs.append(f"{b}: a panel has no title")
            if t in titles:
                errs.append(f"{where}: duplicate panel title")
            titles.add(t)
            if (s.get("type") != "text" and "description" not in p.lint_ok
                    and len(s.get("description", "").strip()) < 20):
                errs.append(f"{where}: description missing or too short")
            if p.has_unit and "unit" not in s.get("fieldConfig", {}).get("defaults", {}):
                errs.append(f"{where}: no unit")
            ds = s.get("datasource")
            if ds and ds.get("uid") not in DATASOURCE_UIDS:
                errs.append(f"{where}: unknown datasource uid {ds.get('uid')!r}")
            for tgt in s.get("targets", []):
                expr = tgt.get("expr", "")
                if "rate-literal" not in p.lint_ok and re.search(
                        r"\b(rate|irate)\(\s*[^()]*\[\d+[smhdw]\]", expr):
                    errs.append(f"{where}: literal rate window, use $__rate_interval: {expr[:80]}")
                for var in re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", expr):
                    if var not in defined and var not in BUILTIN_VARS:
                        errs.append(f"{where}: undefined variable ${var}")
        for v in self.variables:
            q = v.get("definition", "")
            for var in re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", q):
                if var not in defined and var not in BUILTIN_VARS:
                    errs.append(f"{b}: variable {v['name']} uses undefined ${var}")
        if errs:
            raise LintError("\n".join(errs))


def board(uid: str, title: str, folder: str, description: str, method: str,
          filename: str, **kw) -> Board:
    return Board(uid, title, folder, description, method, filename, **kw)
