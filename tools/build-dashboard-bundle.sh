#!/usr/bin/env bash
# build-dashboard-bundle.sh — package + sign a lighthouse dashboard release.
#
# Produces exactly the three files `dashboard-sync.sh` fetches from any channel:
#
#   dist/dashboard.tar.gz    flat data files, no dirs, no symlinks, no code
#   dist/MANIFEST.json       {version, released, bundle, sha256, bytes}
#   dist/MANIFEST.json.sig   detached ssh signature over MANIFEST.json
#
# The signature is the trust root, not the transport — which is why the same
# three files can be served from gitea over the tailnet, from a public HTTPS
# mirror, or from an onion, and a device verifies them identically from any of
# them. The signing key NEVER leaves the release host and is never baked into an
# image; images carry the PUBLIC half in /etc/piranesi/dashboard/allowed_signers.
#
# Version is a monotonic integer. `dashboard-sync.sh` refuses anything not
# strictly greater than what it is already serving, so bumping it is mandatory
# for a release to be accepted anywhere.
#
# Usage:
#   build-dashboard-bundle.sh --src DIR --out DIR [--version N] [--key PATH]
#
# Exit: 0 ok / 2 usage / 3 missing tool / 4 build or signing failure
#
# Env: PORTAL_PY        outpost-portal.py to read the slot declaration from
#      SLOT_REMOVAL_OK  1 = a slot the last release carried may be dropped
#
# P10 RELAXATIONS:
#   R1 — `rm -rf` is confined to the staging dir this script mktemp -d's.
#
# Authored-by: CPCS
set -euo pipefail

readonly SIG_NAMESPACE="piranesi-lighthouse-dashboard"
readonly MAX_BUNDLE_BYTES=524288
readonly BUNDLE_FILES=(index.html.tmpl weather.html.tmpl dashboard.css glyphs.json bundle.json)

SRC=""; OUT=""; VERSION=""; KEY=""
# Global so the EXIT trap can still see it after main() returns; a `local` here
# is unbound by then and `set -u` turns cleanup into a spurious error.
STAGE_DIR=""

die() { printf 'build-dashboard-bundle: %s\n' "$1" >&2; exit "${2:-2}"; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --src)     [[ $# -ge 2 ]] || die "--src requires a value"; SRC="$2"; shift 2 ;;
      --out)     [[ $# -ge 2 ]] || die "--out requires a value"; OUT="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || die "--version requires a value"; VERSION="$2"; shift 2 ;;
      --key)     [[ $# -ge 2 ]] || die "--key requires a value"; KEY="$2"; shift 2 ;;
      -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [[ -n "${SRC}" && -n "${OUT}" ]] || die "--src and --out are required"
  [[ -d "${SRC}" ]] || die "--src is not a directory: ${SRC}"
  # Absolutize both: the pack step runs from inside the mktemp staging dir, so a
  # relative --out would resolve in there and tar would die with exit 4.
  SRC="$(cd "${SRC}" && pwd -P)" || die "could not resolve --src: ${SRC}" 4
  mkdir -p "${OUT}" || die "could not create ${OUT}" 4
  OUT="$(cd "${OUT}" && pwd -P)" || die "could not resolve --out: ${OUT}" 4
  [[ -z "${VERSION}" || "${VERSION}" =~ ^[0-9]{1,9}$ ]] || die "--version must be an integer"
  [[ -z "${KEY}" || -f "${KEY}" ]] || die "--key not found: ${KEY}" 3
  return 0
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return 0; fi
  shasum -a 256 "$1" | awk '{print $1}'
}

# Stage exactly the allowed file set, in a fixed order, with the requested
# version stamped into bundle.json. Anything in --src that is not on the list is
# deliberately left behind: the device's listing gate would reject it anyway.
stage_files() {   # stage_files <stagedir> <version> <released>
  local stage="$1" ver="$2" rel="$3" f
  for f in "${BUNDLE_FILES[@]}"; do
    [[ -f "${SRC}/${f}" ]] || die "missing required bundle file: ${f}" 4
    cp "${SRC}/${f}" "${stage}/${f}" || die "could not stage ${f}" 4
  done
  python3 - "${stage}/bundle.json" "${ver}" "${rel}" <<'PY' || die "could not stamp bundle.json" 4
import json, sys
path, ver, rel = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)
doc["version"], doc["released"] = ver, rel
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY
  return 0
}

# Read the FINISHED ARCHIVE back and run the device's own listing gate on it.
#
# WHY THIS EXISTS: staging a clean directory is not evidence that the archive is
# clean. On macOS, `tar` writes an `._<name>` AppleDouble member for every file
# carrying extended attributes — members that appear AFTER the staging check, and
# that BSD `tar -tzf` then omits from its own listing, so the build host cannot
# see them by eye. A v5 bundle shipped that way and every device refused it with
# "entry '._index.html.tmpl' is not an allowed data file".
#
# So: verify the artifact, not the intent, and verify it with a reader that does
# not hide members (python's tarfile). The member set must equal the allowed set
# EXACTLY — no extras, no absences, no directories, no absolute or traversing
# paths — which is the same rule the device applies before it will install.
verify_archive() {   # verify_archive <tarball>
  python3 - "$1" "${BUNDLE_FILES[@]}" <<'PY' || die "archive rejected by the device's own listing gate" 4
import sys, tarfile
path, allowed = sys.argv[1], sys.argv[2:]
with tarfile.open(path, "r:gz") as tf:
    members = tf.getmembers()
names = [m.name for m in members]
bad = [m.name for m in members if not m.isfile()]
if bad:
    sys.exit("non-file members: %s" % ", ".join(sorted(bad)))
unsafe = [n for n in names if n.startswith("/") or ".." in n.split("/") or "/" in n]
if unsafe:
    sys.exit("unsafe paths: %s" % ", ".join(sorted(unsafe)))
extra, missing = sorted(set(names) - set(allowed)), sorted(set(allowed) - set(names))
if extra or missing:
    sys.exit("member set wrong — extra: %s; missing: %s"
             % (", ".join(extra) or "none", ", ".join(missing) or "none"))
if len(names) != len(set(names)):
    sys.exit("duplicate members")
print("archive gate ok (%d data file(s), no extras)" % len(names))
PY
  return 0
}

# Refuse to sign a template that has silently lost a slot.
#
# WHY THIS EXISTS: verify_archive proves the bundle carries the right FILES; it
# says nothing about what is inside them. The device-side renderer substitutes a
# fixed slot list and only fails CLOSED for a slot it does not define ("{{" left
# over); a slot the template OMITS renders to nothing at all, so the section just
# disappears with every gate green. That is exactly how v10 and v11 shipped
# without the Services/House block. So: gate the CONTENT too, and derive the
# required list rather than hand-transcribing it (a hand-copied list is how the
# device's own _template_ok came to omit HOUSE_SECTION — P-BACKLOG [c160e17]).
#
# Two derivations, both machine-read:
#   1. AUTHORITATIVE — INDEX_SLOTS / WEATHER_SLOTS parsed straight out of the
#      portal that does the substituting (PORTAL_PY, overridable). Missing slot
#      => refuse; slot the portal does not define => refuse (the renderer would
#      discard the page).
#   2. REGRESSION — the previously shipped dashboard.tar.gz in --out. Any slot
#      the last release had and this one does not is a refusal. Needs no list at
#      all and stays correct as slots are added.
# Set SLOT_REMOVAL_OK=1 to authorise a deliberate slot retirement.
slots_ok() {   # slots_ok <stagedir> <previous-tarball-or-empty>
  PORTAL_PY="${PORTAL_PY:-${HOME}/Piranesi/skills/armbian-seed/assets/outpost/role/outpost-portal.py}" \
  SLOT_REMOVAL_OK="${SLOT_REMOVAL_OK:-0}" \
  python3 - "$1" "$2" <<'PY' || die "template slot gate rejected this build" 4
import os, re, sys, tarfile

stage, prev = sys.argv[1], sys.argv[2]
TMPL = {"index.html.tmpl": "INDEX_SLOTS", "weather.html.tmpl": "WEATHER_SLOTS"}
slots = lambda text: set(re.findall(r"\{\{([A-Z0-9_]+)\}\}", text))
read = lambda p: open(p, encoding="utf-8").read()
fail = []

portal = os.environ.get("PORTAL_PY", "")
declared = {}
if portal and os.path.isfile(portal):
    psrc = read(portal)
    for tmpl, var in TMPL.items():
        m = re.search(r"^%s\s*=\s*\(([^)]*)\)" % var, psrc, re.M)
        if m:
            declared[tmpl] = set(re.findall(r'"([A-Z0-9_]+)"', m.group(1)))
if declared:
    print("slot gate: %d slot declaration(s) read from %s" % (len(declared), portal))
else:
    print("slot gate: WARNING no portal slot declaration at %r — regression check only"
          % portal, file=sys.stderr)

prev_slots = {}
if prev and os.path.isfile(prev):
    with tarfile.open(prev, "r:gz") as tf:
        for tmpl in TMPL:
            try:
                fh = tf.extractfile(tmpl)
            except KeyError:
                continue
            if fh is not None:
                prev_slots[tmpl] = slots(fh.read().decode("utf-8", "replace"))

for tmpl in TMPL:
    path = os.path.join(stage, tmpl)
    if not os.path.isfile(path):
        continue                      # stage_files already enforces presence
    have = slots(read(path))
    want = declared.get(tmpl)
    if want is not None:
        missing = sorted(want - have)
        if missing:
            fail.append("%s omits declared slot(s): %s" % (tmpl, ", ".join(missing)))
        unknown = sorted(have - want)
        if unknown:
            fail.append("%s asks for slot(s) the portal does not define (the "
                        "renderer would discard the page): %s" % (tmpl, ", ".join(unknown)))
    lost = sorted(prev_slots.get(tmpl, set()) - have)
    if lost and os.environ.get("SLOT_REMOVAL_OK") != "1":
        fail.append("%s DROPS slot(s) the last shipped release carried: %s "
                    "(set SLOT_REMOVAL_OK=1 if that retirement is deliberate)"
                    % (tmpl, ", ".join(lost)))

if fail:
    sys.exit("\n".join("  - " + f for f in fail))
print("slot gate ok")
PY
  return 0
}

write_manifest() {   # write_manifest <tarball> <version> <released> <dest>
  local sha bytes
  sha="$(sha256_of "$1")" || die "could not hash the bundle" 4
  bytes="$(wc -c < "$1" | tr -d ' ')"
  (( bytes > 0 && bytes <= MAX_BUNDLE_BYTES )) \
    || die "bundle is ${bytes} B (cap ${MAX_BUNDLE_BYTES}); the device would refuse it" 4
  cat > "$4" <<EOF
{
  "schema": "piranesi.lighthouse.dashboard.manifest/1",
  "version": $2,
  "released": "$3",
  "bundle": "dashboard.tar.gz",
  "sha256": "${sha}",
  "bytes": ${bytes}
}
EOF
  return 0
}

main() {
  parse_args "$@"
  command -v tar >/dev/null 2>&1 || die "tar absent" 3
  command -v python3 >/dev/null 2>&1 || die "python3 absent" 3
  local ver released tarball
  ver="${VERSION}"
  if [[ -z "${ver}" ]]; then
    ver="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["version"]))' \
      "${SRC}/bundle.json")" || die "could not read the source version" 4
  fi
  released="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  STAGE_DIR="$(mktemp -d)" || die "mktemp failed" 3
  # R1: the trap only ever removes this script's own mktemp -d staging dir.
  trap '[[ -n "${STAGE_DIR}" ]] && rm -rf "${STAGE_DIR}"' EXIT INT TERM
  stage_files "${STAGE_DIR}" "${ver}" "${released}"
  tarball="${OUT}/dashboard.tar.gz"
  # Content gate BEFORE tar: ${tarball} still holds the PREVIOUS release
  # here, which is what the regression half of the check compares against.
  slots_ok "${STAGE_DIR}" "${tarball}"
  # COPYFILE_DISABLE stops BSD tar emitting AppleDouble (`._*`) members for
  # extended attributes; --no-xattrs is the GNU-side equivalent and is passed
  # only when this tar accepts it, so the same script builds on both platforms.
  local tar_opts=()
  tar --no-xattrs -cf /dev/null -T /dev/null >/dev/null 2>&1 && tar_opts+=(--no-xattrs)
  ( cd "${STAGE_DIR}" && COPYFILE_DISABLE=1 tar "${tar_opts[@]}" -czf "${tarball}" "${BUNDLE_FILES[@]}" ) \
    || die "tar failed" 4
  verify_archive "${tarball}"
  write_manifest "${tarball}" "${ver}" "${released}" "${OUT}/MANIFEST.json"
  if [[ -n "${KEY}" ]]; then
    rm -f "${OUT}/MANIFEST.json.sig"
    ssh-keygen -Y sign -f "${KEY}" -n "${SIG_NAMESPACE}" "${OUT}/MANIFEST.json" >/dev/null 2>&1 \
      || die "signing failed (is ${KEY} an ssh private key?)" 4
    printf 'signed v%s with %s\n' "${ver}" "$(ssh-keygen -lf "${KEY}.pub" | awk '{print $2}')"
  else
    printf 'WARNING: unsigned build — no device will install this\n' >&2
  fi
  printf 'dashboard bundle v%s -> %s (%s B)\n' \
    "${ver}" "${tarball}" "$(wc -c < "${tarball}" | tr -d ' ')"
  return 0
}

main "$@"
