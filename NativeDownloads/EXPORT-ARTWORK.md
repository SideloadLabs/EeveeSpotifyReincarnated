# Embedded export artwork

An explicit audio export resolves the cover from Track.album or the requested album metadata. A missing nested cover falls back to one album metadata read per export job. The existing cancellable native image service requests up to 640 pixels; JPEG conversion runs on a utility queue. Artwork is retained only by the current job and reused across album tracks. Larger export images do not enter the UI thumbnail cache. Cancellation suppresses late image callbacks.

The exported Ogg receives a JPEG front cover in `METADATA_BLOCK_PICTURE`. Existing vendor and non-picture comments are preserved. Existing picture tags are replaced. Audio and setup packets are unchanged; pages receive updated sequence numbers and CRCs. The tagged output must pass the production Ogg and duration validator before atomic replacement. Unavailable/invalid artwork leaves the validated audio export intact. Diagnostics record image resolution and actual embedding results, without image bytes or keys. Spotify cache files stay read-only.

Formats: [Vorbis comments](https://xiph.org/vorbis/doc/v-comment.html), [picture tag](https://wiki.xiph.org/VorbisComment), [FLAC picture block, section 8.8](https://www.rfc-editor.org/rfc/rfc9639.html#section-8.8).

Verification: `python3 NativeDownloads/tools/test_ogg_artwork.py`, `python3 NativeDownloads/tools/test_audio_export.py`, and export metadata/workflow fixtures. Tests use synthetic audio and pictures. Actual iPhone export and cover display still require user verification; Ogg artwork display depends on the receiving player.

## Native share-sheet preview

Physical-device evidence in `.work/cover-failure-20261101-001` confirms both cover1 exports contain the picture. The downloaded file passes independent ffprobe inspection: Vorbis audio plus a 640 x 640 MJPEG attached picture. The blank share-sheet file icon came from passing only NSURL values to UIActivityViewController, without preview metadata.

Audio exports now wrap each file in UIActivityItemSource with LPLinkMetadata imageProvider/iconProvider and the activity thumbnail callback. Every activity still receives the original audio file URL. No separate JPEG is shared, no content type is falsified, and no new artwork fetch occurs during sharing. The existing image is retained with that URL only while the export/share objects live; there is no persistent preview cache. Diagnostic log sharing continues to use its original URL path.

This changes the native export share preview. It cannot force Files or other receiving applications to render embedded Ogg artwork after saving; those apps control their own file thumbnails. The audio file continues to contain its standard embedded picture.
