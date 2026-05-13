#ifndef FFmpegBridging_h
#define FFmpegBridging_h

// Imports the LGPL FFmpeg 7.1.1 decoder API for use from Swift.
// The static libraries themselves live in Vendor/ffmpeg/lib.

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

// SQLite C API for the Phase B vector index (IndexStore.swift).
#include <sqlite3.h>

#endif /* FFmpegBridging_h */
