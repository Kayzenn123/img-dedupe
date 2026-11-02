# img-dedupe

> Find near-duplicate images in a folder via perceptual hashing — one bash file, ffmpeg only. Daily Tools #27.

## Why

Photo folders rot: burst shots, "Screenshot (2).png", the same meme forwarded
through WhatsApp three times at three different JPEG qualities. Exact-hash
dedupers (`fdupes`) miss all of these because one recompressed byte changes the
whole hash; the tools that do catch them (`knjcode/imgdupes`, `czkawka`) are a
Python project or a heavyweight GUI. `img-dedupe` is a single ~330-line bash
script with zero dependencies besides `ffmpeg`: it decodes every image to 8x8
grayscale, builds a 64-bit average hash (aHash), and groups images whose hashes
differ by at most N bits (Hamming distance). File-changing actions are dry-run
by default, output is a human table plus `--json`, and exit codes are
CI-friendly.

## Install

```bash
git clone https://github.com/Kayzenn123/img-dedupe.git
cd img-dedupe
chmod +x img-dedupe.sh
# optional: put it on PATH
sudo cp img-dedupe.sh /usr/local/bin/img-dedupe
```

Requires: `ffmpeg` on PATH (any recent version), Bash 4+. No other
dependencies. Fully offline — nothing is uploaded anywhere.

## Usage

```bash
img-dedupe [OPTIONS] [DIR]...
img-dedupe [OPTIONS] < filelist.txt   # read image paths from stdin
```

| Flag | Purpose | Default |
|---|---|---|
| `-t, --threshold N` | max Hamming distance to count as duplicate | `5` |
| `--max-depth N` | limit directory recursion | unlimited |
| `--min-size BYTES` | skip files smaller than BYTES | `0` |
| `--json` | machine-readable JSON output | table |
| `-q, --quiet` | print only the summary line | off |
| `--move DIR` | move duplicates (not the kept file) into DIR | off |
| `--delete` | delete duplicates (not the kept file) | off |
| `-y, --yes` | actually apply `--move` / `--delete` | dry-run |
| `--fail-on-dupes` | exit `4` when any duplicate group is found | off |
| `--no-color` | disable colors (`NO_COLOR` env also honored) | auto |

The kept file of each group is the largest one (ties: alphabetically first
path). Exit codes: `0` ok, `1` runtime error, `2` bad usage, `4` duplicates
found (with `--fail-on-dupes`).

## Example output

Command:

```bash
img-dedupe scenarios/photo-dump
```

Output (real, copied from an actual run):

```text
Group 1 — 5 files, 4 duplicate(s), 46.8 KB reclaimable
  KEEP  38.1 KB  scenarios/photo-dump/wa-forward.jpg
  DUPE  27.4 KB  (dist 0) scenarios/photo-dump/wa-forward-low.jpg
  DUPE  7.3 KB  (dist 0) scenarios/photo-dump/IMG_20261102_100802.png
  DUPE  6.1 KB  (dist 0) scenarios/photo-dump/IMG_20261102_100801.png
  DUPE  6.1 KB  (dist 0) scenarios/photo-dump/Screenshot 2026-11-02 at 10.08.03.png

Scanned 7 image(s): 1 duplicate group(s), 4 duplicate file(s), 46.8 KB reclaimable.
```

The folder held one photo saved five ways: original PNG, a brightness-tweaked
copy, a renamed copy, and two WhatsApp-style JPEG recompressions. All five
landed at Hamming distance 0; two genuinely different images in the same folder
were correctly left alone. Dry-run is the default for destructive actions:

```text
$ img-dedupe --move ./dupes scenarios/photo-dump
...
DRY-RUN: 4 file(s) would be moved to ./dupes. Re-run with --yes to apply.
```

JSON mode (`--json`) emits the same groups machine-readably, including each
file's hash and its distance to the kept file.

## How it works

1. `find` collects image files (jpg/jpeg/png/webp/bmp/tif/tiff/gif, recursive).
2. Each image is decoded with
   `ffmpeg -vf "scale=8:8:flags=bilinear,format=gray" -f rawvideo` to 64 gray
   bytes; the mean of the 64 bytes becomes the threshold for a 64-bit aHash.
3. All hashes go through one `awk` pass doing union-find over pairwise Hamming
   distances (O(n^2) comparisons, but each is a 64-char string compare —
   instant for a few thousand files).
4. Groups are sorted by size (desc) then path; the first member is kept.
5. `--move` / `--delete` act only on non-kept members, and only with `--yes`.

Undecodable files are skipped with a warning on stderr; the scan never aborts
on a single bad file.

## Limitations

- aHash is coarse by design: heavily edited variants (big crops, rotations,
  filters) may exceed the threshold, and two visually similar-but-different
  photos (e.g. two near-identical product shots) can hash closely — always
  review the table before `--yes`.
- Filenames containing tab or newline characters are skipped (rare, but noted).
- Symlinked files are not followed (`find -type f`).
- Animated GIFs are hashed on their first frame only.
- Pairwise comparison is O(n^2); fine for thousands of images, not millions.

## Development

```bash
bash test/test.sh   # 18 tests, fixtures generated with ffmpeg lavfi
```

## License

MIT

---
Ringkasan (Bahasa Indonesia): img-dedupe mencari gambar yang sama atau nyaris
sama di dalam folder memakai perceptual hashing (aHash 64-bit) — cukup satu
file bash dan `ffmpeg`, tanpa dependensi lain, dan 100% offline. Duplikat
seperti burst shot, copy rename, atau foto yang dikompres ulang WhatsApp
terdeteksi walau hash byte-nya beda. File pengubah (`--move`/`--delete`)
default-nya dry-run; tambah `--yes` untuk eksekusi beneran. Batasan utama:
hash-nya kasar, jadi varian yang diedit berat bisa lolos dan selalu cek tabel
dulu sebelum hapus.
