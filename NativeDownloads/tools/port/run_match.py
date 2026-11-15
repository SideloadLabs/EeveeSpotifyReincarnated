import sys, subprocess, json, os
S = os.environ.get("PORT_WORK", os.getcwd())
TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from macho import Macho
from sites import sites

def run(old_path, new_path, profile_path, label):
    old, new = Macho(old_path), Macho(new_path)
    _, items = sites(profile_path)
    lines, meta = [], {}
    for name, addr, length, kind in items:
        if name == "dlsym_stub": continue
        if kind == "func" and length > 4:
            before, total = 0, 200
        else:
            before, total = 40, 40 + max(1, length // 4) + 70
        start = addr - before * 4
        try: off = old.v2f(start)
        except ValueError: continue
        lines.append(f"{name} {off} {total}")
        meta[name] = (addr, before, total)
    qf = S + f"/queries_{label}.txt"
    open(qf, "w").write("\n".join(lines) + "\n")
    t = new.sections[("__TEXT", "__text")]
    ot = old.sections[("__TEXT", "__text")]
    out = subprocess.run([TOOLS + "/match", old_path, str(ot[2]), new_path, str(t[2]), str(t[1]), qf],
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for ln in out.splitlines():
        name, ngr, off, votes = ln.split()
        addr, before, total = meta[name]
        res.setdefault(name, []).append((int(votes), ngr, new.f2v(int(off)) + before * 4))
    return res, meta

if __name__ == "__main__":
    res, meta = run(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    json.dump({k: [(v, int(g), hex(a)) for v, g, a in r] for k, r in res.items()}, open(S + f"/result_{sys.argv[4]}.json", "w"), indent=1)
    for name, r in res.items():
        top = r[0]; second = r[1][0] if len(r) > 1 else 0
        print(f"{name:28s} old {hex(meta[name][0]):>12s} -> new {hex(top[2]):>12s} votes {top[0]:4d}/{int(top[1]):4d}  next {second}")
