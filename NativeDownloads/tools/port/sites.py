"""Collect the native sites of a Pixie target profile with their windows for matching."""
import json, sys
def sites(profile_path):
    p = json.load(open(profile_path))
    n = p["native"]
    out = []   # (name, addr, length_bytes, kind) kind: 'func' (window starts at addr) or 'mid' (context both sides)
    def add(name, addr, hexbytes, kind):
        out.append((name, int(addr, 16), max(4, len(hexbytes) // 2), kind))
    add("setter", n["setter"], n["setter_original"], "func")
    add("window", n["window"], n["window_original"], "mid")
    add("provider", n["provider"], n["provider_head"], "func")
    add("mapping", n["mapping"], n["mapping_original"], "mid")
    add("dlsym_stub", n["dlsym_stub"], n["dlsym_stub_head"], "func")
    add("render_callback", n["render_callback"], "00" * 4, "func")
    for t in p["trace_points"]:
        add("trace_" + t["name"], t["address"], t["original"], "func" if t["kind"] else "mid")
    for k, v in p["export"]["points"].items():
        add("point_" + k, v["address"], v["original"], "func")
    for k, v in p["export"]["windows"].items():
        add("win_" + k, v["address"], v["bytes"], "mid")
    return p, out
if __name__ == "__main__":
    p, s = sites(sys.argv[1])
    for x in s: print(x[0], hex(x[1]), x[2], x[3])
