#define _DARWIN_C_SOURCE 1
#include "matroska_tracks.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavutil/sha.h>
#include <libavutil/mem.h>
#define META_LIMIT (16u*1024u*1024u)
#define TRACK_LIMIT (4u*1024u*1024u)
#define ELEMENT_LIMIT 100000u
#define TRACKS_ID UINT64_C(0x1654AE6B)
typedef struct { uint64_t id, begin, data, end, size; int unknown; } Element;
struct MTECatalog { MTEFacts facts; MTETrack tracks[32]; char doc_type[16]; };
typedef struct { int fd; uint64_t bytes, io, elements, raw_total, skipped; int max_size; MTEError *error; MTECancellation cancellation; } Reader;
static int fail(Reader *r,uint64_t offset,const char *why){if(r->error){r->error->code=-1;r->error->offset=offset;snprintf(r->error->reason,sizeof(r->error->reason),"%s",why);}return -1;}
static int read_at(Reader*r,uint64_t offset,uint8_t *out,size_t count){
 if(r->cancellation.is_cancelled&&r->cancellation.is_cancelled(r->cancellation.context))return fail(r,offset,"cancelled");
 if(offset>r->bytes||count>r->bytes-offset)return fail(r,offset,"truncated element");
 if(count>META_LIMIT-r->io)return fail(r,offset,"metadata I/O limit");r->io+=count;
 size_t done=0;while(done<count){ssize_t n=pread(r->fd,out+done,count-done,(off_t)(offset+done));if(n<0&&errno==EINTR)continue;if(n<=0)return fail(r,offset+done,"pread failed or truncated");done+=(size_t)n;}return 0;
}
static int vint(Reader*r,uint64_t offset,int is_id,uint64_t *value,int *width,int *unknown){
 uint8_t b[8];if(read_at(r,offset,b,1))return -1;if(!b[0])return fail(r,offset,"invalid zero VINT marker");int n=1;uint8_t mask=0x80;while(!(b[0]&mask)){mask>>=1;n++;}
 if(n>(is_id?4:(r->max_size?r->max_size:8)))return fail(r,offset,"VINT exceeds Matroska width");if(n>1&&read_at(r,offset+1,b+1,(size_t)n-1))return -1;
 uint64_t data=b[0]&(mask-1),raw=b[0];for(int i=1;i<n;i++){data=(data<<8)|b[i];raw=(raw<<8)|b[i];}
 uint64_t all=(UINT64_C(1)<<(7*n))-1;
 if(is_id){if((!data&&raw!=0x80)||data==all)return fail(r,offset,"reserved element ID");if(n>1&&data<((UINT64_C(1)<<(7*(n-1)))-1))return fail(r,offset,"nonminimal element ID");}
 *value=is_id?raw:data;*width=n;*unknown=!is_id&&data==all;return 0;
}
static int element(Reader*r,uint64_t offset,uint64_t parent_end,Element*out){
 if(++r->elements>ELEMENT_LIMIT)return fail(r,offset,"element count limit");int n,m,unused;uint64_t id,size;if(vint(r,offset,1,&id,&n,&unused)||vint(r,offset+(unsigned)n,0,&size,&m,&unused))return -1;
 uint64_t data=offset+(unsigned)n+(unsigned)m;if(data>parent_end)return fail(r,offset,"element header exceeds parent");
 if(!unused&&size>parent_end-data)return fail(r,offset,"element size exceeds parent or file");*out=(Element){id,offset,data,unused?parent_end:data+size,size,unused};return 0;
}
static int number(Reader*r,Element e,uint64_t default_value,uint64_t*out){
 if(e.unknown||e.size>8)return fail(r,e.begin,"invalid unsigned integer size");if(!e.size){*out=default_value;return 0;}uint8_t b[8];if(read_at(r,e.data,b,(size_t)e.size))return -1;uint64_t x=0;for(unsigned i=0;i<e.size;i++)x=(x<<8)|b[i];*out=x;return 0;
}
static int flag(Reader*r,Element e,int def,int*out){uint64_t v;if(number(r,e,(uint64_t)def,&v))return -1;if(v>1)return fail(r,e.begin,"flag must be zero or one");*out=(int)v;return 0;}
static void sha(const uint8_t*p,size_t n,uint8_t out[32]){struct AVSHA*s=av_sha_alloc();if(!s)abort();av_sha_init(s,256);av_sha_update(s,p,n);av_sha_final(s,out);av_free(s);}
static int crc_parent(Reader*r,Element parent,Element crc){
 if(crc.size!=4||crc.begin!=parent.data)return fail(r,crc.begin,"CRC32 must be first and four bytes");uint8_t expected[4],buffer[4096];if(read_at(r,crc.data,expected,4))return -1;uint32_t state=UINT32_MAX;
 for(uint64_t at=crc.end;at<parent.end;){size_t n=(size_t)((parent.end-at)>sizeof(buffer)?sizeof(buffer):parent.end-at);if(read_at(r,at,buffer,n))return -1;for(size_t j=0;j<n;j++){state^=buffer[j];for(int k=0;k<8;k++)state=(state>>1)^(UINT32_C(0xedb88320)&(0u-(state&1u)));}at+=n;}
 uint32_t actual=~state,want=(uint32_t)expected[0]|((uint32_t)expected[1]<<8)|((uint32_t)expected[2]<<16)|((uint32_t)expected[3]<<24);return actual==want?0:fail(r,crc.begin,"CRC32 mismatch");
}
static int video(Reader*r,Element parent,MTETrack*t){
 uint64_t seen[128];size_t count=0;unsigned empty_display=0;t->has_video=1;
 for(uint64_t at=parent.data;at<parent.end;){Element e;if(element(r,at,parent.end,&e))return -1;if(e.unknown)return fail(r,at,"unknown-sized Video child");if(e.id!=0xec){for(size_t j=0;j<count;j++)if(seen[j]==e.id)return fail(r,at,"duplicate Video child ID");if(count==128)return fail(r,at,"Video child count limit");seen[count++]=e.id;}
 uint64_t*target=NULL;unsigned bit=0;switch(e.id){case 0xb0:target=&t->pixel_width;bit=1;break;case 0xba:target=&t->pixel_height;bit=2;break;case 0x54cc:target=&t->crop_left;bit=4;break;case 0x54dd:target=&t->crop_right;bit=8;break;case 0x54bb:target=&t->crop_top;bit=16;break;case 0x54aa:target=&t->crop_bottom;bit=32;break;case 0x54b0:target=&t->display_width;bit=64;break;case 0x54ba:target=&t->display_height;bit=128;break;case 0x54b2:target=&t->display_unit;bit=256;break;case 0x53c0:target=&t->alpha_mode;bit=512;break;case 0xbf:if(crc_parent(r,parent,e))return -1;break;default:break;}
 if(target){if(number(r,e,0,target))return -1;if(!e.size&&(bit==64||bit==128))empty_display|=bit;t->video_fields_present|=bit;}at=e.end;
 }
 if(!t->pixel_width||!t->pixel_height||t->crop_right>=t->pixel_width||t->crop_left>=t->pixel_width-t->crop_right||t->crop_bottom>=t->pixel_height||t->crop_top>=t->pixel_height-t->crop_bottom)return fail(r,parent.begin,"invalid/missing original Video pixel/crop geometry");
 if(!(t->video_fields_present&64)||(empty_display&64))t->display_width=t->display_unit==0?t->pixel_width-t->crop_left-t->crop_right:0;
 if(!(t->video_fields_present&128)||(empty_display&128))t->display_height=t->display_unit==0?t->pixel_height-t->crop_top-t->crop_bottom:0;
 if(t->alpha_mode>1)return fail(r,parent.begin,"unsupported AlphaMode");return 0;
}
static int track(Reader*r,Element entry,MTETrack*t){
 if(entry.unknown)return fail(r,entry.begin,"unknown-sized TrackEntry");if(entry.size>TRACK_LIMIT-r->raw_total)return fail(r,entry.begin,"TrackEntry payload byte limit");r->raw_total+=entry.size;
 uint8_t *raw=malloc((size_t)entry.size? (size_t)entry.size:1);if(!raw)return fail(r,entry.begin,"allocation failed");t->raw_entry=raw;t->raw_entry_size=(size_t)entry.size;t->entry_offset=entry.begin;if(read_at(r,entry.data,raw,(size_t)entry.size))return -1;sha(raw,(size_t)entry.size,t->entry_sha256);
 t->enabled=t->default_track=t->lacing=1;t->forced=0;uint64_t seen[256];size_t count=0;unsigned mandatory=0;
 for(uint64_t at=entry.data;at<entry.end;){Element e;if(element(r,at,entry.end,&e))return -1;if(e.unknown)return fail(r,at,"unknown-sized TrackEntry child");if(e.id!=0xec){for(size_t i=0;i<count;i++)if(seen[i]==e.id)return fail(r,at,"duplicate TrackEntry child ID");if(count==256)return fail(r,at,"TrackEntry child count limit");seen[count++]=e.id;}
  switch(e.id){
   case 0xd7:if(number(r,e,0,&t->number)||!t->number)return fail(r,at,"invalid TrackNumber");mandatory|=1;break;
   case 0x73c5:if(number(r,e,0,&t->uid)||!t->uid)return fail(r,at,"invalid TrackUID");mandatory|=2;break;
   case 0x83:if(number(r,e,0,&t->type)||!t->type)return fail(r,at,"invalid TrackType");mandatory|=4;break;
   case 0xb9:if(flag(r,e,1,&t->enabled))return -1;t->flags_present|=1;break;
   case 0x88:if(flag(r,e,1,&t->default_track))return -1;t->flags_present|=2;break;
   case 0x55aa:if(flag(r,e,0,&t->forced))return -1;t->flags_present|=4;break;
   case 0x9c:if(flag(r,e,1,&t->lacing))return -1;t->flags_present|=8;break;
   case 0x86:{if(!e.size||e.size>128)return fail(r,at,"invalid CodecID length");char*s=calloc((size_t)e.size+1,1);if(!s)return fail(r,at,"allocation failed");t->codec_id=s;if(read_at(r,e.data,(uint8_t*)s,(size_t)e.size))return -1;for(size_t i=0;i<e.size;i++){if(!s[i]){for(size_t j=i;j<e.size;j++)if(s[j])return fail(r,at,"nonzero bytes after CodecID padding");break;}if((unsigned char)s[i]<0x20||(unsigned char)s[i]>0x7e)return fail(r,at,"CodecID must be nonempty ASCII");}if(!s[0])return fail(r,at,"empty CodecID");mandatory|=8;break;}
   case 0x63a2:t->codec_private=raw+(e.data-entry.data);t->codec_private_size=(size_t)e.size;break;
   case 0xe0:if(video(r,e,t))return -1;break;
   case 0xbf:if(crc_parent(r,entry,e))return -1;break;
   default:break; /* Complete raw entry retains unprojected metadata. */
  }at=e.end;
 }
 if(mandatory!=15)return fail(r,entry.begin,"missing required TrackNumber/TrackUID/TrackType/CodecID");return 0;
}
static int header(Reader*r,Element h,char doc[16]){
 if(h.id!=0x1a45dfa3||h.unknown||h.size>4096)return fail(r,h.begin,"invalid EBML header");uint64_t seen[32];size_t count=0;int has_doc=0, max_size=8;
 for(uint64_t at=h.data;at<h.end;){Element e;if(element(r,at,h.end,&e))return -1;if(e.unknown)return fail(r,at,"unknown-sized EBML header child");if(e.id!=0xec){for(size_t i=0;i<count;i++)if(seen[i]==e.id)return fail(r,at,"duplicate EBML header child");if(count==32)return fail(r,at,"EBML header child count limit");seen[count++]=e.id;}
  uint64_t v;switch(e.id){
   case 0x4282:if(!e.size||e.size>=16||read_at(r,e.data,(uint8_t*)doc,(size_t)e.size))return fail(r,at,"invalid DocType");doc[e.size]=0;for(size_t j=0;j<e.size;j++){if(!doc[j]){for(size_t k=j;k<e.size;k++)if(doc[k])return fail(r,at,"nonzero bytes after DocType padding");break;}if((unsigned char)doc[j]<0x20||(unsigned char)doc[j]>0x7e)return fail(r,at,"invalid DocType ASCII");}if(strcmp(doc,"matroska")&&strcmp(doc,"webm"))return fail(r,at,"unsupported DocType");has_doc=1;break;
   case 0x42f2:if(number(r,e,4,&v)||v!=4)return fail(r,at,"Matroska requires EBMLMaxIDLength four");break;
   case 0x42f3:if(number(r,e,8,&v)||!v||v>8)return fail(r,at,"invalid EBMLMaxSizeLength");max_size=(int)v;break;
   case 0x42f7:if(number(r,e,1,&v)||v>1)return fail(r,at,"unsupported EBMLReadVersion");break;
   case 0x4285:if(number(r,e,1,&v)||v>4)return fail(r,at,"unsupported DocTypeReadVersion");break;
   case 0xbf:if(crc_parent(r,h,e))return -1;break;
   default:break;
  }at=e.end;
 }r->max_size=max_size;return has_doc?0:fail(r,h.begin,"missing DocType");
}
static int same_stat(const struct stat*a,const struct stat*b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
void mte_close(MTECatalog**p){if(!p||!*p)return;MTECatalog*c=*p;for(int i=0;i<32;i++){free((void*)c->tracks[i].codec_id);free((void*)c->tracks[i].raw_entry);}free(c);*p=NULL;}
int mte_read_fd_with_cancel(int fd,const uint8_t expected[32],int64_t expected_bytes,MTECancellation cancellation,MTECatalog**out,MTEError*error){
 if(!out||!expected)return -1;*out=NULL;if(error)memset(error,0,sizeof(*error));Reader r={.fd=fd,.error=error,.cancellation=cancellation};struct stat initial,final;
 if(fstat(fd,&initial)||!S_ISREG(initial.st_mode)||initial.st_size<0||initial.st_size!=expected_bytes)return fail(&r,0,"original FD size/type mismatch");r.bytes=(uint64_t)initial.st_size;
 MTECatalog*c=calloc(1,sizeof(*c));if(!c)return fail(&r,0,"allocation failed");struct AVSHA*s=av_sha_alloc();if(!s){mte_close(&c);return fail(&r,0,"allocation failed");}av_sha_init(s,256);uint8_t buffer[65536];
 for(uint64_t at=0;at<r.bytes;){if(cancellation.is_cancelled&&cancellation.is_cancelled(cancellation.context)){av_free(s);mte_close(&c);return fail(&r,at,"cancelled");}size_t n=(size_t)(r.bytes-at>sizeof(buffer)?sizeof(buffer):r.bytes-at);ssize_t got=pread(fd,buffer,n,(off_t)at);if(got<0&&errno==EINTR)continue;if(got<=0){av_free(s);mte_close(&c);return fail(&r,at,"source authentication read failed");}av_sha_update(s,buffer,(size_t)got);at+=(uint64_t)got;}
 av_sha_final(s,c->facts.source_sha256);av_free(s);if(memcmp(c->facts.source_sha256,expected,32)){mte_close(&c);return fail(&r,0,"original FD SHA256 mismatch");}
 Element h;if(element(&r,0,r.bytes,&h)||header(&r,h,c->doc_type))goto failed;uint64_t at=h.end;Element segment;
 for(;;){if(at>=r.bytes){fail(&r,at,"missing Segment");goto failed;}if(element(&r,at,r.bytes,&segment))goto failed;if(segment.id==0xec&&!segment.unknown){at=segment.end;continue;}break;}
 if(segment.id!=0x18538067){fail(&r,at,"expected one Matroska Segment");goto failed;}int tracks_seen=0;
 for(at=segment.data;at<segment.end;){Element e;if(element(&r,at,segment.end,&e))goto failed;if(e.unknown){fail(&r,at,"unknown-sized Segment child cannot be skipped safely");goto failed;}
  if(e.id==TRACKS_ID){if(tracks_seen++){fail(&r,at,"duplicate Tracks element");goto failed;}if(e.size>TRACK_LIMIT){fail(&r,at,"Tracks metadata byte limit");goto failed;}
   for(uint64_t child=e.data;child<e.end;){Element t;if(element(&r,child,e.end,&t))goto failed;if(t.unknown){fail(&r,child,"unknown-sized Tracks child");goto failed;}
    if(t.id==0xae){if(c->facts.count==32){fail(&r,child,"track count limit");goto failed;}MTETrack*next=&c->tracks[c->facts.count++];if(track(&r,t,next))goto failed;for(int i=0;i<c->facts.count-1;i++)if(c->tracks[i].number==next->number||c->tracks[i].uid==next->uid){fail(&r,child,"duplicate TrackNumber or TrackUID");goto failed;}}
    else if(t.id==0xbf){if(crc_parent(&r,e,t))goto failed;}else if(t.id!=0xec){fail(&r,child,"unknown direct Tracks child");goto failed;}child=t.end;
   }
  }else if(e.id==0x18538067||e.id==0x1a45dfa3){fail(&r,at,"nested/conflicting Segment or EBML header");goto failed;}else r.skipped+=e.size;
  at=e.end;
 }
 if(!tracks_seen||!c->facts.count){fail(&r,segment.begin,"missing/nonempty Tracks required");goto failed;}if(segment.end!=r.bytes){fail(&r,segment.end,"multiple document/trailing bytes unsupported");goto failed;}
 if(fstat(fd,&final)||!same_stat(&initial,&final)){fail(&r,0,"original FD changed during metadata read");goto failed;}
 c->facts.doc_type=c->doc_type;c->facts.source_bytes=expected_bytes;c->facts.metadata_read_bytes=r.io;c->facts.source_hash_read_bytes=r.bytes;c->facts.skipped_payload_bytes=r.skipped;*out=c;return 0;
 failed:mte_close(&c);return -1;
}
int mte_read_fd(int fd,const uint8_t expected[32],int64_t expected_bytes,MTECatalog**out,MTEError*error){return mte_read_fd_with_cancel(fd,expected,expected_bytes,(MTECancellation){0},out,error);}
int mte_facts(const MTECatalog*c,MTEFacts*out){if(!c||!out)return -1;*out=c->facts;return 0;}
int mte_track(const MTECatalog*c,int i,MTETrack*out){if(!c||!out||i<0||i>=c->facts.count)return -1;*out=c->tracks[i];return 0;}
