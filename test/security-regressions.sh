#!/usr/bin/env bash
# Local regressions for the scanner wrapper. No network. Uses a stub curl.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$ROOT/scan/trustabl-scan.sh"
WORK=$(mktemp -d)
STUB="$WORK/stubs"
mkdir -p "$STUB"
TOKEN='local-test-token-wxyz'
fail=0

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) echo "unsupported OS"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported arch"; exit 1 ;;
esac

mkdir -p "$WORK/payload"
cat > "$WORK/payload/trustabl" << 'EOF'
#!/bin/bash
echo RAN >> "$STUB_LOG"
fmt=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--format" ]; then fmt="$a"; fi
  prev="$a"
done
if [ "$fmt" = "sarif" ]; then
  printf '%s\n' '{"version":"2.1.0","runs":[]}'
else
  printf '%s\n' '{"overall_score":1,"findings":[],"readiness":[]}'
fi
exit 0
EOF
chmod 755 "$WORK/payload/trustabl"
tar -czf "$WORK/good.tgz" -C "$WORK/payload" trustabl
GOOD_SHA=$(sha256sum "$WORK/good.tgz" | awk '{print $1}')
GOOD_ASSET="trustabl_0.0.0_${OS}_${ARCH}.tar.gz"

python3 - << 'PY' "$WORK/slip.tgz" "$WORK/payload/trustabl"
import io, sys, tarfile
dest, binary = sys.argv[1], sys.argv[2]
data = b"SLIPPED\n"
with tarfile.open(dest, "w:gz") as tar:
    info = tarfile.TarInfo("../escaped.txt")
    info.size = len(data)
    info.mode = 0o644
    tar.addfile(info, io.BytesIO(data))
    raw = open(binary, "rb").read()
    info = tarfile.TarInfo("trustabl")
    info.size = len(raw)
    info.mode = 0o755
    tar.addfile(info, io.BytesIO(raw))
PY
SLIP_SHA=$(sha256sum "$WORK/slip.tgz" | awk '{print $1}')

mkdir -p "$WORK/readme-only"
echo hi > "$WORK/readme-only/README"
tar -czf "$WORK/noread.tgz" -C "$WORK/readme-only" README
NOBIN_SHA=$(sha256sum "$WORK/noread.tgz" | awk '{print $1}')

cat > "$STUB/curl" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
out=""
url=""
cfg=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  if [ "$prev" = "--config" ]; then cfg="$a"; fi
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
  prev="$a"
done
if [ -n "$cfg" ] && grep -q 'Authorization: Bearer' "$cfg"; then
  echo AUTH_HEADER_PRESENT >> "$STUB_LOG"
fi
if [[ "$url" == *checksums.txt ]]; then
  if [ "${CURL_CHECKSUM_MODE:-ok}" = "fail" ]; then
    exit 22
  fi
  if [ "${CURL_CHECKSUM_MODE:-ok}" = "bad" ]; then
    printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$STUB_ASSET_NAME" > "$out"
    exit 0
  fi
  printf '%s  %s\n' "$STUB_SHA" "$STUB_ASSET_NAME" > "$out"
  exit 0
fi
cp "$STUB_TGZ" "$out"
exit 0
EOF
chmod 755 "$STUB/curl"

# A planted scanner that must never be selected via PATH.
mkdir -p "$WORK/planted-bin"
cat > "$WORK/planted-bin/trustabl" << 'EOF'
#!/bin/bash
echo PLANTED_PATH >> "$STUB_LOG"
exit 0
EOF
chmod 755 "$WORK/planted-bin/trustabl"

run_scan() {
  local name="$1"
  shift
  local dir="$WORK/cases/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  local log="$WORK/logs/$name.log"
  mkdir -p "$WORK/logs"
  : > "$log"
  (
    cd "$dir" || exit 1
    # shellcheck disable=SC2086
    env -i PATH="$STUB:$WORK/planted-bin:/usr/bin:/bin" HOME="$WORK/home" \
      STUB_LOG="$log" STUB_TGZ="${STUB_TGZ:-$WORK/good.tgz}" \
      STUB_SHA="${STUB_SHA:-$GOOD_SHA}" STUB_ASSET_NAME="${STUB_ASSET_NAME:-$GOOD_ASSET}" \
      CURL_CHECKSUM_MODE="${CURL_CHECKSUM_MODE:-ok}" \
      VERSION="${VERSION:-v0.0.0}" TARGET=. \
      DEBUG="${DEBUG:-false}" GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
      bash "$SCAN" > "$WORK/logs/$name.out" 2> "$WORK/logs/$name.err"
    echo $? > "$WORK/logs/$name.exit"
  )
}

check() {
  local name="$1" want_exit="$2"
  local got
  got=$(cat "$WORK/logs/$name.exit")
  if [ "$got" != "$want_exit" ]; then
    echo "FAIL $name: exit $got, want $want_exit"
    echo "--- stderr ---"
    cat "$WORK/logs/$name.err"
    fail=1
    return
  fi
  echo "ok $name (exit $got)"
}

assert_absent() {
  local name="$1" needle="$2"
  if grep -F -q -- "$needle" "$WORK/logs/$name.log" "$WORK/logs/$name.out" "$WORK/logs/$name.err"; then
    echo "FAIL $name: found forbidden text"
    fail=1
  else
    echo "ok $name (secret not in output)"
  fi
}

# 1. Happy path still scans and writes the usual outputs.
STUB_TGZ="$WORK/good.tgz" STUB_SHA="$GOOD_SHA" STUB_ASSET_NAME="$GOOD_ASSET" CURL_CHECKSUM_MODE=ok \
  VERSION=v0.0.0 run_scan happy
check happy 0
if ! grep -q RAN "$WORK/logs/happy.log"; then echo "FAIL happy: scanner did not run"; fail=1; fi
if ! grep -q 'checksum verified' "$WORK/logs/happy.out"; then echo "FAIL happy: checksum not verified"; fail=1; fi
for f in trustabl.json trustabl.sarif trustabl.env trustabl-summary.md; do
  if [ ! -f "$WORK/cases/happy/$f" ] || [ -L "$WORK/cases/happy/$f" ]; then
    echo "FAIL happy: missing regular file $f"
    fail=1
  fi
done

# 2. Missing checksums.txt must not run the binary.
CURL_CHECKSUM_MODE=fail run_scan nocheck
check nocheck 2
if grep -q RAN "$WORK/logs/nocheck.log"; then echo "FAIL nocheck: binary ran"; fail=1; else echo "ok nocheck (binary not run)"; fi

# 3. Wrong checksum must not run the binary.
CURL_CHECKSUM_MODE=bad run_scan badcheck
check badcheck 2
if grep -q RAN "$WORK/logs/badcheck.log"; then echo "FAIL badcheck: binary ran"; fail=1; else echo "ok badcheck (binary not run)"; fi

# 4. A version that leaves the release path is rejected before curl.
VERSION='../../../../attacker/evil/releases/download/v1.2.3' run_scan badver
check badver 2
if [ -s "$WORK/logs/badver.log" ]; then echo "FAIL badver: curl was invoked"; fail=1; else echo "ok badver (no download)"; fi

# 5. DEBUG=true must not print the token, and auth must still be attached.
DEBUG=true GITHUB_TOKEN="$TOKEN" run_scan debug
check debug 0
assert_absent debug "$TOKEN"
if ! grep -q AUTH_HEADER_PRESENT "$WORK/logs/debug.log"; then
  echo "FAIL debug: auth header was not sent"
  fail=1
else
  echo "ok debug (auth header present)"
fi

# 6. A token with a newline is refused.
GITHUB_TOKEN=$'abc\ndef' run_scan badtoken
check badtoken 2

# 7. Output symlinks are replaced, not followed.
secret="$WORK/secret"
echo ORIGINAL > "$secret"
mkdir -p "$WORK/cases"
# run_scan creates the dir, so plant the links by wrapping: create after mkdir
# by using a pre-hook inside the case dir. Do it inline.
name=symlink
dir="$WORK/cases/$name"
rm -rf "$dir"
mkdir -p "$dir" "$WORK/logs" "$WORK/home"
: > "$WORK/logs/$name.log"
ln -s "$secret" "$dir/trustabl.json"
ln -s "$secret" "$dir/trustabl.sarif"
ln -s "$secret" "$dir/trustabl.env"
ln -s "$secret" "$dir/trustabl-summary.md"
(
  cd "$dir" || exit 1
  env -i PATH="$STUB:$WORK/planted-bin:/usr/bin:/bin" HOME="$WORK/home" \
    STUB_LOG="$WORK/logs/$name.log" STUB_TGZ="$WORK/good.tgz" STUB_SHA="$GOOD_SHA" \
    STUB_ASSET_NAME="$GOOD_ASSET" CURL_CHECKSUM_MODE=ok VERSION=v0.0.0 TARGET=. \
    DEBUG=false GITHUB_TOKEN= \
    bash "$SCAN" > "$WORK/logs/$name.out" 2> "$WORK/logs/$name.err"
  echo $? > "$WORK/logs/$name.exit"
)
check symlink 0
if [ "$(cat "$secret")" != "ORIGINAL" ]; then
  echo "FAIL symlink: target file was overwritten"
  fail=1
else
  echo "ok symlink (target unchanged)"
fi
if [ -L "$dir/trustabl.json" ]; then echo "FAIL symlink: json is still a symlink"; fail=1; fi

# 8. A .trustabl-bin symlink must not receive the download.
name=binsym
dir="$WORK/cases/$name"
outside="$WORK/outside"
rm -rf "$dir" "$outside"
mkdir -p "$dir" "$outside" "$WORK/logs"
echo KEEP > "$outside/keep.txt"
ln -s "$outside" "$dir/.trustabl-bin"
: > "$WORK/logs/$name.log"
(
  cd "$dir" || exit 1
  env -i PATH="$STUB:$WORK/planted-bin:/usr/bin:/bin" HOME="$WORK/home" \
    STUB_LOG="$WORK/logs/$name.log" STUB_TGZ="$WORK/good.tgz" STUB_SHA="$GOOD_SHA" \
    STUB_ASSET_NAME="$GOOD_ASSET" CURL_CHECKSUM_MODE=ok VERSION=v0.0.0 TARGET=. \
    DEBUG=false GITHUB_TOKEN= \
    bash "$SCAN" > "$WORK/logs/$name.out" 2> "$WORK/logs/$name.err"
  echo $? > "$WORK/logs/$name.exit"
)
check binsym 0
if [ -e "$outside/trustabl" ] || ls "$outside"/*.tar.gz >/dev/null 2>&1; then
  echo "FAIL binsym: download landed in the symlink target"
  fail=1
else
  echo "ok binsym (outside dir untouched)"
fi

# 9. Archive members with .. are refused.
STUB_TGZ="$WORK/slip.tgz" STUB_SHA="$SLIP_SHA" STUB_ASSET_NAME="$GOOD_ASSET" run_scan slip
check slip 2
if [ -e "$WORK/cases/escaped.txt" ] || [ -e "$WORK/escaped.txt" ]; then
  echo "FAIL slip: traversed file was written"
  fail=1
else
  echo "ok slip (not extracted)"
fi

# 10. An archive without the trustabl binary must not fall through to PATH.
STUB_TGZ="$WORK/noread.tgz" STUB_SHA="$NOBIN_SHA" STUB_ASSET_NAME="$GOOD_ASSET" run_scan nobin
check nobin 2
if grep -q PLANTED_PATH "$WORK/logs/nobin.log"; then
  echo "FAIL nobin: PATH binary ran"
  fail=1
else
  echo "ok nobin (PATH binary not run)"
fi

rm -rf "$WORK"
if [ "$fail" -ne 0 ]; then
  echo "security regressions failed"
  exit 1
fi
echo "all security regressions passed"
