# Audio export fixture

`export-tone-10s.ogg` is a generated ten-second Vorbis tone, not device music.
It is the previously generated host fixture with its artificial 167-byte prefix
removed. `test_audio_export.py` adds that prefix and independently encrypts both
the media and storage layers with public synthetic keys. No account material or
captured music is used by these tests.
