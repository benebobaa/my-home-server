#!/usr/bin/env python3
"""Regenerate manifests/ from Kubeletto's LIVE production cluster (read-only).

The Kubeletto repo is not a faithful copy of production (see
docs/runbooks/kubeletto-migration.md), so the home cluster is built from what
prod actually runs: every object below is read with `kubectl get -o json` over
SSH, stripped of cluster-specific fields, and given the home changes:

  - placement: every platform workload gets the control-plane nodeSelector and
    toleration (the server node `k3s` is tainted; only it passes the Postgres
    pinhole), tenants and builds land on the worker by the taint alone;
  - rehearsal safety switches on platform-core (runbook "Safety switches");
  - no Services pinned except the two ClusterIPs registries.yaml and core
    depend on; fresh PVCs; Traefik as ClusterIP (the tunnel is the only way in);
  - the internal-API NetworkPolicy widened from node 1's pod /24 to the /16.

Prod's rate limits (ipStrategy depth 1) stay: Traefik at home trusts
X-Forwarded-* only from the server node's pods (traefik-values.yaml), so the
right-most entry is the client IP Cloudflare added.

Secrets are NOT exported here: secrets.sh pipes them prod -> home.

  ./export-from-prod.py            # rewrites manifests/*.yaml
"""
import copy
import json
import pathlib
import subprocess
import sys

import yaml

PROD = "root@103.59.160.198"
HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "manifests"

PLATFORM_NAMESPACES = ["platform", "nats", "registry", "traefik"]
PINNED_CLUSTER_IPS = {("registry", "registry"), ("platform", "platform-core")}

PLACEMENT = {
    "nodeSelector": {"node-role.kubernetes.io/control-plane": "true"},
    "tolerations": [{"key": "node-role.kubernetes.io/control-plane",
                     "operator": "Exists", "effect": "NoSchedule"}],
}

# Rehearsal: api mode (no background loops), nothing that mails, charges,
# reaps, samples into OpenObserve or burns Let's Encrypt prod limits.
# Explicit env wins over envFrom, so these override platform-core-env.
CORE_ENV_OVERRIDES = {
    "KUBELETTO_RUN_MODE": "api",
    "IDLE_APP_REAP_ENABLED": "false",
    "CRASH_LOOP_SUSPEND_ENABLED": "false",
    "EGRESS_AUTOSUSPEND_ENABLED": "false",
    "OTEL_ENABLED": "false",
    "DOMAINS_ISSUER": "letsencrypt-http01-staging",
}
CORE_ENV_DROP = {"OPENOBSERVE_URL"}

# (namespace or None for cluster-scoped, kind, name)
OBJECTS = [
    *[(None, "namespace", ns) for ns in PLATFORM_NAMESPACES],
    (None, "priorityclass", "kubeletto-platform-critical"),
    (None, "clusterrole", "platform-core-runtime-reconciler"),
    (None, "clusterrolebinding", "platform-core-runtime-reconciler"),
    ("platform", "serviceaccount", "platform-core"),
    ("platform", "deployment", "platform-core"),
    ("platform", "service", "platform-core"),
    ("platform", "networkpolicy", "platform-core-internal-api"),
    ("nats", "configmap", "nats-config"),
    ("nats", "persistentvolumeclaim", "nats-data"),
    ("nats", "deployment", "nats"),
    ("nats", "service", "nats"),
    ("registry", "configmap", "registry-config"),
    ("registry", "configmap", "dockerhub-mirror-config"),
    ("registry", "persistentvolumeclaim", "dockerhub-mirror-cache"),
    ("registry", "deployment", "registry"),
    ("registry", "deployment", "dockerhub-mirror"),
    ("registry", "service", "registry"),
    ("registry", "service", "dockerhub-mirror"),
    ("traefik", "role", "platform-core-domains"),
    ("traefik", "rolebinding", "platform-core-domains"),
    ("traefik", "middleware.traefik.io", "platform-team-auth"),
    ("traefik", "middleware.traefik.io", "ratelimit-api"),
    ("traefik", "middleware.traefik.io", "ratelimit-user-apps"),
    ("traefik", "tlsoption.traefik.io", "default"),
    ("traefik", "tlsstore.traefik.io", "default"),
    ("traefik", "ingressroute.traefik.io", "api"),
    ("traefik", "ingressroute.traefik.io", "user-apps"),
]
KNATIVE_CONFIGMAPS = ["config-autoscaler", "config-defaults", "config-deployment",
                      "config-domain", "config-features", "config-gc",
                      "config-kourier", "config-network"]

DROP_META = {"uid", "resourceVersion", "creationTimestamp", "generation",
             "managedFields", "selfLink", "ownerReferences"}
DROP_ANNOTATIONS_PREFIX = ("kubectl.kubernetes.io/last-applied-configuration",
                           "deployment.kubernetes.io/", "pv.kubernetes.io/",
                           "volume.beta.kubernetes.io/", "volume.kubernetes.io/",
                           "meta.helm.sh/")


def kget(ns, kind, name):
    nsarg = f"-n {ns} " if ns else ""
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", PROD, f"kubectl get {nsarg}{kind} {name} -o json"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def clean(obj):
    obj.pop("status", None)
    meta = obj["metadata"]
    for k in DROP_META:
        meta.pop(k, None)
    ann = {k: v for k, v in (meta.get("annotations") or {}).items()
           if not k.startswith(DROP_ANNOTATIONS_PREFIX)}
    if ann:
        meta["annotations"] = ann
    else:
        meta.pop("annotations", None)
    labels = meta.get("labels") or {}
    labels["app.kubernetes.io/managed-by"] = "homeserver-repo"
    meta["labels"] = labels
    return obj


def home(obj):
    kind, meta = obj["kind"], obj["metadata"]
    ns, name = meta.get("namespace"), meta["name"]

    if kind == "Namespace":
        obj.pop("spec", None)
        (meta.get("labels") or {}).pop("kubernetes.io/metadata.name", None)

    if kind == "Service":
        spec = obj["spec"]
        if (ns, name) not in PINNED_CLUSTER_IPS:
            spec.pop("clusterIP", None)
            spec.pop("clusterIPs", None)
        for k in ("healthCheckNodePort", "ipFamilies", "ipFamilyPolicy",
                  "internalTrafficPolicy", "sessionAffinity"):
            spec.pop(k, None)
        for p in spec.get("ports", []):
            p.pop("nodePort", None)

    if kind == "PersistentVolumeClaim":
        spec = obj["spec"]
        obj["spec"] = {k: spec[k] for k in ("accessModes", "resources", "storageClassName")
                       if k in spec}
        if name == "dockerhub-mirror-cache":
            obj["spec"]["resources"] = {"requests": {"storage": "10Gi"}}  # 40 GB VM disk

    if kind == "Deployment" and ns in PLATFORM_NAMESPACES:
        tmpl = obj["spec"]["template"]
        (tmpl["metadata"].get("annotations") or {}).pop("kubectl.kubernetes.io/restartedAt", None)
        if not tmpl["metadata"].get("annotations"):
            tmpl["metadata"].pop("annotations", None)
        pod = tmpl["spec"]
        pod["nodeSelector"] = dict(PLACEMENT["nodeSelector"])
        pod["tolerations"] = copy.deepcopy(PLACEMENT["tolerations"])
        obj["spec"].pop("progressDeadlineSeconds", None)
        obj["spec"].pop("revisionHistoryLimit", None)

    if kind == "Deployment" and (ns, name) == ("platform", "platform-core"):
        c = obj["spec"]["template"]["spec"]["containers"][0]
        env = [e for e in c.get("env", [])
               if e["name"] not in CORE_ENV_DROP and e["name"] not in CORE_ENV_OVERRIDES]
        env += [{"name": k, "value": v} for k, v in CORE_ENV_OVERRIDES.items()]
        c["env"] = env
        # K3s's policy controller programs a new pod's rules a few seconds
        # after it starts; core dials Redis and NATS once at startup (the
        # live-logs NATS connection never retries), so wait for both first.
        pod = obj["spec"]["template"]["spec"]
        pod["initContainers"] = [{
            "name": "wait-for-deps",
            "image": "docker.io/library/busybox:1.37",
            "command": ["sh", "-c",
                        "for i in $(seq 1 60); do nc -z -w 2 redis.platform.svc.cluster.local 6379"
                        " && nc -z -w 2 nats.nats.svc.cluster.local 4222 && exit 0; sleep 1; done;"
                        " echo 'redis/nats unreachable after 60 s' >&2; exit 1"],
            "resources": {"requests": {"cpu": "10m", "memory": "8Mi"}, "limits": {"memory": "16Mi"}},
            "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
        }]

    if kind == "NetworkPolicy" and name == "platform-core-internal-api":
        for rule in obj["spec"].get("ingress", []):
            for frm in rule.get("from", []):
                if frm.get("ipBlock", {}).get("cidr") == "10.42.0.0/24":
                    frm["ipBlock"]["cidr"] = "10.42.0.0/16"

    return obj


class IndentedDumper(yaml.SafeDumper):
    """Indent sequences under their key, as yamllint (repo config) expects."""

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def dump(path, objs, header):
    with open(path, "w") as f:
        f.write(header)
        yaml.dump_all(objs, f, Dumper=IndentedDumper, sort_keys=False,
                      default_flow_style=False, width=120)


def main():
    OUT.mkdir(exist_ok=True)
    header = ("# GENERATED by services/kubeletto/export-from-prod.py from Kubeletto's live\n"
              "# production cluster, with the home changes it documents. Edit the script,\n"
              "# not this file, then re-run it.\n")
    objs = [home(clean(kget(*o))) for o in OBJECTS]
    dump(OUT / "platform.yaml", objs, header)

    cms = []
    for name in KNATIVE_CONFIGMAPS:
        cm = clean(kget("knative-serving", "configmap", name))
        cm["data"] = {k: v for k, v in (cm.get("data") or {}).items() if k != "_example"}
        cms.append(cm)
    dump(OUT / "knative-config.yaml", cms, header)
    print(f"wrote {len(objs)} platform objects, {len(cms)} Knative ConfigMaps")


if __name__ == "__main__":
    sys.exit(main())
