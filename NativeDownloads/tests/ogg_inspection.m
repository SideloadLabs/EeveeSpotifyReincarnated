#import <Foundation/Foundation.h>
#import "OggInspection.h"
#include <assert.h>
static NSData *audio;
static int stop(void *ctx){return ++*(int *)ctx<3;}
static int stopFollowing(void *ctx){return ++*(int *)ctx<4;}
static NSData *maximumEOS(NSData *source) {
 const uint8_t *bytes=source.bytes;NSUInteger eosAt=0;
 for(NSUInteger at=0;at<source.length;){
  assert(source.length-at>=27);NSUInteger segments=bytes[at+26],size=27+segments;assert(size<=source.length-at);
  for(NSUInteger i=0;i<segments;i++)size+=bytes[at+27+i];assert(size<=source.length-at);
  if(bytes[at+5]&4)eosAt=at;at+=size;
 }
 assert(eosAt);NSMutableData *page=[NSMutableData dataWithLength:27+255+65024];uint8_t *p=page.mutableBytes;
 memcpy(p,bytes+eosAt,27);p[26]=255;memset(p+22,0,4);memset(p+27,255,254);p[281]=254;
 uint32_t checksum=SAPOggChecksum(p,page.length,0);for(unsigned i=0;i<4;i++)p[22+i]=(uint8_t)(checksum>>(8*i));
 NSMutableData *result=[[source subdataWithRange:NSMakeRange(0,eosAt)]mutableCopy];[result appendData:page];return result;
}
static SAPOggInspection inspect(NSData *tail,NSUInteger prefix,SAPOggExportStatus reason) {
 FILE *f=tmpfile();assert(f);NSMutableData *data=[NSMutableData dataWithLength:prefix];[data appendData:audio];if(tail)[data appendData:tail];assert(fwrite(data.bytes,1,data.length,f)==data.length);
 uint64_t start=0,len=0;SAPOggExportDiagnostics v={0};int valid=SAPValidateOggExportDetailed(f,10000,&start,&len,&v);assert(v.status==reason);assert(valid==(reason==SAPOggExportOK));
 if(valid)assert(len==audio.length);
 off_t before=ftello(f);SAPOggInspection out={0};assert(SAPInspectOggExport(f,&v,10000,&out,NULL,NULL));assert(out.position_restored&&ftello(f)==before);
 assert(out.eos_found&&out.eos_end_offset==prefix+audio.length);assert(out.eos_page.crc_matches);assert(out.eos_duration_ms==10000&&out.duration_checked&&out.duration_matches);
 assert(out.tail_bytes==tail.length&&out.tail_scan_complete&&out.tail_scanned==tail.length);assert(v.status==reason);fclose(f);return out;
}
int main(int argc,const char **argv){@autoreleasepool {
 assert(argc==2);audio=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];assert(audio.length);
 SAPOggInspection d=inspect(nil,0,SAPOggExportOK);assert(!d.tail_bytes);
 for(NSUInteger padding=1;padding<=3;padding++){
  NSUInteger prefix=(4-padding-audio.length%4+4)%4;
  d=inspect([NSMutableData dataWithLength:padding],prefix,SAPOggExportOK);assert(d.tail_zero_bytes==padding);
 }
 NSData *original=audio;audio=maximumEOS(audio);
 for(NSUInteger padding=1;padding<=3;padding++){
  NSUInteger prefix=(4-padding-audio.length%4+4)%4;
  d=inspect([NSMutableData dataWithLength:padding],prefix,SAPOggExportOK);assert(d.eos_page.bytes==65306);
 }
 audio=original;
 d=inspect([NSMutableData dataWithLength:16],167,SAPOggExportTrailingData);assert(d.tail_zero_bytes==16&&d.tail_uniform&&d.tail_uniform_byte==0&&!d.tail_pkcs7_shape);
 uint8_t pad[]={4,4,4,4};d=inspect([NSData dataWithBytes:pad length:4],0,SAPOggExportTrailingData);assert(d.tail_pkcs7_shape&&!d.tail_x923_shape&&d.tail_distinct_bytes==1);
 uint8_t x923[]={0,0,0,4};d=inspect([NSData dataWithBytes:x923 length:4],0,SAPOggExportTrailingData);assert(d.tail_x923_shape&&!d.tail_pkcs7_shape);
 d=inspect([@"ID3metadata" dataUsingEncoding:NSUTF8StringEncoding],0,SAPOggExportTrailingData);assert(!strcmp(SAPOggTailSignatureName(d.tail_signature),"ID3"));
 d=inspect(audio,0,SAPOggExportTrailingData);assert(d.following_bos_found&&d.following_offset==audio.length&&d.following_status==SAPOggExportOK&&d.following_duration_ms==10000&&d.valid_tail_pages>0);
 uint64_t followingPages=d.following_pages;
 FILE *chain=tmpfile();assert(chain);fwrite(audio.bytes,1,audio.length,chain);fwrite(audio.bytes,1,audio.length,chain);
 SAPOggExportDiagnostics chainValidation={0};uint64_t chainStart=0,chainLength=0;assert(!SAPValidateOggExportDetailed(chain,10000,&chainStart,&chainLength,&chainValidation));
 off_t chainPosition=ftello(chain);int followingCounter=0;assert(!SAPInspectOggExport(chain,&chainValidation,10000,&d,stopFollowing,&followingCounter));
 assert(d.cancelled&&d.position_restored&&ftello(chain)==chainPosition&&d.following_pages>0&&d.following_pages<followingPages);fclose(chain);
 NSMutableData *bad=[audio mutableCopy];((uint8_t *)bad.mutableBytes)[40]^=1;d=inspect(bad,0,SAPOggExportTrailingData);assert(d.failure_page.crc_checked&&!d.failure_page.crc_matches&&!d.following_bos_found);
 d=inspect([@"OggSbad"dataUsingEncoding:NSUTF8StringEncoding],0,SAPOggExportTrailingData);assert(d.ogg_magic_count==1&&!d.valid_tail_pages);
 FILE *f=tmpfile();fwrite(audio.bytes,1,audio.length,f);uint8_t zeros[32768]={0};fwrite(zeros,1,sizeof(zeros),f);SAPOggExportDiagnostics v={0};uint64_t start=0,len=0;SAPValidateOggExportDetailed(f,10000,&start,&len,&v);off_t saved=ftello(f);int counter=0;assert(!SAPInspectOggExport(f,&v,10000,&d,stop,&counter));assert(d.cancelled&&d.position_restored&&ftello(f)==saved);fclose(f);
 puts("ogg_inspection PASS: EOS/duration/padding/metadata/chain/CRC/cancel and unchanged rejection");
}}
