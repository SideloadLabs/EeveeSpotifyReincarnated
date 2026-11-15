#pragma once
#include "ExportCancellation.h"
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

// JPEG front cover, encoded as the standard Vorbis METADATA_BLOCK_PICTURE tag.
// The source remains read-only. Codec/audio packets and granules are preserved.
int SAPWriteOggWithArtwork(FILE *source,uint64_t offset,uint64_t length,FILE *output,
                          const uint8_t *jpeg,size_t jpegLength,uint32_t width,uint32_t height);

int SAPWriteOggWithArtworkCancellable(FILE *source,uint64_t offset,uint64_t length,FILE *output,const uint8_t *jpeg,size_t jpegLength,uint32_t width,uint32_t height,SAPExportContinue keepGoing,void *context);
