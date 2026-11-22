"""Write targets/spotify-9.2.2.json from the 9.2.0 profile and the sites located in the 9.2.2 binary.

Every site was found by structure against the 9.2.0 binary (tools/port/run_match.py, then confirmed by
comparing the disassembly and call graph around each site). The original bytes are read from the 9.2.2
binary itself, so the build guards compare against real code.
usage: make_profile_922.py <9.2.2 Spotify binary> <out.json>
"""
import json, struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from macho import Macho

SITES = {
    "setter": 0x1098eb350, "manager_vtable": 0x10d9cc718, "window": 0x1098d06d8, "call_site": 0x1098d06e4,
    "provider": 0x10972d67c, "mapping": 0x10972d6e0, "dlsym_stub": 0x10a868de0, "render_callback": 0x109f58804,
    "trace": {"Request": 0x1098d06e4, "Success": 0x1098d0a10, "Failure": 0x1098d0a98},
    "points": {"CacheKey": 0x1092c36e8, "StreamKey": 0x109ee7bcc, "CacheCipher": 0x10936b554,
               "CacheCipherApple": 0x10936b8a8, "MediaKeyPath": 0x1098d054c, "MediaKeyBlob": 0x10993139c,
               "MediaContext": 0x109361888, "MediaRecord": 0x10993142c, "UnsealedMediaKey": 0x109362d60},
    "windows": {"layout0": 0x1098d0a20, "layout1": 0x1098d08bc, "layout2": 0x10a7bc700, "layout3": 0x10a7bc844,
                "cache_storage_owner": 0x1092c1888, "unseal_guard": 0x109362d58, "unseal_caller": 0x1099313fc,
                "share_wrapper_guard": 0x100ed2b88, "share_constructor_guard": 0x100ed2fac,
                "cache_key_body": 0x1092c36f8},
}
# Every patched site is now ~160 MB from the header padding, beyond the +-128 MiB range of a branch, so the
# code caves live in the zero padding after the last __TEXT section (see CAVES below). Addresses are
# assigned by tools/port/assign_caves.py from the real trampoline sizes.
CAVES = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "caves_9.2.2.json")))

def h(v): return "0x%x" % v

def main(new_path, out_path):
    new = Macho(new_path)
    p = json.load(open(os.path.join(os.path.dirname(__file__), "../../targets/spotify-9.2.0.json")))
    uuid = None
    d, off = new.data, 32
    for _ in range(struct.unpack_from("<I", d, 16)[0]):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x1b: uuid = d[off+8:off+24].hex()
        off += size
    p["id"] = "eevee-spotify-9.2.2-pixie-1.4"; p["spotify_version"] = "9.2.2"; p["spotify_build"] = "920202587"
    p["uuid"] = uuid
    n = p["native"]
    sz = {k: len(bytes.fromhex(n[k])) for k in ("setter_original", "window_original", "provider_head", "mapping_original", "dlsym_stub_head")}
    n["setter"] = h(SITES["setter"]); n["setter_original"] = new.read(SITES["setter"], sz["setter_original"]).hex()
    n["setter_cave"] = CAVES["setter_cave"]
    n["manager_vtable"] = h(SITES["manager_vtable"])
    n["window"] = h(SITES["window"]); n["window_original"] = new.read(SITES["window"], sz["window_original"]).hex()
    n["call_site"] = h(SITES["call_site"])
    n["provider"] = h(SITES["provider"]); n["provider_head"] = new.read(SITES["provider"], sz["provider_head"]).hex()
    n["mapping"] = h(SITES["mapping"]); n["mapping_original"] = new.read(SITES["mapping"], sz["mapping_original"]).hex()
    n["dlsym_stub"] = h(SITES["dlsym_stub"]); n["dlsym_stub_head"] = new.read(SITES["dlsym_stub"], sz["dlsym_stub_head"]).hex()
    n["render_callback"] = h(SITES["render_callback"])
    n["selector_cave"] = CAVES["selector_cave"]
    # The quota counters moved with the rest of the manager's fields from +0x238 on: +0x80 over 9.2.0.
    n["manager_field_shift"] = 8 + 0x80
    # Four slots were added before it: the setter's vtable slot is 69 (it was 65).
    n["manager_setter_slot"] = 69
    for t in p["trace_points"]:
        t["address"] = h(SITES["trace"][t["name"]])
        # The Request boundary is the call site the key-mode patch has already rewritten to "mov w2, #0".
        if t["name"] != "Request": t["original"] = new.read(SITES["trace"][t["name"]], len(bytes.fromhex(t["original"]))).hex()
        t["cave"] = CAVES["trace"][t["name"]]
    for k, v in p["export"]["points"].items():
        v["address"] = h(SITES["points"][k]); v["original"] = new.read(SITES["points"][k], len(bytes.fromhex(v["original"]))).hex()
        v["cave"] = CAVES["points"][k]
    for k, v in p["export"]["windows"].items():
        v["address"] = h(SITES["windows"][k]); v["bytes"] = new.read(SITES["windows"][k], len(bytes.fromhex(v["bytes"]))).hex()
    p["export"]["cave_base"] = CAVES["cave_base"]
    p["export"]["comment"] = ("Spotify 9.2.2 sites located by structure against the 9.2.0 binary "
                              "(normalised ARM64 matching, then call-graph and disassembly checks); every cave is in the "
                              "zero padding after the last __TEXT section, the header padding being out of branch range.")
    json.dump(p, open(out_path, "w"), indent=2); open(out_path, "a").write("\n")
    print("wrote", out_path, "uuid", uuid)

if __name__ == "__main__":
    main(*sys.argv[1:3])
