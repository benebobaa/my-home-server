#!/usr/bin/env bash
# Pin Kubeletto's own images in the home overlay to digests. A tag can be
# re-pushed to different content; a digest cannot, so the cluster runs exactly
# the image CI built (operating model D21). Edits infra/k8s/home/kustomization.yaml
# in KUBELETTO_REPO (default: the kubeletto-home checkout); it never touches
# the cluster. Apply with ./apply.sh after reviewing ./apply.sh diff.
#
#   ./pin.sh running                 # pin what the cluster runs now (read-only on the cluster)
#   ./pin.sh set core|admin <sha8> <sha256:...>
#                                    # pin a new build: the digest is in the run summary
#                                    # of the "images" workflow (record the digest step)
#   ./pin.sh show                    # the overlay's current tag and digest per image
#
# `running` refuses when the cluster's tag differs from the overlay's newTag,
# or when two versions run at once (a rollout in progress): pin only what you
# mean to pin.
set -euo pipefail
cd "$(dirname "$0")"

KUBELETTO_REPO=${KUBELETTO_REPO:-$HOME/Documents/benelabs/kubeletto-home}
KUST="$KUBELETTO_REPO/infra/k8s/home/kustomization.yaml"
NODE=root@10.10.10.12   # pve2 (inventory/lab.yaml: k3s on pve2)
VMID=300
[ -f "$KUST" ] || { echo "no overlay at $KUST" >&2; exit 2; }

# key -> kustomize image name (the `name:` in images:) and registry repository
kust_name() { case "$1" in core) echo kubeletto/platform-core ;; admin) echo kubeletto/admin-ui ;; *) return 1 ;; esac; }
repo_of()   { case "$1" in core) echo ghcr.io/podpilott/kubeletto-core ;; admin) echo ghcr.io/podpilott/kubeletto-admin-ui ;; *) return 1 ;; esac; }

# Rewrite newTag and digest for one image block, in place. Python edits the
# text (not YAML round-trip) so comments and layout survive.
write_pin() { # key tag digest
  python3 - "$KUST" "$(kust_name "$1")" "$2" "$3" <<'PY'
import re, sys
path, name, tag, digest = sys.argv[1:5]
lines = open(path).read().split("\n")
out, i, done = [], 0, False
while i < len(lines):
    line = lines[i]
    out.append(line)
    if re.match(r"^\s*-\s+name:\s+" + re.escape(name) + r"\s*$", line):
        # copy this block's keys until the next list item or a dedented line
        i += 1
        saw_tag = False
        while i < len(lines) and re.match(r"^\s{4}\S", lines[i]) and not lines[i].lstrip().startswith("- "):
            cur = lines[i]
            if cur.strip().startswith("digest:"):
                i += 1
                continue            # dropped; re-added after newTag
            if cur.strip().startswith("newTag:"):
                comment = re.search(r"\s+#.*$", cur)
                # Always quoted: a commit sha of only digits (30378122) is a
                # YAML number, and kustomize refuses a numeric newTag.
                out.append('    newTag: "%s"%s' % (tag, comment.group(0) if comment else ""))
                out.append("    digest: %s" % digest)
                saw_tag = True
            else:
                out.append(cur)
            i += 1
        if not saw_tag:
            sys.exit("image %s has no newTag line to pin" % name)
        done = True
        continue
    i += 1
if not done:
    sys.exit("no image %s in %s" % (name, path))
open(path, "w").write("\n".join(out))
PY
}

current() { # key -> "tag digest-or-none" from the overlay
  python3 - "$KUST" "$(kust_name "$1")" <<'PY'
import re, sys
path, name = sys.argv[1:3]
lines = open(path).read().split("\n")
tag, digest, inblock = "?", "none", False
for line in lines:
    if re.match(r"^\s*-\s+name:\s+" + re.escape(name) + r"\s*$", line):
        inblock = True
        continue
    if inblock:
        if re.match(r"^\s*-\s", line) or not line.startswith("    "):
            break
        m = re.match(r"^\s+newTag:\s+(\S+)", line)
        if m: tag = m.group(1).strip('"\'')
        m = re.match(r"^\s+digest:\s+(\S+)", line)
        if m: digest = m.group(1)
print(tag, digest)
PY
}

vm_bash() { # script on stdin
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 120 -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
}

valid() { # tag digest
  [[ $1 =~ ^[0-9a-f]{8}$ ]] || { echo "tag must be an 8-char commit sha, got: $1" >&2; return 1; }
  [[ $2 =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "digest must be sha256:<64 hex>, got: $2" >&2; return 1; }
}

cmd_show() {
  local k
  for k in core admin; do printf '%-6s %s\n' "$k" "$(current "$k")"; done
}

cmd_set() {
  local key=${1:-} tag=${2:-} digest=${3:-}
  [ -n "$key" ] && [ -n "$tag" ] && [ -n "$digest" ] || { echo "usage: pin.sh set core|admin <sha8> <sha256:digest>" >&2; exit 2; }
  kust_name "$key" >/dev/null || { echo "unknown image: $key (core|admin)" >&2; exit 2; }
  valid "$tag" "$digest"
  write_pin "$key" "$tag" "$digest"
  echo "pinned $key: $tag@$digest"
}

cmd_running() {
  local pairs key repo found tag digest cur_tag
  pairs=$(vm_bash <<'EOF'
k3s kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.image} {.imageID}{"\n"}{end}{end}'
EOF
  )
  for key in core admin; do
    repo=$(repo_of "$key")
    # Only containers of this repository; tag from .image, digest from .imageID.
    found=$(printf '%s\n' "$pairs" | awk -v r="$repo" 'index($1, r ":") == 1 || index($1, r "@") == 1 { print $1, $2 }' | sort -u)
    if [ -z "$found" ]; then echo "$key: not running on the cluster, skipped" >&2; continue; fi
    if [ "$(printf '%s\n' "$found" | wc -l)" -ne 1 ]; then
      echo "$key: more than one version is running (rollout in progress?), refusing:" >&2
      printf '  %s\n' "$found" >&2
      exit 1
    fi
    read -r image imageid <<<"$found"
    tag=${image##*:}; tag=${tag%%@*}
    digest=${imageid##*@}
    valid "$tag" "$digest"
    read -r cur_tag _ <<<"$(current "$key")"
    if [ "$tag" != "$cur_tag" ]; then
      echo "$key: the cluster runs tag $tag but the overlay says $cur_tag; refusing to pin a version the repo does not name" >&2
      exit 1
    fi
    write_pin "$key" "$tag" "$digest"
    echo "pinned $key: $tag@$digest (what the cluster runs)"
  done
}

case "${1:-}" in
  running) cmd_running ;;
  set) shift; cmd_set "$@" ;;
  show) cmd_show ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
