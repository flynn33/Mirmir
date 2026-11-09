The downloads directory contains the exact authenticated FFmpeg8.1.2 source archive, signature and original release key. DEPENDENCY-MANIFEST.json in the parent directory pins all source, library, header and recipe bytes. Original upstream copyright/license notices remain in the complete source archive.

To prepare a fresh writable corresponding-source/build tree:
python3 rebuild_ffmpeg.py --package . --output /a/new/local/build-directory

To execute the retained strict-scalar build after preparation, follow the exact commands in the prepared REBUILD-INSTRUCTIONS.txt. Alternatively supply --build during initial preparation. The preparation/extraction path was tested; a new full dependency rebuild from the relocated package is not yet claimed.

To test a replacement ABI-compatible LGPL dynamic library on a fresh local signed app copy:
python3 replace_lgpl_libraries.py --app /path/Mirmir.app --output /new/path/MirmirReplacement.app --replacement-directory /path/to/replacement/libraries --signing-identity YOUR_LOCAL_CODESIGN_IDENTITY

The retained hardened-runtime policy requires a usable code-signing identity for this local replacement test. Ad hoc signatures were observed to fail library validation. The replacement tool preserves the original entitlements, uses no library-validation exception, signs the nested copies and enclosing local app, and never changes the original app. This is a local technical test, not proof of Store-installed replacement behavior or legal compliance. Customer terms were not changed.
