#include "../src/Export/CacheEnvelope.h"
#include <assert.h>
#include <string.h>
#include <stdlib.h>

int main(int argc,char **argv) {
    assert(argc==6);
    FILE *input=fopen(argv[1],"rb"),*out=tmpfile(),*expected=fopen(argv[2],"rb");
    assert(input && out && expected);
    uint8_t descriptor[24]={0},key[16];
    for(unsigned i=0;i<20;i++)descriptor[i]=(uint8_t)i;
    for(unsigned i=0;i<16;i++)key[i]=(uint8_t)(0xa0+i);
    descriptor[20]=(uint8_t)atoi(argv[5]);descriptor[22]=0x34;descriptor[23]=0x12;
    if(atoi(argv[3])==2)key[0]^=1;
    SAPCacheEnvelopeDetails details;
    int result=SAPExtractCacheEnvelope(input,out,atoi(argv[3])?key:NULL,descriptor,&details);
    assert(result==atoi(argv[4]));
    if(result) {
        uint64_t count=0;int a,b;
        while((a=fgetc(expected))!=EOF){b=fgetc(out);assert(a==b);count++;}
        assert(fgetc(out)==EOF && count==details.payload_bytes && !strcmp(details.status,"ok"));
    }
    printf("%s\n",details.status);
    fclose(input);fclose(out);fclose(expected);
    return 0;
}
