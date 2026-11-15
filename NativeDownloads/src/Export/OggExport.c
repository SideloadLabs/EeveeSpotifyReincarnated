#include "OggExport.h"
#include <string.h>
#include <limits.h>
#include <stdlib.h>
static uint32_t le32(const unsigned char *p) {return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t le64(const unsigned char *p) {return le32(p)|(uint64_t)le32(p+4)<<32;}
static const uint32_t crcTable[256]={0x00000000,0x04c11db7,0x09823b6e,0x0d4326d9,0x130476dc,0x17c56b6b,0x1a864db2,0x1e475005,0x2608edb8,0x22c9f00f,0x2f8ad6d6,0x2b4bcb61,0x350c9b64,0x31cd86d3,0x3c8ea00a,0x384fbdbd,0x4c11db70,0x48d0c6c7,0x4593e01e,0x4152fda9,0x5f15adac,0x5bd4b01b,0x569796c2,0x52568b75,0x6a1936c8,0x6ed82b7f,0x639b0da6,0x675a1011,0x791d4014,0x7ddc5da3,0x709f7b7a,0x745e66cd,0x9823b6e0,0x9ce2ab57,0x91a18d8e,0x95609039,0x8b27c03c,0x8fe6dd8b,0x82a5fb52,0x8664e6e5,0xbe2b5b58,0xbaea46ef,0xb7a96036,0xb3687d81,0xad2f2d84,0xa9ee3033,0xa4ad16ea,0xa06c0b5d,0xd4326d90,0xd0f37027,0xddb056fe,0xd9714b49,0xc7361b4c,0xc3f706fb,0xceb42022,0xca753d95,0xf23a8028,0xf6fb9d9f,0xfbb8bb46,0xff79a6f1,0xe13ef6f4,0xe5ffeb43,0xe8bccd9a,0xec7dd02d,0x34867077,0x30476dc0,0x3d044b19,0x39c556ae,0x278206ab,0x23431b1c,0x2e003dc5,0x2ac12072,0x128e9dcf,0x164f8078,0x1b0ca6a1,0x1fcdbb16,0x018aeb13,0x054bf6a4,0x0808d07d,0x0cc9cdca,0x7897ab07,0x7c56b6b0,0x71159069,0x75d48dde,0x6b93dddb,0x6f52c06c,0x6211e6b5,0x66d0fb02,0x5e9f46bf,0x5a5e5b08,0x571d7dd1,0x53dc6066,0x4d9b3063,0x495a2dd4,0x44190b0d,0x40d816ba,0xaca5c697,0xa864db20,0xa527fdf9,0xa1e6e04e,0xbfa1b04b,0xbb60adfc,0xb6238b25,0xb2e29692,0x8aad2b2f,0x8e6c3698,0x832f1041,0x87ee0df6,0x99a95df3,0x9d684044,0x902b669d,0x94ea7b2a,0xe0b41de7,0xe4750050,0xe9362689,0xedf73b3e,0xf3b06b3b,0xf771768c,0xfa325055,0xfef34de2,0xc6bcf05f,0xc27dede8,0xcf3ecb31,0xcbffd686,0xd5b88683,0xd1799b34,0xdc3abded,0xd8fba05a,0x690ce0ee,0x6dcdfd59,0x608edb80,0x644fc637,0x7a089632,0x7ec98b85,0x738aad5c,0x774bb0eb,0x4f040d56,0x4bc510e1,0x46863638,0x42472b8f,0x5c007b8a,0x58c1663d,0x558240e4,0x51435d53,0x251d3b9e,0x21dc2629,0x2c9f00f0,0x285e1d47,0x36194d42,0x32d850f5,0x3f9b762c,0x3b5a6b9b,0x0315d626,0x07d4cb91,0x0a97ed48,0x0e56f0ff,0x1011a0fa,0x14d0bd4d,0x19939b94,0x1d528623,0xf12f560e,0xf5ee4bb9,0xf8ad6d60,0xfc6c70d7,0xe22b20d2,0xe6ea3d65,0xeba91bbc,0xef68060b,0xd727bbb6,0xd3e6a601,0xdea580d8,0xda649d6f,0xc423cd6a,0xc0e2d0dd,0xcda1f604,0xc960ebb3,0xbd3e8d7e,0xb9ff90c9,0xb4bcb610,0xb07daba7,0xae3afba2,0xaafbe615,0xa7b8c0cc,0xa379dd7b,0x9b3660c6,0x9ff77d71,0x92b45ba8,0x9675461f,0x8832161a,0x8cf30bad,0x81b02d74,0x857130c3,0x5d8a9099,0x594b8d2e,0x5408abf7,0x50c9b640,0x4e8ee645,0x4a4ffbf2,0x470cdd2b,0x43cdc09c,0x7b827d21,0x7f436096,0x7200464f,0x76c15bf8,0x68860bfd,0x6c47164a,0x61043093,0x65c52d24,0x119b4be9,0x155a565e,0x18197087,0x1cd86d30,0x029f3d35,0x065e2082,0x0b1d065b,0x0fdc1bec,0x3793a651,0x3352bbe6,0x3e119d3f,0x3ad08088,0x2497d08d,0x2056cd3a,0x2d15ebe3,0x29d4f654,0xc5a92679,0xc1683bce,0xcc2b1d17,0xc8ea00a0,0xd6ad50a5,0xd26c4d12,0xdf2f6bcb,0xdbee767c,0xe3a1cbc1,0xe760d676,0xea23f0af,0xeee2ed18,0xf0a5bd1d,0xf464a0aa,0xf9278673,0xfde69bc4,0x89b8fd09,0x8d79e0be,0x803ac667,0x84fbdbd0,0x9abc8bd5,0x9e7d9662,0x933eb0bb,0x97ffad0c,0xafb010b1,0xab710d06,0xa6322bdf,0xa2f33668,0xbcb4666d,0xb8757bda,0xb5365d03,0xb1f740b4};
static uint32_t crc(const unsigned char *p,size_t count,uint32_t value) {
    for(size_t i=0;i<count;i++)value=(value<<8)^crcTable[((value>>24)^p[i])&255];
    return value;
}
uint32_t SAPOggChecksum(const uint8_t *bytes,size_t length,uint32_t initial) {
    return crc(bytes,length,initial);
}
const char *SAPOggExportStatusName(SAPOggExportStatus status) {
    switch(status) {
#define STATUS(value, name) case value: return name
        STATUS(SAPOggExportOK,"ok");
        STATUS(SAPOggExportInvalidArguments,"invalid_arguments");
        STATUS(SAPOggExportSeekFailed,"seek_failed");
        STATUS(SAPOggExportTellFailed,"tell_failed");
        STATUS(SAPOggExportInputTooShort,"input_too_short");
        STATUS(SAPOggExportReadFailed,"read_failed");
        STATUS(SAPOggExportVorbisBOSNotFound,"vorbis_bos_not_found");
        STATUS(SAPOggExportTrailingData,"trailing_data");
        STATUS(SAPOggExportTruncatedPageHeader,"truncated_page_header");
        STATUS(SAPOggExportInvalidPageHeader,"invalid_page_header");
        STATUS(SAPOggExportTruncatedSegmentTable,"truncated_segment_table");
        STATUS(SAPOggExportTruncatedPageBody,"truncated_page_body");
        STATUS(SAPOggExportCRCMismatch,"crc_mismatch");
        STATUS(SAPOggExportInvalidIdentificationHeader,"invalid_identification_header");
        STATUS(SAPOggExportInvalidSampleRate,"invalid_sample_rate");
        STATUS(SAPOggExportUnexpectedBOS,"unexpected_bos");
        STATUS(SAPOggExportSerialMismatch,"serial_mismatch");
        STATUS(SAPOggExportSequenceMismatch,"sequence_mismatch");
        STATUS(SAPOggExportGranuleRegression,"granule_regression");
        STATUS(SAPOggExportContinuationMismatch,"continuation_mismatch");
        STATUS(SAPOggExportInvalidVorbisHeaderOrder,"invalid_vorbis_header_order");
        STATUS(SAPOggExportMissingVorbisHeaders,"missing_vorbis_headers");
        STATUS(SAPOggExportUnfinishedPacket,"unfinished_packet");
        STATUS(SAPOggExportMissingEOS,"missing_eos");
        STATUS(SAPOggExportInvalidGranule,"invalid_granule");
        STATUS(SAPOggExportDurationMismatch,"duration_mismatch");
        STATUS(SAPOggExportInspectionCancelled,"diagnostic_cancelled");
#undef STATUS
    }
    return "unknown";
}
static int fail(SAPOggExportDiagnostics *d,SAPOggExportStatus status,uint64_t offset) {
    if(d){d->status=status;d->failure_offset=offset;}return 0;
}
int SAPOggBufferHasVorbisBOS(const uint8_t *buffer,size_t length,size_t *offset) {
    if(!buffer || length<27+1+30) return 0;
    for(size_t i=0;i+27+1+30<=length;i++) {
        const uint8_t *head=buffer+i;
        if(memcmp(head,"OggS",4)||head[4]||head[5]!=2)continue;
        unsigned laces=head[26];
        if(laces!=1 || i+27+1+30>length || head[27]!=30)continue;
        const uint8_t *body=head+28;
        if(memcmp(body,"\1vorbis",7))continue;
        uint32_t stored=le32(head+22);
        uint8_t copy[27];memcpy(copy,head,27);memset(copy+22,0,4);
        if(stored!=crc(body,30,crc(head+27,1,crc(copy,27,0))))continue;
        uint32_t rate=le32(body+12);
        if(!rate||rate>384000||!(body[29]&1))continue;
        if(offset)*offset=i;
        return 1;
    }
    return 0;
}
static int shortRead(FILE *f,SAPOggExportDiagnostics *d,SAPOggExportStatus status,uint64_t offset) {
    return fail(d,ferror(f)?SAPOggExportReadFailed:status,offset);
}
static int validate(FILE *f,uint64_t start,uint64_t size,uint64_t expected,uint64_t *streamEnd,SAPOggExportDiagnostics *d,SAPOggDiagnosticsContinue keepGoing,void *context) {
    unsigned char head[27],laces[255],body[65025],signature[7];
    uint32_t serial=0,sequence=0,rate=0;uint64_t end=0,audioEnd=size;int first=1,eos=0,packetOpen=0;
    unsigned headers=0,signatureBytes=0;
    if(fseeko(f,(off_t)start,SEEK_SET))return fail(d,SAPOggExportSeekFailed,start);
    for(;;) {
        off_t position=ftello(f);if(position<0)return fail(d,SAPOggExportTellFailed,start);
        uint64_t at=(uint64_t)position;
        if(keepGoing&&!keepGoing(context))return fail(d,SAPOggExportInspectionCancelled,at);
        if(at>=size)break;
        if(eos) {
            // Native payloads may be zero-aligned to an absolute 4-byte boundary.
            // Accept only that exact trailer after a completely validated EOS page.
            uint64_t padding=size-at;unsigned char tail[3];
            if(padding>sizeof(tail)||(size%4))return fail(d,SAPOggExportTrailingData,at);
            if(fread(tail,1,(size_t)padding,f)!=(size_t)padding)return shortRead(f,d,SAPOggExportReadFailed,at);
            for(size_t i=0;i<(size_t)padding;i++)if(tail[i])return fail(d,SAPOggExportTrailingData,at);
            audioEnd=at;break;
        }
        if(fread(head,1,27,f)!=27)return shortRead(f,d,SAPOggExportTruncatedPageHeader,at);
        if(memcmp(head,"OggS",4)||head[4]||(head[5]&~7))return fail(d,SAPOggExportInvalidPageHeader,at);
        unsigned n=head[26];if(fread(laces,1,n,f)!=n)return shortRead(f,d,SAPOggExportTruncatedSegmentTable,at);
        size_t bytes=0;for(unsigned i=0;i<n;i++)bytes+=laces[i];
        if(fread(body,1,bytes,f)!=bytes)return shortRead(f,d,SAPOggExportTruncatedPageBody,at);
        uint32_t stored=le32(head+22);memset(head+22,0,4);
        if(stored!=crc(body,bytes,crc(laces,n,crc(head,27,0))))return fail(d,SAPOggExportCRCMismatch,at);
        if(first){
            if(head[5]!=2||le32(head+18)!=0||n!=1||laces[0]!=30||bytes!=30||memcmp(body,"\1vorbis",7)||le32(body+7)||!body[11]||!(body[29]&1))return fail(d,SAPOggExportInvalidIdentificationHeader,at);
            serial=le32(head+14);rate=le32(body+12);if(d)d->sample_rate=rate;
            if(!rate||rate>384000)return fail(d,SAPOggExportInvalidSampleRate,at);first=0;
        } else if(head[5]&2)return fail(d,SAPOggExportUnexpectedBOS,at);
        if(le32(head+14)!=serial)return fail(d,SAPOggExportSerialMismatch,at);
        if(le32(head+18)!=sequence++)return fail(d,SAPOggExportSequenceMismatch,at);
        // Empty pages carry no packet data and do not change continuation state.
        if((n&&!!(head[5]&1)!=packetOpen)||(!n&&(head[5]&1)))return fail(d,SAPOggExportContinuationMismatch,at);
        size_t consumed=0;
        for(unsigned i=0;i<n;i++) {
            unsigned segment=laces[i];
            if(headers<3) {
                size_t take=sizeof(signature)-signatureBytes;if(take>segment)take=segment;
                memcpy(signature+signatureBytes,body+consumed,take);signatureBytes+=(unsigned)take;
            }
            consumed+=segment;packetOpen=segment==255;
            if(!packetOpen&&headers<3) {
                static const unsigned char types[]={1,3,5};
                if(signatureBytes!=7||signature[0]!=types[headers]||memcmp(signature+1,"vorbis",6))return fail(d,SAPOggExportInvalidVorbisHeaderOrder,at);
                headers++;signatureBytes=0;
            }
        }
        uint64_t granule=le64(head+6);if(granule!=UINT64_MAX){if(granule<end)return fail(d,SAPOggExportGranuleRegression,at);end=granule;}
        eos=(head[5]&4)!=0;
        if(eos&&packetOpen)return fail(d,SAPOggExportUnfinishedPacket,at);
        if(eos&&headers<3)return fail(d,SAPOggExportMissingVorbisHeaders,at);
        if(d)d->pages_validated++;
    }
    if(first||!eos)return fail(d,SAPOggExportMissingEOS,size);
    if(!end||end>UINT64_MAX/1000)return fail(d,SAPOggExportInvalidGranule,size);
    uint64_t duration=end*1000/rate;if(d)d->observed_duration_ms=duration;
    if(expected&&((duration<expected&&expected-duration>2000)||(duration>expected&&duration-expected>2000)))return fail(d,SAPOggExportDurationMismatch,size);
    if(streamEnd)*streamEnd=audioEnd;
    return 1;
}
int SAPValidateOggExportDetailedCancellable(FILE *f,uint64_t expected,uint64_t *offset,uint64_t *length,SAPOggExportDiagnostics *d,SAPExportContinue keepGoing,void *context) {
    if(d){memset(d,0,sizeof(*d));d->status=SAPOggExportInvalidArguments;}
    if(!f||!offset||!length)return fail(d,SAPOggExportInvalidArguments,0);
    if(!SAPExportMayContinue(keepGoing,context))return fail(d,SAPOggExportInspectionCancelled,0);
    if(fseeko(f,0,SEEK_END))return fail(d,SAPOggExportSeekFailed,0);
    off_t total=ftello(f);if(total<0)return fail(d,SAPOggExportTellFailed,0);
    if(d)d->input_bytes=(uint64_t)total;
    if(total<30)return fail(d,SAPOggExportInputTooShort,0);
    // Some cached layouts place a larger auxiliary area before the stream.
    // Scan a bounded prefix instead of assuming librespot's 167-byte header.
    enum { PrefixLimit=256*1024 };
    size_t prefixSize=(size_t)PrefixLimit+27+255+7;
    unsigned char *prefix=malloc(prefixSize);
    if(!prefix)return fail(d,SAPOggExportReadFailed,0);
    if(fseeko(f,0,SEEK_SET)){free(prefix);return fail(d,SAPOggExportSeekFailed,0);}
    clearerr(f);
    size_t n=fread(prefix,1,prefixSize,f);
    if(ferror(f)){free(prefix);return fail(d,SAPOggExportReadFailed,0);}
    size_t stream=0;
    if(!SAPOggBufferHasVorbisBOS(prefix,n,&stream)){free(prefix);return fail(d,SAPOggExportVorbisBOSNotFound,0);}
    if(d){d->stream_offset=stream;d->has_stream_offset=1;}
    // Once an audio stream begins, never salvage a later concatenated track.
    uint64_t streamEnd=0;
    int valid=validate(f,stream,(uint64_t)total,expected,&streamEnd,d,keepGoing,context);
    free(prefix);
    if(!valid)return 0;
    *offset=stream;*length=streamEnd-stream;if(d)d->status=SAPOggExportOK;return 1;
}
int SAPValidateOggExport(FILE *f,uint64_t expected,uint64_t *offset,uint64_t *length) {
    return SAPValidateOggExportDetailed(f,expected,offset,length,NULL);
}
int SAPDiagnoseOggStreamFrom(FILE *f,uint64_t start,SAPOggExportDiagnostics *d,SAPOggDiagnosticsContinue keepGoing,void *context) {
    if(d){memset(d,0,sizeof(*d));d->status=SAPOggExportInvalidArguments;}
    if(!f || !d)return 0;
    if(fseeko(f,0,SEEK_END))return fail(d,SAPOggExportSeekFailed,start);
    off_t total=ftello(f);if(total<0)return fail(d,SAPOggExportTellFailed,start);
    if(start>=(uint64_t)total)return 0;
    d->input_bytes=(uint64_t)total;d->stream_offset=start;d->has_stream_offset=1;
    if(!validate(f,start,(uint64_t)total,0,NULL,d,keepGoing,context))return 0;
    d->status=SAPOggExportOK;return 1;
}

int SAPValidateOggExportDetailed(FILE *f,uint64_t expected,uint64_t *offset,uint64_t *length,SAPOggExportDiagnostics *d) {return SAPValidateOggExportDetailedCancellable(f,expected,offset,length,d,NULL,NULL);}
