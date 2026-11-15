"""Write targets/spotify-9.2.0.json from the 9.1.98 profile and the sites located in the 9.2.0 binary.

Every address below was found by structure against the 9.1.98 binary (see PORT-9.2.0.md) and the
original bytes are read from the 9.2.0 binary itself, so the build guards compare against real code.
usage: make_profile.py <9.2.0 Spotify binary> <9.1.98 Spotify binary> <out.json>
"""
import json, struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from macho import Macho

NEW_SITES = {
    "setter": 0x1022d7c88, "manager_vtable": 0x10d9c3c08, "window": 0x106140930, "call_site": 0x10614093c,
    "provider": 0x100dc8438, "mapping": 0x100dc849c, "dlsym_stub": 0x10a7bc268, "render_callback": 0x10665852c,
    "trace": {"Request": 0x10614093c, "Success": 0x106ae0060, "Failure": 0x10635feb8},
    "points": {"CacheKey": 0x10559a704, "StreamKey": 0x10985aad8, "CacheCipher": 0x101a51d8c,
               "CacheCipherApple": 0x1027929f4, "MediaKeyPath": 0x1061407a4, "MediaKeyBlob": 0x10774139c,
               "MediaContext": 0x10503253c, "MediaRecord": 0x10774142c, "UnsealedMediaKey": 0x1059344f4},
    "windows": {"layout0": 0x106ae0070, "layout1": 0x108bce298, "layout2": 0x10a75e9b8, "layout3": 0x10a75eb0c,
                "cache_storage_owner": 0x10a5c828c, "unseal_guard": 0x1059344ec, "unseal_caller": 0x1077413fc,
                "share_wrapper_guard": 0x100659c6c, "share_constructor_guard": 0x1025dda90,
                "cache_key_body": 0x10559a714},
}
FAR_CAVES = {"StreamKey": 0x10d11f000}          # too far from the header caves (> 128 MiB)
SELECTOR_CAVE = 0x10d11f600

def h(v): return "0x%x" % v

def main(new_path, old_path, out_path):
    new, old = Macho(new_path), Macho(old_path)
    p = json.load(open(os.path.join(os.path.dirname(__file__), "../../targets/spotify-9.1.98.json")))
    uuid = None
    d, off = new.data, 32
    ncmds = struct.unpack_from("<I", d, 16)[0]
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x1b: uuid = d[off+8:off+24].hex()
        off += size
    p["id"] = "eevee-spotify-9.2.0-pixie-1.4"; p["spotify_version"] = "9.2.0"; p["spotify_build"] = "920002054"
    p["uuid"] = uuid; p["eevee_version"] = "7.0.1"
    n = p["native"]
    sz = {k: len(bytes.fromhex(n[k])) for k in ("setter_original", "window_original", "provider_head", "mapping_original", "dlsym_stub_head")}
    n["setter"] = h(NEW_SITES["setter"]); n["setter_original"] = new.read(NEW_SITES["setter"], sz["setter_original"]).hex()
    n["manager_vtable"] = h(NEW_SITES["manager_vtable"])
    n["window"] = h(NEW_SITES["window"]); n["window_original"] = new.read(NEW_SITES["window"], sz["window_original"]).hex()
    n["call_site"] = h(NEW_SITES["call_site"])
    n["provider"] = h(NEW_SITES["provider"]); n["provider_head"] = new.read(NEW_SITES["provider"], len(bytes.fromhex(n["provider_head"]))).hex()
    n["mapping"] = h(NEW_SITES["mapping"]); n["mapping_original"] = new.read(NEW_SITES["mapping"], sz["mapping_original"]).hex()
    n["dlsym_stub"] = h(NEW_SITES["dlsym_stub"]); n["dlsym_stub_head"] = new.read(NEW_SITES["dlsym_stub"], sz["dlsym_stub_head"]).hex()
    n["render_callback"] = h(NEW_SITES["render_callback"])
    n["selector_cave"] = h(SELECTOR_CAVE)
    for t in p["trace_points"]:
        t["address"] = h(NEW_SITES["trace"][t["name"]])
        if t["name"] != "Request": t["original"] = new.read(NEW_SITES["trace"][t["name"]], len(bytes.fromhex(t["original"]))).hex()
        t.pop("cave", None)
        t["cave"] = {"Request": "0x100023700", "Success": "0x100023900", "Failure": "0x100023b00"}[t["name"]]
    for k, v in p["export"]["points"].items():
        v["address"] = h(NEW_SITES["points"][k]); v["original"] = new.read(NEW_SITES["points"][k], len(bytes.fromhex(v["original"]))).hex()
        v.pop("cave", None)
        if k in FAR_CAVES: v["cave"] = h(FAR_CAVES[k])
    for k, v in p["export"]["windows"].items():
        v["address"] = h(NEW_SITES["windows"][k]); v["bytes"] = new.read(NEW_SITES["windows"][k], len(bytes.fromhex(v["bytes"]))).hex()
    p["export"]["comment"] = ("Spotify 9.2.0 (Eevee 7.0.1 Patched build) sites located by structure against the 9.1.98 binary: "
                              "call-graph anchors (request callback constructors, vtable slot 65, dlsym import) and normalised ARM64 matching; see PORT-9.2.0.md.")
    json.dump(p, open(out_path, "w"), indent=2); open(out_path, "a").write("\n")
    print("wrote", out_path, "uuid", uuid)

if __name__ == "__main__":
    main(*sys.argv[1:4])
