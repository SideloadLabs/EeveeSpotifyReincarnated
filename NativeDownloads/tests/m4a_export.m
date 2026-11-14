#import <Foundation/Foundation.h>
#import "M4AExport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static double export_fraction;
static const char *test_output;
static int cancel_midway;
static int cancelled(void *ctx) { return cancel_midway && export_fraction > .2; }
static void progress(double value, void *ctx) { if(value<export_fraction || value>1 || (value<1 && access(test_output,F_OK)==0)) abort(); export_fraction=value; }
int main(int argc,char **argv) { @autoreleasepool {
 if(argc<3)return 99;
 test_output=argv[2];
 cancel_midway=argc>3&&!strcmp(argv[3],"cancel");
 NSData *cover=argc>4?[NSData dataWithContentsOfFile:@(argv[4])]:nil;
 const char *title=getenv("M4A_EXPORT_TEST_TITLE");
 SAPM4AExportMetadata tags={.title=title?:"Пісня – 日本語",.artist="Виконавець",.album="Альбом",.track="3/12",.year="2026",.jpeg_cover=cover.bytes,.jpeg_cover_length=cover.length};
 SAPM4AExportStatus status=SAPExportOggToM4A(argv[1],argv[2],&tags,cancelled,progress,NULL);
 printf("status=%d progress=%f\n",status,export_fraction);
 if(status==SAPM4AExportOK&&export_fraction!=1)return 98;
 return status;
}}
