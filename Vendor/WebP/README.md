Embedded Google libwebp 1.6.0 decoder/demux, statically built for arm64 macOS 14+. No Homebrew installation or dynamic WebP library is needed to use the app.

Source: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
SHA-256: e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
License: Resources/WebP-LICENSE.txt (BSD).

Use script/rebuild_webp.sh with CMake and Xcode to rebuild for another Mac architecture. The decoder is used for one-time artwork-video preparation; normal animated playback uses AVFoundation.
