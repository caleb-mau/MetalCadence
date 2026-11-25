#pragma once
#include <stdint.h>
#include <stdatomic.h>
#define VC_W 1920
#define VC_H 1080
#define VC_BYTES (VC_W*VC_H*3/2)
#define VC_SLOTS 8
#define VC_AUDIO 800
#define VC_MAGIC 0x5643415054555245ULL
typedef struct {
 _Atomic uint64_t stamp;
 double pts,arrival;
 uint64_t tick;
 uint32_t audioFrames;
 float pcm[VC_AUDIO*2];
 unsigned char pixels[VC_BYTES];
} VCSlot;
typedef struct {
 uint64_t magic;
 _Atomic uint64_t latest,sourceDrops;
 _Atomic uint64_t heartbeat;
 VCSlot slots[VC_SLOTS];
} VCRing;
