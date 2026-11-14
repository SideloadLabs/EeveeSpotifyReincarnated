#define _POSIX_C_SOURCE 200809L
#include "OggInspection.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <errno.h>
#include <limits.h>
enum {PageMaximum=27+255+65025,ProbeLimit=64};
static uint32_t u32(const unsigned char *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t u64(const unsigned char *p){return u32(p)|(uint64_t)u32(p+4)<<32;}
static int readAt(FILE *f,uint64_t at,void *bytes,size_t count) {
    return at<=INT64_MAX && !fseeko(f,(off_t)at,SEEK_SET) && fread(bytes,1,count,f)==count;
}
static int probe(FILE *f,uint64_t at,uint64_t size,SAPOggPageInspection *p,unsigned char *buffer) {
    memset(p,0,sizeof(*p));p->offset=at;
    if(at>size || size-at<27 || !readAt(f,at,buffer,27) || memcmp(buffer,"OggS",4))return 0;
    p->header_present=1;p->version=buffer[4];p->flags=buffer[5];p->valid_header=!buffer[4]&&!(buffer[5]&~7);
    p->granule=u64(buffer+6);p->serial=u32(buffer+14);p->sequence=u32(buffer+18);p->stored_crc=u32(buffer+22);
    size_t segments=buffer[26];if(size-at<27+segments || !readAt(f,at+27,buffer+27,segments))return 0;
    size_t body=0;for(size_t i=0;i<segments;i++)body+=buffer[27+i];p->bytes=27+segments+body;
    if(p->bytes>size-at || !readAt(f,at+27+segments,buffer+27+segments,body))return 0;
    p->complete=1;memset(buffer+22,0,4);p->computed_crc=SAPOggChecksum(buffer,(size_t)p->bytes,0);p->crc_checked=1;p->crc_matches=p->stored_crc==p->computed_crc;
    if(p->valid_header && p->crc_matches && p->flags==2 && !p->sequence && segments==1 && body==30 && buffer[27]==30 && !memcmp(buffer+28,"\1vorbis",7) && !u32(buffer+35) && buffer[39] && u32(buffer+40) && (buffer[57]&1))p->vorbis_bos=1;
    return p->valid_header && p->complete && p->crc_matches;
}
const char *SAPOggTailSignatureName(uint64_t signature) {
    switch(signature){case 1:return "OggS";case 2:return "ID3";case 3:return "APETAGEX";case 4:return "TAG";case 5:return "fLaC";case 6:return "RIFF";case 7:return "MP4_ftyp";default:return "unknown";}
}
static uint64_t signature(const unsigned char *p,size_t n) {
    if(n>=4&&!memcmp(p,"OggS",4))return 1;if(n>=3&&!memcmp(p,"ID3",3))return 2;
    if(n>=8&&!memcmp(p,"APETAGEX",8))return 3;if(n>=3&&!memcmp(p,"TAG",3))return 4;
    if(n>=4&&!memcmp(p,"fLaC",4))return 5;if(n>=4&&!memcmp(p,"RIFF",4))return 6;
    if(n>=8&&!memcmp(p+4,"ftyp",4))return 7;return 0;
}
int SAPInspectOggExport(FILE *f,const SAPOggExportDiagnostics *d,uint64_t expected,SAPOggInspection *out,SAPOggInspectionContinue keepGoing,void *context) {
    if(!out)return 0;memset(out,0,sizeof(*out));if(!f||!d)return 0;
    off_t saved=ftello(f);if(saved<0||ferror(f)){out->io_error=errno?errno:EIO;return 0;}
    unsigned char *page=malloc(PageMaximum),*buffer=malloc(PageMaximum+3);int complete=0;
    if(!page||!buffer){out->io_error=ENOMEM;goto done;}
    if(keepGoing&&!keepGoing(context)){out->cancelled=1;goto done;}
    if(fseeko(f,0,SEEK_END)){out->io_error=errno;goto done;}off_t end=ftello(f);
    if(end<0){out->io_error=1;goto done;}out->source_bytes=(uint64_t)end;
    if(out->source_bytes!=d->input_bytes){out->source_size_changed=1;goto done;}
    probe(f,d->failure_offset,out->source_bytes,&out->failure_page,page);
    uint64_t eosEnd=d->status==SAPOggExportTrailingData?d->failure_offset:(d->status==SAPOggExportOK||d->status==SAPOggExportDurationMismatch?out->source_bytes:0);
    if(eosEnd && eosEnd<=out->source_bytes && d->has_stream_offset && d->pages_validated && readAt(f,d->stream_offset,page,27)) {
        uint32_t serial=u32(page+14);uint64_t begin=eosEnd>PageMaximum+3?eosEnd-PageMaximum-3:0;if(begin<d->stream_offset)begin=d->stream_offset;
        size_t amount=(size_t)(eosEnd-begin);
        if(readAt(f,begin,buffer,amount))for(size_t i=amount;i-->0;) {
            if(i+4>amount || memcmp(buffer+i,"OggS",4))continue;
            SAPOggPageInspection candidate;
            if(probe(f,begin+i,eosEnd,&candidate,page) && (candidate.flags&4) && candidate.serial==serial && candidate.sequence==(uint32_t)(d->pages_validated-1)) {
                uint64_t candidateEnd=begin+i+candidate.bytes,extra=eosEnd-candidateEnd;
                if(extra) {
                    if(extra>3||eosEnd%4||(d->status!=SAPOggExportOK&&d->status!=SAPOggExportDurationMismatch))continue;
                    int zero=1;for(size_t j=i+(size_t)candidate.bytes;j<amount;j++)if(buffer[j]){zero=0;break;}
                    if(!zero)continue;
                }
                out->eos_found=1;out->eos_end_offset=candidateEnd;out->eos_page=candidate;
                if(d->sample_rate && candidate.granule && candidate.granule<=UINT64_MAX/1000) {
                    out->eos_duration_ms=candidate.granule*1000/d->sample_rate;
                    out->duration_checked=expected>0;uint64_t duration=out->eos_duration_ms;
                    out->duration_matches=expected && (duration>expected?duration-expected:expected-duration)<=2000;
                }break;
            }
        }
    }
    if(!out->eos_found){complete=1;goto done;}
    eosEnd=out->eos_end_offset;
    out->tail_bytes=out->source_bytes-out->eos_end_offset;
    uint64_t histogram[256]={0},rolling=0;int leading=1;unsigned char last=0;
    for(uint64_t at=eosEnd;at<out->source_bytes;) {
        if(keepGoing&&!keepGoing(context)){out->cancelled=1;goto done;}
        size_t n=(size_t)(out->source_bytes-at);if(n>8192)n=8192;
        if(!readAt(f,at,buffer,n)){out->io_error=1;goto done;}
        out->tail_crc32=SAPOggChecksum(buffer,n,(uint32_t)out->tail_crc32);
        if(at==eosEnd)out->tail_signature=signature(buffer,n);
        for(size_t i=0;i<n;i++) {
            unsigned char byte=buffer[i];last=byte;histogram[byte]++;
            if(!byte){out->tail_zero_bytes++;out->tail_trailing_zeros++;if(leading)out->tail_leading_zeros++;}else{leading=0;out->tail_trailing_zeros=0;}
            rolling=((rolling<<8)|byte)&UINT32_MAX;
            if(rolling==UINT32_C(0x4f676753)) {
                out->ogg_magic_count++;
                if(out->page_candidates_checked<ProbeLimit) {
                    uint64_t position=at+i-3;SAPOggPageInspection candidate;out->page_candidates_checked++;
                    if(probe(f,position,out->source_bytes,&candidate,page)) {
                        out->valid_tail_pages++;if(!out->first_tail_page.header_present)out->first_tail_page=candidate;
                        if(candidate.vorbis_bos && !out->following_bos_found) {
                            out->following_bos_found=1;out->following_offset=position;SAPOggExportDiagnostics next={0};
                            SAPDiagnoseOggStreamFrom(f,position,&next,keepGoing,context);out->following_status=next.status;out->following_pages=next.pages_validated;out->following_duration_ms=next.observed_duration_ms;
                            if(next.status==SAPOggExportInspectionCancelled){out->cancelled=1;goto done;}
                        }
                    }
                }else out->page_probe_limit_reached=1;
            }
        }
        out->tail_scanned+=n;at+=n;
    }
    out->tail_scan_complete=1;
    double entropy=0;
    for(unsigned i=0;i<256;i++)if(histogram[i]){out->tail_distinct_bytes++;out->tail_uniform_byte=i;double p=(double)histogram[i]/(double)out->tail_bytes;entropy-=p*log2(p);}
    out->tail_uniform=out->tail_distinct_bytes==1;if(!out->tail_uniform)out->tail_uniform_byte=0;
    out->tail_entropy_millibits=(uint64_t)(entropy*1000+.5);
    if(out->tail_bytes>0 && out->tail_bytes<=16 && last==out->tail_bytes) {
        out->tail_pkcs7_shape=out->tail_uniform;out->tail_x923_shape=out->tail_zero_bytes==out->tail_bytes-1;
    }complete=1;
done:
    if(ferror(f))out->io_error=1;
    clearerr(f);out->position_restored=!fseeko(f,saved,SEEK_SET);free(page);free(buffer);
    return complete && out->position_restored && !out->io_error && !out->cancelled;
}
