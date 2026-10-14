#ifndef CARTRIDGES_WEBP_H
#define CARTRIDGES_WEBP_H
#include <stddef.h>
#include <stdint.h>
typedef struct CartridgeWebP CartridgeWebP;
CartridgeWebP *CartridgeWebPCreate(const uint8_t *bytes, size_t length);
void CartridgeWebPDelete(CartridgeWebP *decoder);
int CartridgeWebPWidth(CartridgeWebP *decoder);
int CartridgeWebPHeight(CartridgeWebP *decoder);
int CartridgeWebPFrameCount(CartridgeWebP *decoder);
const uint8_t *CartridgeWebPNext(CartridgeWebP *decoder, int *duration_ms);
#endif
