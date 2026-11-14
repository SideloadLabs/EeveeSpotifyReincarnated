#include "CacheEnvelope.h"
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint32_t adler(const uint8_t *p,size_t length) {
    uint32_t a=1,b=0;
    for(size_t i=0;i<length;i++){a=(a+p[i])%65521;b=(b+a)%65521;}
    return b<<16|a;
}
static int cipherAt(const uint8_t key[16],const uint8_t descriptor[24],uint64_t offset,CCCryptorRef *cipher) {
    uint8_t counter[16];memcpy(counter,descriptor,16);
    counter[0]^=descriptor[20];counter[2]^=descriptor[23];counter[3]^=descriptor[22];
    uint64_t blocks=offset/16;
    for(int i=15;i>=0 && blocks;i--){blocks+=counter[i];counter[i]=(uint8_t)blocks;blocks>>=8;}
    int ok=!blocks && CCCryptorCreateWithMode(kCCDecrypt,kCCModeCTR,kCCAlgorithmAES,ccNoPadding,
        counter,key,16,NULL,0,0,kCCModeOptionCTR_BE,cipher)==kCCSuccess;
    memset_s(counter,sizeof(counter),0,sizeof(counter));
    if(ok && offset%16) {
        uint8_t zero[16]={0},discard[32];size_t produced=0;
        ok=CCCryptorUpdate(*cipher,zero,offset%16,discard,sizeof(discard),&produced)==kCCSuccess && produced==offset%16;
        memset_s(discard,sizeof(discard),0,sizeof(discard));
    }
    if(!ok && *cipher){CCCryptorRelease(*cipher);*cipher=NULL;}
    return ok;
}
static int readAt(FILE *file,uint64_t offset,uint8_t *out,size_t size,const uint8_t *key,const uint8_t descriptor[24]) {
    size_t read=0;
    while(read<size) {
        ssize_t n=pread(fileno(file),out+read,size-read,(off_t)(offset+read));
        if(n<0 && errno==EINTR)continue;
        if(n<=0)return 0;read+=(size_t)n;
    }
    if(!key)return 1;
    CCCryptorRef cipher=NULL;size_t written=0;
    int ok=cipherAt(key,descriptor,offset,&cipher) &&
        CCCryptorUpdate(cipher,out,size,out,size,&written)==kCCSuccess && written==size;
    if(cipher)CCCryptorRelease(cipher);return ok;
}
static int reject(SAPCacheEnvelopeDetails *details,const char *status) {
    if(details)details->status=status;return 0;
}
int SAPExtractCacheEnvelopeCancellable(FILE *input,FILE *output,const uint8_t *key,
                           const uint8_t descriptor[24],SAPCacheEnvelopeDetails *details,SAPExportContinue keepGoing,void *context) {
    if(details){memset(details,0,sizeof(*details));details->status="invalid_arguments";}
    if(!input || !output || !descriptor || input==output)return 0;
    if(!SAPExportMayContinue(keepGoing,context))return reject(details,"cancelled");
    if(fseeko(input,0,SEEK_END))return reject(details,"seek_failed");
    off_t total=ftello(input);
    if(total<68 || total>1024LL*1024*1024)return reject(details,"unsupported_size");
    if(details)details->physical_bytes=(uint64_t)total;
    uint8_t head[64],buffer[65536];
    for(unsigned encrypted=0;encrypted<(key?2u:1u);encrypted++)for(unsigned tail=0;tail<2;tail++) {
        if(!SAPExportMayContinue(keepGoing,context))return reject(details,"cancelled");
        const uint8_t *useKey=encrypted?key:NULL;
        uint64_t headerOffset=tail?(uint64_t)total-64:0;
        if(!readAt(input,headerOffset,head,sizeof(head),useKey,descriptor))return reject(details,"header_read_failed");
        if(le32(head+4)!=0x617233ab || le32(head)!=adler(head+4,60))continue;
        uint64_t size=le32(head+8);
        if(!size || size>1024ULL*1024*1024 || head[32]!=descriptor[20] || head[33])
            return reject(details,"invalid_header");
        uint64_t count=(size+16383)/16384,metadata=64+4*count;
        uint64_t padding=(uint64_t)head[34]|(uint64_t)head[35]<<8|(uint64_t)head[44]<<16;
        if(metadata>(uint64_t)total || padding>(uint64_t)total-metadata ||
           (uint64_t)total-metadata-padding!=size)return reject(details,"inconsistent_size");
        uint64_t table=tail?(uint64_t)total-metadata:64;
        for(uint64_t at=0;at<count;) {
            if(!SAPExportMayContinue(keepGoing,context))return reject(details,"cancelled");
            size_t n=(size_t)(count-at);if(n>sizeof(buffer)/4)n=sizeof(buffer)/4;
            if(!readAt(input,table+at*4,buffer,n*4,useKey,descriptor))return reject(details,"block_table_read_failed");
            for(size_t i=0;i<n;i++)if(le32(buffer+i*4)==UINT32_MAX)return reject(details,"incomplete_blocks");
            at+=n;
        }
        // Native logical offset 0x1061b92ac: header-first files place metadata
        // and the auxiliary area before audio; footer files begin with audio.
        uint64_t payload=tail?0:metadata+padding;
        if(ftruncate(fileno(output),0) || fseeko(output,0,SEEK_SET))return reject(details,"output_reset_failed");
        CCCryptorRef cipher=NULL;
        if(useKey && !cipherAt(useKey,descriptor,payload,&cipher))return reject(details,"storage_cipher_failed");
        int ok=1,cancelled=0;
        for(uint64_t at=0;at<size;) {
            if(!SAPExportMayContinue(keepGoing,context)){ok=0;cancelled=1;break;}
            size_t n=(size_t)(size-at);if(n>sizeof(buffer))n=sizeof(buffer);
            if(!readAt(input,payload+at,buffer,n,NULL,descriptor)){ok=0;break;}
            if(cipher) {
                size_t written=0;
                if(CCCryptorUpdate(cipher,buffer,n,buffer,sizeof(buffer),&written)!=kCCSuccess || written!=n){ok=0;break;}
            }
            if(fwrite(buffer,1,n,output)!=n){ok=0;break;}
            at+=n;
        }
        if(cipher)CCCryptorRelease(cipher);
        memset_s(buffer,sizeof(buffer),0,sizeof(buffer));
        if(cancelled)return reject(details,"cancelled");
        if(!ok || fflush(output))return reject(details,"payload_copy_failed");
        if(details){details->status="ok";details->payload_bytes=size;details->payload_offset=payload;
            details->blocks=(unsigned)count;details->encrypted=(int)encrypted;details->metadata_at_end=(int)tail;}
        return !fseeko(output,0,SEEK_SET);
    }
    memset_s(head,sizeof(head),0,sizeof(head));
    return reject(details,key?"native_header_not_validated":"storage_context_unavailable_or_legacy_file");
}

int SAPExtractCacheEnvelope(FILE *input,FILE *output,const uint8_t *key,const uint8_t descriptor[24],SAPCacheEnvelopeDetails *details) {return SAPExtractCacheEnvelopeCancellable(input,output,key,descriptor,details,NULL,NULL);}
