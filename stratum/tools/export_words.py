"""Builds Holo's meaning table (models/holo-words.bin) from ConceptNet
Numberbatch 19.08 (English), which is trained for word relatedness
("datacenter" near "region", "login" near "authentication").

    pip install wordfreq numpy
    curl -O https://conceptnet.s3.amazonaws.com/downloads/2019/numberbatch/numberbatch-en-19.08.txt.gz
    python tools/export_words.py numberbatch-en-19.08.txt.gz models/holo-words.bin

Numberbatch is CC BY-SA 4.0 (ConceptNet 5, Speer, Chin and Havasi 2017);
so is the table built from it.

Words are stemmed exactly like src/holo/text.zig, merged per stem
(frequency weighted), reduced to DIMS dimensions and stored as int8. Each
stem also gets its NBRS nearest neighbours, computed on the full vectors.

File layout (little endian):
    "HOLOWV1\\0"  u32 count  u16 dims  u16 nbrs
    count x (u8 len, bytes)                 stems
    count x dims x i8                       vectors, unit length * 127
    count x nbrs x (u16 index, u8 sim*255)  neighbours, index 0xFFFF = none
"""

import gzip
import os
import struct
import sys

import numpy as np
import wordfreq

TOP_WORDS = 80_000
MAX_STEMS = 50_000
DIMS = int(os.environ.get("HOLO_DIMS", "300"))
NBRS = 8
MIN_SIM = 0.35

STOP = set(
    "a an and are as at be but by can did do does for from had has have he her his how i if in into is it its me my no not of on or our she so that the their them then there these they this to too us was we were what when where which who why will with would you your should could about please just".split()
)


def stem(w: str) -> str:
    if len(w) > 5 and w.endswith("ing"):
        return w[:-3]
    if len(w) > 4 and w.endswith("ies"):
        return w[:-3] + "y"
    if len(w) > 4 and w.endswith("ed"):
        return w[:-2]
    if len(w) > 3 and w[-1] == "s" and w[-2] not in "sui":
        return w[:-1]
    return w


def load_vectors(path: str, want: set[str]) -> dict[str, np.ndarray]:
    vecs = {}
    with gzip.open(path, "rt", encoding="utf-8") as f:
        next(f)
        for line in f:
            w, rest = line.split(" ", 1)
            if w in want:
                vecs[w] = np.array(rest.split(), dtype=np.float32)
    return vecs


def main(src: str, out_path: str) -> None:
    top = wordfreq.top_n_list("en", TOP_WORDS)
    vecs = load_vectors(src, set(top))
    groups: dict[str, list[tuple[float, np.ndarray]]] = {}
    order: list[str] = []
    for w in top:
        if not w.isascii() or not w.isalnum() or len(w) < 2 or len(w) > 32 or w in STOP:
            continue
        if w not in vecs:
            continue
        s = stem(w)
        if s not in groups:
            groups[s] = []
            order.append(s)
        groups[s].append((wordfreq.word_frequency(w, "en"), vecs[w]))
    order = order[:MAX_STEMS]
    full = np.zeros((len(order), len(next(iter(vecs.values())))), dtype=np.float32)
    for i, s in enumerate(order):
        tot = sum(f for f, _ in groups[s])
        v = sum(f * vec for f, vec in groups[s]) / tot
        full[i] = v / (np.linalg.norm(v) + 1e-9)

    # Neighbours on the full vectors, in chunks.
    n = len(order)
    nbr_idx = np.full((n, NBRS), 0xFFFF, dtype=np.uint16)
    nbr_sim = np.zeros((n, NBRS), dtype=np.uint8)
    for start in range(0, n, 2048):
        sims = full[start : start + 2048] @ full.T
        for r in range(sims.shape[0]):
            sims[r, start + r] = -1
        top = np.argpartition(-sims, NBRS, axis=1)[:, :NBRS]
        for r in range(sims.shape[0]):
            cand = sorted(top[r], key=lambda j: -sims[r, j])
            k = 0
            for j in cand:
                if sims[r, j] < MIN_SIM:
                    break
                nbr_idx[start + r, k] = j
                nbr_sim[start + r, k] = int(round(float(sims[r, j]) * 255))
                k += 1

    # Smaller vectors for sentence similarity: SVD, then unit length, int8.
    # No centering: Numberbatch is already debiased, and centering it
    # loses some of its relatedness.
    _, _, vt = np.linalg.svd(full, full_matrices=False)
    red = full @ vt[:DIMS].T
    red /= np.linalg.norm(red, axis=1, keepdims=True) + 1e-9
    q = np.clip(np.round(red * 127), -127, 127).astype(np.int8)

    with open(out_path, "wb") as f:
        f.write(b"HOLOWV1\0")
        f.write(struct.pack("<IHH", n, DIMS, NBRS))
        for s in order:
            b = s.encode()
            f.write(struct.pack("<B", len(b)))
            f.write(b)
        f.write(q.tobytes())
        for i in range(n):
            for k in range(NBRS):
                f.write(struct.pack("<HB", int(nbr_idx[i, k]), int(nbr_sim[i, k])))
    print(f"{n} stems, {DIMS} dims, written to {out_path}")
    for w in ["login", "deploy", "outage", "datacenter", "invoice", "backup"]:
        s = stem(w)
        if s in groups:
            i = order.index(s)
            print(w, "->", [(order[j], round(nbr_sim[i, k] / 255, 2)) for k, j in enumerate(nbr_idx[i]) if j != 0xFFFF])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
