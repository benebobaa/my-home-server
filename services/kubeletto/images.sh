#!/usr/bin/env bash
# Make every external tenant image available on the home worker before the
# restore (a cutover step; run after `./restore.sh list`).
#
# 30 of 52 tenant services run images from ghcr.io or Docker Hub, not from the
# platform's registry. Prod resolved each to a digest and keeps running it from
# its node's cache even when the upstream has since gone private or been
# deleted: pulling from home then fails (403) and the app would be down after
# the cutover for no fault of the migration. For each digest in the restore list
# (`ns name image@sha256:...`, registry.kubeletto.com ones excluded: they come
# from the platform's own registry):
#
#   1. already on the worker                    -> nothing to do
#   2. `crictl pull` on the worker succeeds     -> done (and warm)
#   3. else prod's containerd holds it          -> export there, stream in
#                                                  verified chunks, import here
#                                                  (only when the layers are still
#                                                  there: K3s discards them once
#                                                  unpacked, then it is not possible)
#   4. else                                     -> reported UNAVAILABLE: broken on
#                                                  prod too, or running there from
#                                                  a snapshot only (its owner must
#                                                  redeploy after the cutover)
#
#   ./images.sh            do all of the above
#   ./images.sh check      only report (no pull, no copy)
#
# The restore then runs with the same digests (restore.sh list captures them),
# so the Knative controller skips re-resolving a tag it can no longer reach.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

PROD=${KUBELETTO_PROD_SSH:-root@103.59.160.198}
PVE3=root@10.10.10.13      # hosts the worker VM
WORKER=301
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/kubeletto-restore
LIST=$CACHE/ksvc.txt
MODE=${1:-apply}
[[ $MODE =~ ^(apply|check)$ ]] || { echo "usage: $0 [check]" >&2; exit 2; }
[ -s "$LIST" ] || { echo "no list at $LIST (run: ./restore.sh list)" >&2; exit 2; }
CHUNK=${KUBELETTO_IMAGE_CHUNK:-520000}   # bytes per guest-agent call (stdin cap 1 MiB once base64'd)

worker() { # worker <script on stdin>: run a script in the worker VM, print its stdout
  ssh -o BatchMode=yes "$PVE3" "qm guest exec $WORKER --pass-stdin 1 --timeout ${1:-300} -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.exit(d.get("exitcode",1))'
}

on_worker() { # on_worker <ref>: present | pulled | failed
  local ref=$1
  # shellcheck disable=SC2016 # the printf template is a script for the VM
  printf 'REF=%q\nif k3s crictl inspecti "$REF" >/dev/null 2>&1; then echo present; elif [ "%s" = apply ] && timeout 240 k3s crictl pull "$REF" >/dev/null 2>&1; then echo pulled; else echo failed; fi\n' "$ref" "$MODE" | worker 300 || echo failed
}

copy_from_prod() { # copy_from_prod <ref>
  local ref=$1 tmp want got n=0 total
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$PROD" "k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF '$ref'" || return 2
  ssh -n -o BatchMode=yes "$PROD" "k3s ctr -n k8s.io images export --platform linux/amd64 - '$ref' 2>/dev/null" > "$tmp/img.tar"
  [ -s "$tmp/img.tar" ] || return 3
  # K3s's containerd discards an image's layer blobs once unpacked: the image
  # RUNS from the snapshot but cannot be exported (found 2026-10-14: a 17 MiB
  # image exported as 1536 bytes, the index alone). Nothing real to copy.
  if [ "$(wc -c < "$tmp/img.tar" | tr -d ' ')" -lt 65536 ]; then
    echo "    prod holds it only as a running snapshot: the layer blobs are gone, it cannot be exported" >&2; return 5
  fi
  want=$(shasum -a 256 "$tmp/img.tar" | cut -d' ' -f1); total=$(wc -c < "$tmp/img.tar" | tr -d ' ')
  worker 60 <<< 'rm -rf /var/tmp/imgcopy && install -d -m 700 /var/tmp/imgcopy' >/dev/null
  split -b "$CHUNK" "$tmp/img.tar" "$tmp/part."
  for f in "$tmp"/part.*; do
    { printf 'base64 -d >> /var/tmp/imgcopy/img.tar <<"B64"\n'; base64 < "$f"; printf 'B64\n'; } | worker 120 >/dev/null
    n=$((n+1))
  done
  got=$(worker 120 <<< 'sha256sum /var/tmp/imgcopy/img.tar | cut -d" " -f1')
  [ "$got" = "$want" ] || { echo "checksum mismatch after $n chunks" >&2; return 4; }
  worker 300 <<< 'k3s ctr -n k8s.io images import --platform linux/amd64 /var/tmp/imgcopy/img.tar >/dev/null; rm -rf /var/tmp/imgcopy' >/dev/null
  [ "$(worker 60 <<< "k3s crictl inspecti '$ref' >/dev/null 2>&1 && echo ok")" = ok ] || { echo "    imported but not usable on the worker" >&2; return 6; }
  printf '    copied %s bytes in %s chunks, sha256 verified, present on the worker\n' "$total" "$n" >&2
}

refs=$(awk 'NF==3 && $3 !~ /^registry\.kubeletto\.com\// {print $3}' "$LIST" | sort -u)
echo "external images in the list: $(echo "$refs" | grep -c .) (of $(wc -l < "$LIST" | tr -d ' ') services)" >&2
present=0; pulled=0; copied=0; missing=()
# A for-loop over an array, not `while read`: every ssh below would swallow the
# loop's stdin and silently end it after a few images (found 2026-10-14).
refs_arr=()
while IFS= read -r line; do refs_arr+=("$line"); done <<< "$refs"   # bash 3.2 (macOS): no mapfile
for ref in "${refs_arr[@]}"; do
  [ -n "$ref" ] || continue
  case "$(on_worker "$ref")" in
    present) present=$((present+1)) ;;
    pulled) pulled=$((pulled+1)); echo "  pulled   $ref" >&2 ;;
    *)
      if [ "$MODE" = check ]; then missing+=("$ref"); echo "  MISSING on the worker: $ref" >&2; continue; fi
      echo "  cannot pull, trying prod's cache: $ref" >&2
      if copy_from_prod "$ref"; then copied=$((copied+1)); else missing+=("$ref"); echo "  UNAVAILABLE everywhere: $ref" >&2; fi ;;
  esac
done
echo "== present $present, pulled $pulled, copied from prod $copied, unavailable ${#missing[@]}" >&2
[ ${#missing[@]} -eq 0 ] || exit 1
