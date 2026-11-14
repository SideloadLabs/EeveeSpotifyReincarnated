"""Exercise dyld's actual dependency resolution without an executable rpath."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from fix_sideload_dependencies import pin_substrate_dependency, substrate_dependencies, PINNED_SUBSTRATE


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True).stdout


with tempfile.TemporaryDirectory(prefix='pixie-dyld-test-') as temporary:
    root = Path(temporary)
    app = root/'Original.app'
    frameworks = app/'Frameworks'
    substrate = frameworks/'CydiaSubstrate.framework/CydiaSubstrate'
    substrate.parent.mkdir(parents=True)
    (root/'substrate.c').write_text('int dependency_value(void) { return 73; }\n')
    (root/'plugin.c').write_text('extern int dependency_value(void); int plugin_value(void) { return dependency_value(); }\n')
    (root/'host.c').write_text('#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) {\n'
        'void *h = dlopen(argv[1], RTLD_NOW); if (!h) { puts(dlerror()); return 80; }\n'
        'int (*f)(void) = dlsym(h, "plugin_value"); return f && f() == 73 ? 0 : 81; }\n')
    run('xcrun', 'clang', '-dynamiclib', root/'substrate.c',
        '-Wl,-install_name,@rpath/CydiaSubstrate.framework/CydiaSubstrate', '-o', substrate)
    plugin = frameworks/'spotifyglass.dylib'
    run('xcrun', 'clang', '-dynamiclib', root/'plugin.c', substrate,
        '-Wl,-install_name,@rpath/spotifyglass.dylib', '-o', plugin)
    host = app/'Host'
    run('xcrun', 'clang', root/'host.c', '-o', host)
    assert 'LC_RPATH' not in run('otool', '-l', host)
    before = subprocess.run([str(host), str(plugin)], capture_output=True, text=True)
    assert before.returncode == 80 and '@rpath/CydiaSubstrate.framework/CydiaSubstrate' in before.stdout
    print('PASS: original dependency fails when the host has no Frameworks rpath')
    assert pin_substrate_dependency(plugin)['text_sections_unchanged']
    run('codesign', '--force', '--sign', '-', '--timestamp=none', plugin)
    run(host, plugin)
    assert substrate_dependencies(plugin) == [PINNED_SUBSTRATE]
    print('PASS: loader-relative dependency loads without any executable rpath')
    assert pin_substrate_dependency(plugin)['before'] == PINNED_SUBSTRATE
    moved = root/'Renamed приложение.app'
    shutil.move(app, moved)
    run(moved/'Host', moved/'Frameworks/spotifyglass.dylib')
    print('PASS: relocated bundle with spaces/non-ASCII still loads; rewrite is idempotent')
    (moved/'Frameworks/CydiaSubstrate.framework/CydiaSubstrate').unlink()
    missing = subprocess.run([str(moved/'Host'), str(moved/'Frameworks/spotifyglass.dylib')], capture_output=True, text=True)
    assert missing.returncode == 80
    print('PASS: genuinely missing framework is reported, not masked as a successful load')
