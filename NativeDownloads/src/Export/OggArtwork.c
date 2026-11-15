#include "OggArtwork.h"
#include "OggExport.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

enum { MaxComment=4*1024*1024, MaxImage=1024*1024 };
typedef struct {uint8_t header[27],laces[255],body[65025];size_t count,bytes;} Page;
static uint32_t get32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put32(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(i*8));}
static void put64(uint8_t *p,uint64_t n){for(unsigned i=0;i<8;i++)p[i]=(uint8_t)(n>>(i*8));}
static void big32(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(24-i*8));}
static uint32_t checksum(Page *p){return SAPOggChecksum(p->body,p->bytes,SAPOggChecksum(p->laces,p->count,SAPOggChecksum(p->header,27,0)));}
static int readPage(FILE *f,uint64_t end,Page *p,uint32_t serial,uint32_t sequence,int first) {
    off_t at=ftello(f);if(at<0||(uint64_t)at>end||end-(uint64_t)at<27)return 0;
    if(fread(p->header,1,27,f)!=27||memcmp(p->header,"OggS",4)||p->header[4]||(p->header[5]&~7))return 0;
    p->count=p->header[26];p->bytes=0;
    if(end-(uint64_t)at-27<p->count||fread(p->laces,1,p->count,f)!=p->count)return 0;
    for(size_t i=0;i<p->count;i++)p->bytes+=p->laces[i];
    if(end-(uint64_t)at-27-p->count<p->bytes||fread(p->body,1,p->bytes,f)!=p->bytes)return 0;
    if(get32(p->header+18)!=sequence||(!first&&get32(p->header+14)!=serial))return 0;
    uint32_t saved=get32(p->header+22);memset(p->header+22,0,4);
    return saved==checksum(p);
}
static int writePage(FILE *f,Page *p,uint32_t sequence) {
    p->header[26]=(uint8_t)p->count;put32(p->header+18,sequence);memset(p->header+22,0,4);
    put32(p->header+22,checksum(p));
    return fwrite(p->header,1,27,f)==27&&fwrite(p->laces,1,p->count,f)==p->count&&fwrite(p->body,1,p->bytes,f)==p->bytes;
}
static int artworkField(const uint8_t *data,size_t length) {
    const char *names[]={"METADATA_BLOCK_PICTURE=","COVERART=","COVERARTMIME="};
    for(unsigned n=0;n<3;n++) {
        size_t len=strlen(names[n]);if(length<len)continue;size_t i=0;
        for(;i<len;i++){unsigned c=data[i];if(c>='a'&&c<='z')c-=32;if(c!=(unsigned char)names[n][i])break;}
        if(i==len)return 1;
    }
    return 0;
}
static uint8_t *pictureComment(const uint8_t *old,size_t oldSize,const uint8_t *jpeg,size_t jpegSize,
                               uint32_t width,uint32_t height,size_t *resultSize) {
    if(oldSize<16||oldSize>MaxComment||memcmp(old,"\3vorbis",7))return NULL;
    uint32_t vendor=get32(old+7);size_t at=11;
    if(vendor>oldSize-at||oldSize-at-vendor<5)return NULL;at+=vendor;
    uint32_t count=get32(old+at);at+=4;if(count>65536)return NULL;
    size_t rawSize=42+jpegSize,encodedSize=((rawSize+2)/3)*4;
    const char *name="METADATA_BLOCK_PICTURE=";size_t nameSize=strlen(name);
    size_t capacity=oldSize+4+nameSize+encodedSize;
    uint8_t *raw=malloc(rawSize),*out=malloc(capacity);
    if(!raw||!out){free(raw);free(out);return NULL;}
    big32(raw,3);big32(raw+4,10);memcpy(raw+8,"image/jpeg",10);big32(raw+18,0);
    big32(raw+22,width);big32(raw+26,height);big32(raw+30,24);big32(raw+34,0);big32(raw+38,(uint32_t)jpegSize);
    memcpy(raw+42,jpeg,jpegSize);
    size_t written=11+vendor;memcpy(out,old,written);size_t countAt=written;written+=4;uint32_t kept=0;
    for(uint32_t i=0;i<count;i++) {
        if(oldSize-at<4)goto invalid;
        size_t size=get32(old+at);at+=4;if(size>oldSize-at)goto invalid;
        if(!artworkField(old+at,size)){put32(out+written,(uint32_t)size);written+=4;memcpy(out+written,old+at,size);written+=size;kept++;}
        at+=size;
    }
    if(at>=oldSize||!(old[at]&1))goto invalid;
    put32(out+written,(uint32_t)(nameSize+encodedSize));written+=4;memcpy(out+written,name,nameSize);written+=nameSize;
    static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for(size_t i=0;i<rawSize;i+=3) {
        size_t left=rawSize-i;uint32_t value=(uint32_t)raw[i]<<16;
        if(left>1)value|=(uint32_t)raw[i+1]<<8;if(left>2)value|=raw[i+2];
        out[written++]=(uint8_t)alphabet[value>>18];out[written++]=(uint8_t)alphabet[(value>>12)&63];
        out[written++]=left>1?(uint8_t)alphabet[(value>>6)&63]:'=';out[written++]=left>2?(uint8_t)alphabet[value&63]:'=';
    }
    memcpy(out+written,old+at,oldSize-at);written+=oldSize-at;put32(out+countAt,kept+1);
    free(raw);*resultSize=written;return out;
invalid:free(raw);free(out);return NULL;
}
static int writeComment(FILE *output,const uint8_t *packet,size_t size,uint32_t serial,uint32_t *sequence) {
    Page page={0};memcpy(page.header,"OggS",4);put32(page.header+14,serial);
    size_t at=0;int pending=1,continuation=0;
    while(pending) {
        page.count=page.bytes=0;
        while(page.count<255) {
            size_t take=size-at;if(take>255)take=255;
            page.laces[page.count++]=(uint8_t)take;memcpy(page.body+page.bytes,packet+at,take);page.bytes+=take;at+=take;
            if(take<255){pending=0;break;}
        }
        page.header[5]=(uint8_t)continuation;put64(page.header+6,pending?UINT64_MAX:0);
        if(!writePage(output,&page,(*sequence)++))return 0;continuation=1;
    }
    return 1;
}
int SAPWriteOggWithArtworkCancellable(FILE *source,uint64_t offset,uint64_t length,FILE *output,
                          const uint8_t *jpeg,size_t jpegLength,uint32_t width,uint32_t height,SAPExportContinue keepGoing,void *context) {
    if(!source||!output||source==output||!jpeg||jpegLength<4||jpegLength>MaxImage||jpeg[0]!=0xff||jpeg[1]!=0xd8||
       !width||!height||width>4096||height>4096||offset>(uint64_t)LLONG_MAX||length>(uint64_t)LLONG_MAX-offset)return 0;
    uint64_t end=offset+length;Page *page=malloc(sizeof(*page));uint8_t *old=malloc(MaxComment),*replacement=NULL;
    if(!page||!old){free(page);free(old);return 0;}
    int ok=0,complete=0;uint32_t sequence=0,serial=0;size_t used=0,newSize=0;
    if(fseeko(source,(off_t)offset,SEEK_SET)||!readPage(source,end,page,0,0,1)||page->header[5]!=2||page->count!=1||page->laces[0]!=30)goto done;
    serial=get32(page->header+14);sequence=1;
    while(!complete) {
        if(!SAPExportMayContinue(keepGoing,context))goto done;
        if(!readPage(source,end,page,serial,sequence++,0))goto done;
        size_t at=0;
        for(size_t i=0;i<page->count;i++) {
            size_t take=page->laces[i];if(take>MaxComment-used)goto done;
            memcpy(old+used,page->body+at,take);used+=take;at+=take;
            if(take<255){complete=1;break;}
        }
    }
    replacement=pictureComment(old,used,jpeg,jpegLength,width,height,&newSize);if(!replacement)goto done;
    if(fseeko(source,(off_t)offset,SEEK_SET)||!readPage(source,end,page,serial,0,0))goto done;
    sequence=0;if(!writePage(output,page,sequence++))goto done;
    uint32_t inputSequence=1;complete=0;
    while(!complete) {
        if(!SAPExportMayContinue(keepGoing,context))goto done;
        if(!readPage(source,end,page,serial,inputSequence++,0))goto done;
        size_t consumed=0,segments=0;
        for(;segments<page->count;segments++){size_t take=page->laces[segments];consumed+=take;if(take<255){segments++;complete=1;break;}}
        if(!complete)continue;
        if(!writeComment(output,replacement,newSize,serial,&sequence))goto done;
        if(segments<page->count) {
            memmove(page->laces,page->laces+segments,page->count-segments);page->count-=segments;
            memmove(page->body,page->body+consumed,page->bytes-consumed);page->bytes-=consumed;page->header[5]&=(uint8_t)~1;
            if(!writePage(output,page,sequence++))goto done;
        }
    }
    while((uint64_t)ftello(source)<end) {
        if(!SAPExportMayContinue(keepGoing,context))goto done;
        if(!readPage(source,end,page,serial,inputSequence++,0)||!writePage(output,page,sequence++))goto done;
    }
    ok=(uint64_t)ftello(source)==end&&!ferror(source)&&!fflush(output);
done:free(replacement);free(old);free(page);return ok;
}

int SAPWriteOggWithArtwork(FILE *source,uint64_t offset,uint64_t length,FILE *output,const uint8_t *jpeg,size_t jpegLength,uint32_t width,uint32_t height) {return SAPWriteOggWithArtworkCancellable(source,offset,length,output,jpeg,jpegLength,width,height,NULL,NULL);}
