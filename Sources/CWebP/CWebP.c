#include "CWebP.h"
#include "webp/demux.h"
#include <stdlib.h>
#include <string.h>
struct CartridgeWebP {
    WebPAnimDecoder *decoder;
    WebPAnimInfo info;
    uint8_t *data;
    int timestamp;
};
CartridgeWebP *CartridgeWebPCreate(const uint8_t *bytes, size_t length) {
    CartridgeWebP *result = calloc(1, sizeof(*result));
    if (!result) return NULL;
    result->data = malloc(length);
    if (!result->data) { free(result); return NULL; }
    memcpy(result->data, bytes, length);
    WebPData data = {result->data, length};
    WebPAnimDecoderOptions options;
    if (!WebPAnimDecoderOptionsInit(&options)) { CartridgeWebPDelete(result); return NULL; }
    options.color_mode = MODE_bgrA; // Premultiplied BGRA, directly compatible with CoreGraphics.
    options.use_threads = 0; // Small cover images; avoid spinning up one thread per frame.
    result->decoder = WebPAnimDecoderNew(&data, &options);
    if (!result->decoder || !WebPAnimDecoderGetInfo(result->decoder, &result->info) ||
        result->info.canvas_width > 8192 || result->info.canvas_height > 8192) {
        CartridgeWebPDelete(result); return NULL;
    }
    return result;
}
void CartridgeWebPDelete(CartridgeWebP *decoder) {
    if (!decoder) return;
    if (decoder->decoder) WebPAnimDecoderDelete(decoder->decoder);
    free(decoder->data); free(decoder);
}
int CartridgeWebPWidth(CartridgeWebP *decoder) { return decoder ? decoder->info.canvas_width : 0; }
int CartridgeWebPHeight(CartridgeWebP *decoder) { return decoder ? decoder->info.canvas_height : 0; }
int CartridgeWebPFrameCount(CartridgeWebP *decoder) { return decoder ? decoder->info.frame_count : 0; }
const uint8_t *CartridgeWebPNext(CartridgeWebP *decoder, int *duration_ms) {
    if (!decoder) return NULL;
    if (!WebPAnimDecoderHasMoreFrames(decoder->decoder)) {
        WebPAnimDecoderReset(decoder->decoder); decoder->timestamp = 0;
    }
    uint8_t *buffer = NULL; int timestamp = 0;
    if (!WebPAnimDecoderGetNext(decoder->decoder, &buffer, &timestamp)) return NULL;
    *duration_ms = timestamp - decoder->timestamp;
    decoder->timestamp = timestamp;
    return buffer;
}
