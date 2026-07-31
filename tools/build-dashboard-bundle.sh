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
      -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [[ -n "${SRC}" && -n "${OUT}" ]] || die "--src and --out are required"
  [[ -d "${SRC}" ]] || die "--src is not a directory: ${SRC}"
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
  mkdir -p "${OUT}" || die "could not create ${OUT}" 4
  STAGE_DIR="$(mktemp -d)" || die "mktemp failed" 3
  # R1: the trap only ever removes this script's own mktemp -d staging dir.
  trap '[[ -n "${STAGE_DIR}" ]] && rm -rf "${STAGE_DIR}"' EXIT INT TERM
  stage_files "${STAGE_DIR}" "${ver}" "${released}"
  tarball="${OUT}/dashboard.tar.gz"
  ( cd "${STAGE_DIR}" && tar -czf "${tarball}" "${BUNDLE_FILES[@]}" ) \
    || die "tar failed" 4
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
