"""Rank candidate 9.2.0 locations of the 9.1.92 / 9.1.98 sites by exact original bytes and normalised similarity."""
import json, sys, struct, os
S = os.environ.get("PORT_WORK", os.getcwd())
TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from macho import Macho
from sites import sites

def norm(w):
    if (w & 0x9f000000) == 0x90000000: return w & 0x9f00001f
    if (w & 0x9f000000) == 0x10000000: return w & 0x9f00001f
    if (w & 0x7c000000) == 0x14000000: return w & 0xfc000000
    if (w & 0xff000010) == 0x54000000: return w & 0xff00001f
    if (w & 0x7e000000) == 0x34000000: return w & 0xff00001f
    if (w & 0x7e000000) == 0x36000000: return w & 0xfff8001f
    if (w & 0x3b000000) == 0x18000000: return w & 0xff00001f
    if (w & 0x1f000000) == 0x11000000: return w & 0xff8003ff
    if (w & 0x3b000000) == 0x39000000: return w & 0xffc003ff
    return w

def words(m, addr, n):
    return list(struct.unpack("<%dI" % n, m.read(addr, 4 * n)))

def rank(refname, refpath, profile, resultjson, new):
    ref = Macho(refpath)
    _, items = sites(profile)
    meta = {n: (a, l, k) for n, a, l, k in items}
    res = json.load(open(resultjson))
    out = {}
    for name, cands in res.items():
        addr, length, kind = meta[name]
        before = 0 if (kind == "func" and length > 4) else 40
        total = 200 if before == 0 else 40 + max(1, length // 4) + 70
        ow = words(ref, addr - before * 4, total)
        on = [norm(w) for w in ow]
        scored = []
        for votes, ngr, a in cands[:4]:
            a = int(a, 16)
            best = None
            for shift in range(-24, 25):          # tolerate small insertions before the window
                na = a + shift * 4
                try: nw = words(new, na - before * 4, total)
                except Exception: continue
                same = sum(1 for x, y in zip(on, [norm(w) for w in nw]) if x == y)
                if best is None or same > best[0]: best = (same, shift, na)
            scored.append((best[0] / total, best[1], best[2], votes))
        scored.sort(reverse=True)
        out[name] = scored
    return out

if __name__ == "__main__":
    new = Macho(S + "/pa/Payload/Spotify.app/Spotify")
    from_92 = rank("92", S + "/bin92/Payload/Spotify.app/Spotify", "/Users/glongq/Documents/Codex/eevee pixie fixed/NativeDownloads/targets/spotify-9.1.92.json", S + "/result_92to92x.json", new)
    from_98 = rank("98", S + "/bin98/Payload/Spotify.app/Spotify", "/Users/glongq/Documents/Codex/eevee pixie fixed/NativeDownloads/targets/spotify-9.1.98.json", S + "/result_98to92x.json", new)
    json.dump({"92": {k: [(s, sh, hex(a), v) for s, sh, a, v in r] for k, r in from_92.items()},
               "98": {k: [(s, sh, hex(a), v) for s, sh, a, v in r] for k, r in from_98.items()}}, open(S + "/ranked.json", "w"), indent=1)
    print(f"{'site':28s} {'best vs 92 ref':>26s} {'best vs 98 ref':>26s}")
    for name in from_92:
        a = from_92[name][0]; b = from_98[name][0] if name in from_98 else None
        fa = f"{hex(a[2])} {a[0]*100:3.0f}% (sh{a[1]:+d})"
        fb = f"{hex(b[2])} {b[0]*100:3.0f}% (sh{b[1]:+d})" if b else "-"
        print(f"{name:28s} {fa:>26s} {fb:>26s}  {'SAME' if b and a[2]==b[2] else ''}")
