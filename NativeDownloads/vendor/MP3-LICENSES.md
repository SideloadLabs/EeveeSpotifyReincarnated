# MP3 export third party sources

LAME 4.0 encoder, Copyright The LAME Project: https://lame.sourceforge.io/
Bundled complete, unmodified source: `lame-4.0.tar.gz`.
Primary download: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz
SHA-256: `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb`.
License: GNU Library General Public License, version 2 or later, as stated in
source file headers; full text in `LAME-COPYING` and source archive `COPYING`.
The build disables the mpg123 decoder and command line frontend. Only the
separate static encoder library is linked. No LAME sources are modified.

stb_vorbis 1.22, Copyright Sean Barrett. Unmodified source and full MIT/public-domain
license are in `stb_vorbis.c`. This distribution uses the MIT license option.
Pinned upstream revision: `d14d46f6b44456eb88beac58cba833a4135d4c89`.
Primary source: https://raw.githubusercontent.com/nothings/stb/d14d46f6b44456eb88beac58cba833a4135d4c89/stb_vorbis.c
SHA-256: `4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636`.

For static-link redistribution, retain the complete LAME source archive,
licenses, build helper and application relink materials (objects/link command)
so recipients can substitute a modified LAME library. Packaging the application
must include this notice and license, with source/relink materials available
alongside the release. Merely including a source download link is insufficient
for providing application relink materials.

MP3 export is no longer built: current Pixie does not compile or link LAME.
The former build helper `tools/build_mp3_dependencies.py` and the MP3 tests were
moved out of the repository with the MP3 sources (see git history, commit 2ef29f2
and later).
