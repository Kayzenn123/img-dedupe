#!/usr/bin/env bash
# test.sh — tests for img-dedupe. No dependencies besides bash + ffmpeg.
# Fixtures are generated with ffmpeg lavfi (synthetic, no copyrighted media).
set -u

BIN="$(cd "$(dirname "$0")" && pwd)/img-dedupe.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; [[ -n "${2:-}" ]] && echo "       $2"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---- fixtures -----------------------------------------------------------
# base: gradient + testsrc pattern; near1: base cropped 4px then scaled back
# (simulates a slight re-export); diff: completely different pattern.
ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=320x240:rate=1:duration=1" \
    -frames:v 1 "$T/base.png"
cp "$T/base.png" "$T/base-copy.png"
ffmpeg -nostdin -v error -y -i "$T/base.png" \
    -vf "crop=312:232:4:4,scale=320:240" -frames:v 1 "$T/base-near.png"
ffmpeg -nostdin -v error -y -f lavfi -i "gradients=size=320x240:rate=1:duration=1:speed=0.3" \
    -frames:v 1 "$T/different.png"
# corrupt file with image extension
head -c 200 /dev/urandom > "$T/broken.png"
mkdir -p "$T/empty"

# ---- 1: --help exits 0 ---------------------------------------------------
out=$("$BIN" --help 2>&1); code=$?
[[ $code -eq 0 && "$out" == *"--threshold"* ]] && ok "help exits 0 and documents --threshold" \
    || bad "help" "code=$code"

# ---- 2: --version ---------------------------------------------------------
out=$("$BIN" --version 2>&1); code=$?
[[ $code -eq 0 && "$out" == "img-dedupe "* ]] && ok "version prints name+version" \
    || bad "version" "out=$out"

# ---- 3: unknown flag -> exit 2 -------------------------------------------
"$BIN" --bogus >/dev/null 2>&1; code=$?
[[ $code -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag" "code=$code"

# ---- 4: missing dir -> exit 1 --------------------------------------------
"$BIN" "$T/nope" >/dev/null 2>&1; code=$?
[[ $code -eq 1 ]] && ok "missing dir exits 1" || bad "missing dir" "code=$code"

# ---- 5: identical copies grouped, different image not --------------------
out=$("$BIN" "$T" --max-depth 1 2>/dev/null)
echo "$out" | grep -q "duplicate group(s)" \
    && echo "$out" | grep -q "KEEP.*base" \
    && ! echo "$out" | grep -q "DUPE.*different" \
    && ok "identical copies grouped, different.png not flagged" \
    || bad "grouping basics" "$out"

# ---- 6: near-duplicate caught with default threshold ---------------------
out=$("$BIN" "$T" --max-depth 1 2>/dev/null)
echo "$out" | grep -q "base-near.png" \
    && ok "near-duplicate (crop+rescale) grouped at default threshold" \
    || bad "near-duplicate grouping" "$out"

# ---- 7: --threshold 0 splits near-duplicate but keeps exact --------------
out=$("$BIN" -t 0 "$T" --max-depth 1 2>/dev/null)
echo "$out" | grep -q "base-copy.png" && ! echo "$out" | grep -q "base-near.png" \
    && ok "threshold 0 keeps exact dupes, drops near-dupe" \
    || bad "threshold 0" "$out"

# ---- 8: empty dir -> 0 groups, exit 0 ------------------------------------
out=$("$BIN" "$T/empty" 2>&1); code=$?
[[ $code -eq 0 && "$out" == *"No images found"* ]] && ok "empty dir handled" \
    || bad "empty dir" "code=$code out=$out"

# ---- 9: corrupt image skipped with warning, others still processed -------
out=$("$BIN" "$T" --max-depth 1 2>&1 >/dev/null)
echo "$out" | grep -q "cannot decode as image" \
    && ok "corrupt image warned and skipped" \
    || bad "corrupt image" "$out"

# ---- 10: --json is valid JSON with expected shape ------------------------
out=$("$BIN" --json "$T" --max-depth 1 2>/dev/null)
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['tool']=='img-dedupe' and d['scanned']>=4
assert d['summary']['duplicate_groups']>=1
g=d['groups'][0]
assert 'keep' in g and 'duplicates' in g and g['duplicates'][0]['distance']>=0
print('json-ok')
" >/dev/null 2>&1 && ok "json output valid with expected shape" \
    || bad "json output" "${out:0:200}"

# ---- 11: dry-run move changes nothing ------------------------------------
M="$T/move-dry"; mkdir -p "$M"
mkdir -p "$T/dry"; cp "$T/base.png" "$T/dry/a.png"; cp "$T/base.png" "$T/dry/b.png"
"$BIN" --move "$M" "$T/dry" >/dev/null 2>&1
[[ -f "$T/dry/a.png" && -f "$T/dry/b.png" && -z "$(ls -A "$M")" ]] \
    && ok "move without --yes is dry-run (nothing moved)" \
    || bad "dry-run move" "files moved without --yes"

# ---- 12: --move --yes actually moves --------------------------------------
M2="$T/move-real"; mkdir -p "$M2"
mkdir -p "$T/real"; cp "$T/base.png" "$T/real/a.png"; cp "$T/base.png" "$T/real/b.png"
"$BIN" --move "$M2" --yes "$T/real" >/dev/null 2>&1
moved=$(ls "$M2" | wc -l)
[[ ! -f "$T/real/b.png" && -f "$T/real/a.png" && "$moved" -eq 1 ]] \
    && ok "--move --yes moves exactly the duplicate" \
    || bad "real move" "moved=$moved"

# ---- 13: --delete dry-run then real ---------------------------------------
mkdir -p "$T/del"; cp "$T/base.png" "$T/del/a.png"; cp "$T/base.png" "$T/del/b.png"
"$BIN" --delete "$T/del" >/dev/null 2>&1
[[ -f "$T/del/b.png" ]] || { bad "delete dry-run" "deleted without --yes"; }
"$BIN" --delete --yes "$T/del" >/dev/null 2>&1
[[ -f "$T/del/a.png" && ! -f "$T/del/b.png" ]] \
    && ok "--delete dry-run safe, --yes deletes dupe only" \
    || bad "delete --yes"

# ---- 14: NO_COLOR honored -------------------------------------------------
out=$(NO_COLOR=1 "$BIN" "$T" --max-depth 1 2>/dev/null)
[[ "$out" != *$'\e['* ]] && ok "NO_COLOR disables escape codes" \
    || bad "NO_COLOR" "escape codes present"

# ---- 15: stdin file list --------------------------------------------------
out=$(printf '%s\n%s\n' "$T/base.png" "$T/different.png" | "$BIN" 2>/dev/null)
echo "$out" | grep -q "Scanned 2 image" \
    && ok "stdin file list accepted" \
    || bad "stdin" "$out"

# ---- 16: e2e exit codes ----------------------------------------------------
"$BIN" "$T" --max-depth 1 >/dev/null 2>&1; c1=$?
"$BIN" --fail-on-dupes "$T" --max-depth 1 >/dev/null 2>&1; c2=$?
"$BIN" --fail-on-dupes "$T/empty" >/dev/null 2>&1; c3=$?
[[ $c1 -eq 0 && $c2 -eq 4 && $c3 -eq 0 ]] \
    && ok "exit codes: 0 ok, 4 on --fail-on-dupes with dupes, 0 without" \
    || bad "exit codes" "c1=$c1 c2=$c2 c3=$c3"

# ---- 17: keeper is the largest file ----------------------------------------
mkdir -p "$T/keep"
ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=640x480:rate=1:duration=1" -frames:v 1 "$T/keep/big.png"
ffmpeg -nostdin -v error -y -i "$T/keep/big.png" -vf "scale=160:120" -frames:v 1 "$T/keep/small.png"
sz_big=$(stat -c%s "$T/keep/big.png"); sz_small=$(stat -c%s "$T/keep/small.png")
if (( sz_big >= sz_small )); then expect="big.png"; else expect="small.png"; fi
out=$("$BIN" "$T/keep" 2>/dev/null)
echo "$out" | grep -q "KEEP.*$expect" \
    && ok "keeper is the largest file ($expect)" \
    || bad "keeper choice" "$out"

# ---- 18: --min-size filters tiny files --------------------------------------
out=$("$BIN" --min-size 999999999 "$T" --max-depth 1 2>&1)
[[ "$out" == *"No images found"* ]] \
    && ok "--min-size filters everything out cleanly" \
    || bad "min-size" "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
