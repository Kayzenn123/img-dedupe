#!/usr/bin/env bash
#
# img-dedupe — find near-duplicate images via perceptual hashing.
#
# Scans one or more directories for images, computes a 64-bit average hash
# (aHash) for each image with ffmpeg, and groups images whose hashes differ
# by at most --threshold bits (Hamming distance). Exact copies have distance
# 0; re-exports, slight crops and recompressions usually land at 1-6.
#
# Actions that change files (--move, --delete) are dry-run by default;
# pass --yes to actually apply them. Fully offline, zero dependencies
# besides ffmpeg.
#
set -euo pipefail

VERSION="1.0.0"
PROG="img-dedupe"

THRESHOLD=5
AS_JSON=0
MOVE_DIR=""
DO_DELETE=0
CONFIRM=0
MAX_DEPTH=""
FAIL_ON_DUPES=0
MIN_SIZE=0
QUIET=0
NO_COLOR_FLAG=0

usage() {
    cat <<EOF
Usage: $PROG [OPTIONS] [DIR]...
       $PROG [OPTIONS] < filelist.txt

Find near-duplicate images in DIRs using perceptual hashing (aHash).
Fully offline. Needs ffmpeg on PATH.

Options:
  -t, --threshold N   max Hamming distance to call two images duplicates
                      (default 5; 0 = byte-identical look only)
      --max-depth N   limit directory recursion depth
      --min-size BYTES skip files smaller than BYTES (default 0)
      --json          machine-readable JSON output instead of the table
  -q, --quiet         print only the summary line
      --move DIR      move duplicate files (not the kept one) into DIR
      --delete        delete duplicate files (not the kept one)
  -y, --yes           actually apply --move / --delete (default: dry-run)
      --fail-on-dupes exit 4 when at least one duplicate group is found
      --no-color      disable colored output
  -h, --help          show this help and exit
      --version       print version and exit

The kept file of each group is the largest one (ties: first path alphabetically).
Exit codes: 0 ok, 1 runtime error, 2 bad usage, 4 duplicates found (--fail-on-dupes).
EOF
}

die()         { echo "$PROG: error: $*" >&2; exit 1; }
usage_error() { echo "$PROG: error: $*" >&2; echo "Try '$PROG --help'." >&2; exit 2; }
warn()        { echo "$PROG: warning: $*" >&2; }

# ---------------------------------------------------------------- args ---
DIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--threshold)   THRESHOLD="${2:?missing value}"; shift 2 ;;
        --threshold=*)    THRESHOLD="${1#*=}"; shift ;;
        --max-depth)      MAX_DEPTH="${2:?missing value}"; shift 2 ;;
        --max-depth=*)    MAX_DEPTH="${1#*=}"; shift ;;
        --min-size)       MIN_SIZE="${2:?missing value}"; shift 2 ;;
        --min-size=*)     MIN_SIZE="${1#*=}"; shift ;;
        --json)           AS_JSON=1; shift ;;
        -q|--quiet)       QUIET=1; shift ;;
        --move)           MOVE_DIR="${2:?missing value}"; shift 2 ;;
        --move=*)         MOVE_DIR="${1#*=}"; shift ;;
        --delete)         DO_DELETE=1; shift ;;
        -y|--yes)         CONFIRM=1; shift ;;
        --fail-on-dupes)  FAIL_ON_DUPES=1; shift ;;
        --no-color)       NO_COLOR_FLAG=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        --version)        echo "$PROG $VERSION"; exit 0 ;;
        --)               shift; while [[ $# -gt 0 ]]; do DIRS+=("$1"); shift; done ;;
        -*)               usage_error "unknown option: $1" ;;
        *)                DIRS+=("$1"); shift ;;
    esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || usage_error "--threshold must be a non-negative integer"
[[ "$MIN_SIZE"   =~ ^[0-9]+$ ]] || usage_error "--min-size must be a non-negative integer"
[[ -z "$MAX_DEPTH" || "$MAX_DEPTH" =~ ^[0-9]+$ ]] || usage_error "--max-depth must be a non-negative integer"
if [[ -n "$MOVE_DIR" && "$DO_DELETE" -eq 1 ]]; then
    usage_error "--move and --delete cannot be combined"
fi

# stdin file list when no DIR given
if [[ ${#DIRS[@]} -eq 0 ]]; then
    if [[ -t 0 ]]; then
        usage_error "no directory given and stdin is a terminal"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && DIRS+=("$line")
    done
    [[ ${#DIRS[@]} -gt 0 ]] || usage_error "no input paths on stdin"
fi

for d in "${DIRS[@]}"; do
    [[ -e "$d" ]] || die "no such file or directory: $d"
done

command -v ffmpeg >/dev/null 2>&1 \
    || die "ffmpeg not found on PATH (https://ffmpeg.org/download.html)"

# ---------------------------------------------------------------- color --
if [[ "$NO_COLOR_FLAG" -eq 1 || -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
else
    C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RESET=$'\e[0m'
fi

# ------------------------------------------------------------- helpers --
human() { # bytes -> "1.2 MB"
    local b=$1
    if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
    elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
    elif (( b >= 1024 ));       then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
    else printf "%d B" "$b"; fi
}

json_escape() { # $1 -> JSON string literal
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    printf '"%s"' "$s"
}

# hash_image PATH -> prints 64-char bit string, returns 1 on failure
hash_image() {
    local bits
    bits=$(ffmpeg -nostdin -v error -i "$1" -frames:v 1 \
        -vf "scale=8:8:flags=bilinear,format=gray" \
        -f rawvideo -pix_fmt gray - 2>/dev/null \
        | od -An -vtu1 \
        | awk '{ for (i=1;i<=NF;i++){ n++; a[n]=$i; s+=$i } }
               END{ if (n != 64) exit 1
                    avg = s/n
                    for (i=1;i<=64;i++) printf "%d", (a[i] > avg ? 1 : 0) }') \
        || return 1
    [[ -n "$bits" ]] || return 1
    printf '%s' "$bits"
}

# hamming BITS1 BITS2 -> distance
hamming() {
    local a=$1 b=$2 i d=0
    for (( i=0; i<64; i++ )); do
        [[ "${a:i:1}" == "${b:i:1}" ]] || (( d++ ))
    done
    printf '%d' "$d"
}

# --------------------------------------------------------------- scan ---
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT
HASHLIST="$TMPDIR_WORK/hashes.tsv"

find_cmd=(find "${DIRS[@]}")
[[ -n "$MAX_DEPTH" ]] && find_cmd+=(-maxdepth "$MAX_DEPTH")
find_cmd+=(-type f
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
     -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.tif' \
     -o -iname '*.tiff' -o -iname '*.gif' \) -print0)

scanned=0; skipped=0
while IFS= read -r -d '' f; do
    if [[ "$f" == *$'\n'* ]]; then
        warn "skipping (newline in filename): $f"; skipped=$((skipped+1)); continue
    fi
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null) || {
        warn "cannot stat: $f"; skipped=$((skipped+1)); continue
    }
    if (( size < MIN_SIZE )); then skipped=$((skipped+1)); continue; fi
    bits=$(hash_image "$f") || { warn "cannot decode as image: $f"; skipped=$((skipped+1)); continue; }
    printf '%s\t%s\t%s\n' "$bits" "$size" "$f" >> "$HASHLIST"
    scanned=$((scanned+1))
done < <("${find_cmd[@]}" 2>/dev/null) || true

if (( scanned == 0 )); then
    [[ "$AS_JSON" -eq 1 ]] && printf '{"tool":"%s","version":"%s","threshold":%d,"scanned":0,"groups":[],"summary":{"duplicate_groups":0,"duplicate_files":0,"reclaimable_bytes":0}}\n' "$PROG" "$VERSION" "$THRESHOLD"
    [[ "$AS_JSON" -eq 0 && "$QUIET" -eq 0 ]] && echo "No images found."
    [[ "$AS_JSON" -eq 0 && "$QUIET" -eq 1 ]] && echo "scanned=0 groups=0 duplicates=0"
    exit 0
fi

# -------------------------------------------------------------- group ---
# union-find over Hamming distance, done in one awk pass
GROUPED="$TMPDIR_WORK/grouped.tsv"
awk -F'\t' -v TH="$THRESHOLD" '
    { n++; h[n]=$1; sz[n]=$2+0; p[n]=$3; parent[n]=n }
    function find(x){ while(parent[x]!=x){ parent[x]=parent[parent[x]]; x=parent[x] } return x }
    function ham(a,b,  i,d){ d=0; for(i=1;i<=64;i++) if(substr(a,i,1)!=substr(b,i,1)) d++; return d }
    END{
        for(i=1;i<=n;i++) for(j=i+1;j<=n;j++)
            if(ham(h[i],h[j]) <= TH+0){
                ri=find(i); rj=find(j); if(ri!=rj) parent[ri]=rj
            }
        g=0
        for(i=1;i<=n;i++){ r=find(i); if(!(r in gid)) gid[r]=++g }
        for(i=1;i<=n;i++) printf "%d\t%s\t%s\t%s\n", gid[find(i)], h[i], sz[i], p[i]
    }' "$HASHLIST" | LC_ALL=C sort -t $'\t' -k1,1n -k3,3nr -k4,4 > "$GROUPED"

# ------------------------------------------------------------- report ---
# per group: first row (largest size, then path) = keeper
group_count=0; dupe_files=0; reclaim=0
declare -a ACTIONS=()   # "MOVE|src|dst" / "DELETE|src"

report_group() { # $1 = gid, rows on stdin: "hash\tsize\tpath"
    local gid=$1 rows keeper_path keeper_size keeper_hash
    rows=$(cat)
    local n
    n=$(printf '%s\n' "$rows" | grep -c . || true)
    (( n > 1 )) || return 0
    group_count=$((group_count+1))

    keeper_hash=$(printf '%s\n' "$rows" | head -1 | cut -f1)
    keeper_size=$(printf '%s\n' "$rows" | head -1 | cut -f2)
    keeper_path=$(printf '%s\n' "$rows" | head -1 | cut -f3-)

    local dlist=() dsize_total=0
    while IFS=$'\t' read -r dh ds dp; do
        [[ -n "$dp" ]] || continue
        dlist+=("$dh"$'\t'"$ds"$'\t'"$dp")
        dsize_total=$(( dsize_total + ds ))
        dupe_files=$((dupe_files+1))
    done < <(printf '%s\n' "$rows" | tail -n +2)
    reclaim=$(( reclaim + dsize_total ))

    # ---- human output
    if [[ "$AS_JSON" -eq 0 && "$QUIET" -eq 0 ]]; then
        printf '\n%sGroup %d%s — %d files, %d duplicate(s), %s reclaimable\n' \
            "$C_BOLD" "$group_count" "$C_RESET" "$n" "$(( n - 1 ))" "$(human "$dsize_total")"
        printf '  %sKEEP%s  %s  %s%s\n' "$C_GREEN" "$C_RESET" "$(human "$keeper_size")" "$C_DIM" "$keeper_path$C_RESET"
        for e in "${dlist[@]}"; do
            dh="${e%%$'\t'*}"; rest="${e#*$'\t'}"; ds="${rest%%$'\t'*}"; dp="${rest#*$'\t'}"
            dist=$(hamming "$keeper_hash" "$dh")
            printf '  %sDUPE%s  %s  (dist %d) %s\n' "$C_YELLOW" "$C_RESET" "$(human "$ds")" "$dist" "$dp"
        done
    fi

    # ---- JSON accumulation (bash-built)
    if [[ "$AS_JSON" -eq 1 ]]; then
        local j
        j=$(printf '{"group":%d,"keep":{"path":%s,"size":%d,"hash":"%s"},"duplicates":[' \
            "$group_count" "$(json_escape "$keeper_path")" "$keeper_size" "$keeper_hash")
        local first=1
        for e in "${dlist[@]}"; do
            dh="${e%%$'\t'*}"; rest="${e#*$'\t'}"; ds="${rest%%$'\t'*}"; dp="${rest#*$'\t'}"
            dist=$(hamming "$keeper_hash" "$dh")
            if (( first )); then first=0; else j+=','; fi
            j+=$(printf '{"path":%s,"size":%d,"hash":"%s","distance":%d}' \
                "$(json_escape "$dp")" "$ds" "$dh" "$dist")
        done
        j+=']}'
        JSON_GROUPS+=("$j")
    fi

    # ---- planned actions
    for e in "${dlist[@]}"; do
        rest="${e#*$'\t'}"; rest="${rest#*$'\t'}"; dp="$rest"
        if [[ -n "$MOVE_DIR" ]]; then
            ACTIONS+=("MOVE|$dp")
        elif [[ "$DO_DELETE" -eq 1 ]]; then
            ACTIONS+=("DELETE|$dp")
        fi
    done
}

declare -a JSON_GROUPS=()
prev_gid=""
buf=""
while IFS=$'\t' read -r gid h s p; do
    if [[ -n "$prev_gid" && "$gid" != "$prev_gid" ]]; then
        report_group "$prev_gid" <<< "$buf"
        buf=""
    fi
    prev_gid="$gid"
    buf+="${h}"$'\t'"${s}"$'\t'"${p}"$'\n'
done < "$GROUPED"
[[ -n "$buf" ]] && report_group "$prev_gid" <<< "$buf"

# ------------------------------------------------------------- output ---
if [[ "$AS_JSON" -eq 1 ]]; then
    printf '{"tool":"%s","version":"%s","threshold":%d,"scanned":%d,"groups":[' \
        "$PROG" "$VERSION" "$THRESHOLD" "$scanned"
    for (( i=0; i<${#JSON_GROUPS[@]}; i++ )); do
        (( i )) && printf ','
        printf '%s' "${JSON_GROUPS[$i]}"
    done
    printf '],"summary":{"duplicate_groups":%d,"duplicate_files":%d,"reclaimable_bytes":%d}}\n' \
        "$group_count" "$dupe_files" "$reclaim"
elif [[ "$QUIET" -eq 1 ]]; then
    printf 'scanned=%d groups=%d duplicates=%d reclaimable=%s\n' \
        "$scanned" "$group_count" "$dupe_files" "$(human "$reclaim")"
else
    printf '\n%sScanned %d image(s): %d duplicate group(s), %d duplicate file(s), %s reclaimable.%s\n' \
        "$C_BOLD" "$scanned" "$group_count" "$dupe_files" "$(human "$reclaim")" "$C_RESET"
    (( skipped > 0 )) && printf '%s(%d file(s) skipped: undecodable or too small)%s\n' "$C_DIM" "$skipped" "$C_RESET"
fi

# ------------------------------------------------------------- action ---
if (( ${#ACTIONS[@]} > 0 )); then
    if [[ "$CONFIRM" -eq 0 ]]; then
        [[ "$AS_JSON" -eq 0 ]] && {
            echo
            echo "DRY-RUN: ${#ACTIONS[@]} file(s) would be $(
                [[ -n "$MOVE_DIR" ]] && echo "moved to $MOVE_DIR" || echo "deleted"
            ). Re-run with --yes to apply."
        }
    else
        [[ -n "$MOVE_DIR" ]] && mkdir -p "$MOVE_DIR"
        for a in "${ACTIONS[@]}"; do
            kind="${a%%|*}"; src="${a#*|}"
            if [[ "$kind" == "MOVE" ]]; then
                base=$(basename "$src")
                dst="$MOVE_DIR/$base"
                if [[ -e "$dst" ]]; then
                    stem="${base%.*}"; ext="${base##*.}"
                    [[ "$stem" == "$ext" ]] && ext=""
                    i=2
                    while :; do
                        cand="$MOVE_DIR/${stem}-${i}${ext:+.$ext}"
                        [[ -e "$cand" ]] || { dst="$cand"; break; }
                        i=$((i+1))
                    done
                fi
                mv -- "$src" "$dst" && [[ "$AS_JSON" -eq 0 ]] && echo "moved: $src -> $dst"
            else
                rm -- "$src" && [[ "$AS_JSON" -eq 0 ]] && echo "deleted: $src"
            fi
        done
    fi
fi

if [[ "$FAIL_ON_DUPES" -eq 1 && "$group_count" -gt 0 ]]; then
    exit 4
fi
exit 0
