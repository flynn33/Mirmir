#include "bridge.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/pixdesc.h>
#include <libavutil/sha.h>
#include <libswresample/swresample.h>

typedef struct { MIBSource *source; int64_t offset; AVIOContext *io; AVFormatContext *format; } Input;
typedef struct { int resolution, bits, valid; int64_t base, previous_base; } VOPClock;
struct MIBSource {
    int fd; struct stat initial; uint8_t digest[32]; MIBLimits limits;
    atomic_int cancelled, references, cursors; atomic_ullong denied;
    Input inventory; char layouts[32][256]; MIBCancellation cancellation;
};
struct MIBCursor {
    MIBSource *source; Input input; int stream, kind;
    AVCodecContext *decoder; AVFrame *frame; AVPacket *packet;
    SwrContext *swr; AVChannelLayout audio_layout; int audio_format, audio_rate;
    uint8_t *scratch; size_t capacity;
    int packet_pending, sent_eof, eof; int64_t packet_ordinal, frame_ordinal;
    VOPClock vop; MIBTime seek_target; int seeking, seek_clock;
    char layout[256]; uint64_t audio_skip_remaining;
};
static int error_at(MIBError *error, const char *stage, int code) {
    if(error) { memset(error,0,sizeof(*error));error->code=code;
        snprintf(error->stage,sizeof(error->stage),"%s",stage);
        av_strerror(code,error->message,sizeof(error->message)); }
    return code;
}
static MIBTime time_at(int64_t value, AVRational base) {
    return (MIBTime){value!=AV_NOPTS_VALUE && base.num>0 && base.den>0,value,{base.num,base.den}};
}
static AVRational rational(MIBRational value) { return (AVRational){value.num,value.den}; }
static MIBRational facts_rational(AVRational value) {return (MIBRational){value.num,value.den};}
static int cancelled(MIBSource *s) {return (atomic_load(&s->cancelled) || (s->cancellation.is_cancelled && s->cancellation.is_cancelled(s->cancellation.context))) ? AVERROR(ECANCELED):0;}
static int same_stat(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size &&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static int check_source(MIBSource *s) {
    int code=cancelled(s);if(code<0)return code;struct stat now;
    if(fstat(s->fd,&now)<0)return AVERROR(errno);
    return same_stat(&s->initial,&now)?0:AVERROR(ESTALE);
}
static int sha_bytes(const uint8_t *data,size_t size,uint8_t out[32]) {
    struct AVSHA *sha=av_sha_alloc();if(!sha)return AVERROR(ENOMEM);
    av_sha_init(sha,256);if(size)av_sha_update(sha,data,size);av_sha_final(sha,out);av_free(sha);return 0;
}
static int hash_fd(MIBSource *s,uint8_t out[32]) {
    struct AVSHA *sha=av_sha_alloc();if(!sha)return AVERROR(ENOMEM);av_sha_init(sha,256);
    uint8_t buffer[65536];int64_t offset=0;int code=0;
    while(offset<s->initial.st_size) {
        if((code=check_source(s))<0)break;
        size_t count=(size_t)FFMIN((int64_t)sizeof(buffer),s->initial.st_size-offset);ssize_t n;
        do {n=pread(s->fd,buffer,count,offset);} while(n<0 && errno==EINTR);
        if(n<=0){code=n<0?AVERROR(errno):AVERROR(ESTALE);break;}
        av_sha_update(sha,buffer,(size_t)n);offset+=n;
    }
    if(code>=0){code=check_source(s);if(code>=0)av_sha_final(sha,out);}av_free(sha);return code;
}
static int io_read(void *opaque,uint8_t *buffer,int count) {
    Input *i=opaque;int code=check_source(i->source);if(code<0)return code;
    int64_t left=i->source->initial.st_size-i->offset;if(left<=0)return AVERROR_EOF;
    count=(int)FFMIN((int64_t)count,left);ssize_t n;
    do {n=pread(i->source->fd,buffer,(size_t)count,i->offset);} while(n<0 && errno==EINTR);
    if(n>0){i->offset+=n;return (int)n;}return n<0?AVERROR(errno):AVERROR(ESTALE);
}
static int64_t io_seek(void *opaque,int64_t offset,int whence) {
    Input *i=opaque;int code=check_source(i->source);if(code<0)return code;
    if((whence&~AVSEEK_FORCE)==AVSEEK_SIZE)return i->source->initial.st_size;
    int origin=whence&~AVSEEK_FORCE;int64_t base=origin==SEEK_SET?0:origin==SEEK_CUR?i->offset:
        origin==SEEK_END?i->source->initial.st_size:-1;
    if(base<0 || (offset>0 && base>INT64_MAX-offset) || (offset<0 && offset< -base))return AVERROR(EINVAL);
    int64_t next=base+offset;if(next<0 || next>i->source->initial.st_size)return AVERROR(EINVAL);
    i->offset=next;return next;
}
static int interrupt(void *opaque) {return cancelled(opaque)!=0;}
static int deny_open(AVFormatContext *format,AVIOContext **io,const char *url,int flags,AVDictionary **options) {
    (void)io;(void)url;(void)flags;(void)options;Input *i=format->opaque;
    if(i)atomic_fetch_add(&i->source->denied,1);return AVERROR(EPERM);
}
static void close_input(Input *i) {
    avformat_close_input(&i->format);if(i->io){av_freep(&i->io->buffer);avio_context_free(&i->io);}i->offset=0;
}
static int open_input(Input *i,MIBSource *source) {
    memset(i,0,sizeof(*i));i->source=source;int code=check_source(source);if(code<0)return code;
    uint8_t *buffer=av_malloc(65536);if(!buffer)return AVERROR(ENOMEM);
    i->io=avio_alloc_context(buffer,65536,0,i,io_read,NULL,io_seek);
    if(!i->io){av_free(buffer);return AVERROR(ENOMEM);}
    i->format=avformat_alloc_context();if(!i->format){close_input(i);return AVERROR(ENOMEM);}
    AVFormatContext *f=i->format;f->pb=i->io;f->opaque=i;f->flags|=AVFMT_FLAG_CUSTOM_IO;
    f->io_open=deny_open;f->interrupt_callback=(AVIOInterruptCB){interrupt,source};
    f->probesize=4*1024*1024;f->format_probesize=1024*1024;f->max_analyze_duration=5*AV_TIME_BASE;
    f->max_probe_packets=10000;f->max_streams=source->limits.streams;f->max_index_size=8*1024*1024;
    f->max_picture_buffer=16*1024*1024;
    code=avformat_open_input(&i->format,NULL,NULL,NULL);
    if(code>=0)code=avformat_find_stream_info(i->format,NULL);
    if(code>=0 && (i->format->nb_streams>(unsigned)source->limits.streams || i->format->nb_chapters>1024 || i->format->nb_programs>1024 || i->format->nb_stream_groups>1024))code=AVERROR(EFBIG);
    if(cancelled(source)<0)code=AVERROR(ECANCELED);if(code<0)close_input(i);return code;
}
static int metadata_bound(AVDictionary *dictionary,size_t limit) {
    size_t total=0;const AVDictionaryEntry *e=NULL;
    while((e=av_dict_iterate(dictionary,e))) {
        size_t a=strlen(e->key),b=strlen(e->value);
        if(a>limit-total || b>limit-total-a)return AVERROR(EFBIG);total+=a+b;
    }return 0;
}
MIBLimits mib_default_limits(void) {
    return (MIBLimits){64*1024*1024,64*1024*1024,1024*1024,32,8,8192,8192,32,262144};
}
static void release_source(MIBSource *s) {
    if(atomic_fetch_sub(&s->references,1)!=1)return;
    close_input(&s->inventory);close(s->fd);av_free(s);
}
int mib_source_open_fd_with_cancel(int fd,const uint8_t expected[32],int64_t bytes,const MIBLimits *limits,MIBCancellation cancellation,MIBSource **out,MIBError *error) {
    if(!out || !expected || bytes<0)return error_at(error,"source_arguments",AVERROR(EINVAL));*out=NULL;
    int mode=fcntl(fd,F_GETFL);if(mode<0)return error_at(error,"source_flags",AVERROR(errno));
    if((mode&O_ACCMODE)!=O_RDONLY)return error_at(error,"readonly_fd_required",AVERROR(EPERM));
    MIBSource *s=av_mallocz(sizeof(*s));if(!s)return error_at(error,"source_alloc",AVERROR(ENOMEM));
    s->fd=-1;s->cancellation=cancellation;s->limits=limits?*limits:mib_default_limits();atomic_init(&s->references,1);
    atomic_init(&s->cancelled,0);atomic_init(&s->cursors,0);atomic_init(&s->denied,0);
    if(s->limits.streams<1 || s->limits.streams>32 || s->limits.cursors<1 || s->limits.cursors>32 ||
       s->limits.packet_bytes<1 || s->limits.packet_bytes>INT_MAX || s->limits.frame_bytes<1 || s->limits.frame_bytes>INT_MAX ||
       s->limits.metadata_bytes<1 || s->limits.max_width<1 || s->limits.max_height<1 || s->limits.max_channels<1 ||
       s->limits.max_channels>32 || s->limits.max_audio_samples<1) {av_free(s);return error_at(error,"source_limits",AVERROR(EINVAL));}
    s->fd=fcntl(fd,F_DUPFD_CLOEXEC,0);if(s->fd<0){int c=AVERROR(errno);av_free(s);return error_at(error,"source_dup",c);}
    int code=fstat(s->fd,&s->initial)<0?AVERROR(errno):0;
    if(code>=0 && (!S_ISREG(s->initial.st_mode) || s->initial.st_size!=bytes))code=AVERROR(ESTALE);
    if(code>=0)code=hash_fd(s,s->digest);
    if(code>=0 && memcmp(expected,s->digest,32))code=AVERROR(ESTALE);
    if(code>=0)code=open_input(&s->inventory,s);
    if(code>=0)code=metadata_bound(s->inventory.format->metadata,s->limits.metadata_bytes);
    if(code>=0)for(unsigned n=0;n<s->inventory.format->nb_streams;n++) {
        AVStream *st=s->inventory.format->streams[n];AVCodecParameters *p=st->codecpar;
        if(p->ch_layout.nb_channels<0 || p->ch_layout.nb_channels>s->limits.max_channels || p->extradata_size<0 || (size_t)p->extradata_size>s->limits.metadata_bytes){code=AVERROR(EFBIG);break;}
        code=metadata_bound(st->metadata,s->limits.metadata_bytes);if(code<0)break;
        av_channel_layout_describe(&p->ch_layout,s->layouts[n],sizeof(s->layouts[n]));
    }
    if(code<0){release_source(s);return error_at(error,"source_authenticate_probe",code);}*out=s;return 0;
}
int mib_source_open_fd(int fd,const uint8_t expected[32],int64_t bytes,const MIBLimits *limits,MIBSource **out,MIBError *error) {
    return mib_source_open_fd_with_cancel(fd,expected,bytes,limits,(MIBCancellation){0},out,error);
}
void mib_source_close(MIBSource **s){if(s && *s){release_source(*s);*s=NULL;}}
void mib_source_cancel(MIBSource *s){if(s)atomic_store(&s->cancelled,1);}
int mib_source_authenticate(MIBSource *s,MIBError *e) {
    if(!s)return error_at(e,"authenticate_arguments",AVERROR(EINVAL));uint8_t digest[32];int code=hash_fd(s,digest);
    if(code>=0 && memcmp(digest,s->digest,32))code=AVERROR(ESTALE);return code<0?error_at(e,"source_reauthenticate",code):0;
}
int mib_asset_facts(MIBSource *s,MIBAssetFacts *o,MIBError *e) {
    if(!s || !o)return error_at(e,"asset_arguments",AVERROR(EINVAL));int code=check_source(s);if(code<0)return error_at(e,"asset_identity",code);
    AVFormatContext *f=s->inventory.format;memset(o,0,sizeof(*o));memcpy(o->sha256,s->digest,32);
    o->bytes=s->initial.st_size;o->device=s->initial.st_dev;o->inode=s->initial.st_ino;o->demuxer=f->iformat->name;
    o->start=time_at(f->start_time,AV_TIME_BASE_Q);o->duration=time_at(f->duration,AV_TIME_BASE_Q);
    o->streams=(int)f->nb_streams;o->chapters=(int)f->nb_chapters;o->programs=(int)f->nb_programs;o->groups=(int)f->nb_stream_groups;
    o->denied_secondary_opens=atomic_load(&s->denied);return 0;
}
int mib_stream_facts(MIBSource *s,int stream,MIBStreamFacts *o,MIBError *e) {
    if(!s || !o || stream<0 || stream>=(int)s->inventory.format->nb_streams)return error_at(e,"stream_arguments",AVERROR(EINVAL));
    AVStream *st=s->inventory.format->streams[stream];AVCodecParameters *p=st->codecpar;memset(o,0,sizeof(*o));
    o->ordinal=stream;o->container_id=st->id;o->media_type=p->codec_type;o->codec_id=p->codec_id;o->codec_tag=p->codec_tag;
    o->codec_name=avcodec_get_name(p->codec_id);o->profile=p->profile;o->level=p->level;o->disposition=st->disposition;
    o->width=p->width;o->height=p->height;o->pixel_format=p->format;o->raw_depth=p->bits_per_raw_sample;o->coded_depth=p->bits_per_coded_sample;
    o->color_range=p->color_range;o->primaries=p->color_primaries;o->transfer=p->color_trc;o->matrix=p->color_space;o->chroma_location=p->chroma_location;
    o->field_order=p->field_order;o->video_delay=p->video_delay;o->sample_rate=p->sample_rate;o->sample_format=p->format;o->channels=p->ch_layout.nb_channels;
    o->channel_order=p->ch_layout.order;o->channel_mask=(p->ch_layout.order==AV_CHANNEL_ORDER_NATIVE || p->ch_layout.order==AV_CHANNEL_ORDER_AMBISONIC)?p->ch_layout.u.mask:0;
    for(int n=0;n<p->ch_layout.nb_channels;n++)o->channel_id[n]=av_channel_layout_channel_from_index(&p->ch_layout,(unsigned)n);
    o->side_data_count=p->nb_coded_side_data;o->frame_size=p->frame_size;o->initial_padding=p->initial_padding;o->trailing_padding=p->trailing_padding;o->seek_preroll=p->seek_preroll;
    o->time_base=facts_rational(st->time_base);o->average_frame_rate=facts_rational(st->avg_frame_rate);o->real_frame_rate=facts_rational(st->r_frame_rate);
    o->sample_aspect_ratio=facts_rational(p->sample_aspect_ratio);o->start=time_at(st->start_time,st->time_base);o->duration=time_at(st->duration,st->time_base);
    o->declared_frames=st->nb_frames;o->channel_layout=s->layouts[stream];o->extradata=(MIBSpan){p->extradata,(size_t)p->extradata_size};return 0;
}
int mib_program_facts(MIBSource *s,int index,MIBProgramFacts *o,MIBError *e) {
    if(!s || !o || index<0 || index>=(int)s->inventory.format->nb_programs)return error_at(e,"program_arguments",AVERROR(EINVAL));
    AVProgram *p=s->inventory.format->programs[index];if(p->nb_stream_indexes>(unsigned)s->limits.streams)return error_at(e,"program_stream_bound",AVERROR(EFBIG));
    for(unsigned n=0;n<p->nb_stream_indexes;n++)if(p->stream_index[n]>=s->inventory.format->nb_streams)return error_at(e,"program_stream_index",AVERROR_INVALIDDATA);
    *o=(MIBProgramFacts){p->id,p->flags,p->discard,p->program_num,p->pmt_pid,p->pcr_pid,p->pmt_version,(int)p->nb_stream_indexes,p->stream_index};return 0;
}
int mib_program_metadata_count(MIBSource *s,int index,MIBError *e) {
    MIBProgramFacts p;int code=mib_program_facts(s,index,&p,e);if(code<0)return code;
    AVDictionary *d=s->inventory.format->programs[index]->metadata;code=metadata_bound(d,s->limits.metadata_bytes);
    return code<0?error_at(e,"program_metadata_bound",code):av_dict_count(d);
}
int mib_program_metadata_at(MIBSource *s,int index,int entry,const char **key,const char **value,MIBError *e) {
    int count=mib_program_metadata_count(s,index,e);if(count<0)return count;
    if(!key || !value || entry<0 || entry>=count)return error_at(e,"program_metadata_index",AVERROR(EINVAL));
    const AVDictionaryEntry *d=NULL;for(int n=0;n<=entry;n++)d=av_dict_iterate(s->inventory.format->programs[index]->metadata,d);
    *key=d->key;*value=d->value;return 0;
}
static AVDictionary *dictionary(MIBSource *s,int stream) {return stream<0?s->inventory.format->metadata:s->inventory.format->streams[stream]->metadata;}
int mib_metadata_count(MIBSource *s,int stream,MIBError *e) {
    if(!s || stream< -1 || stream>=(int)s->inventory.format->nb_streams)return error_at(e,"metadata_scope",AVERROR(EINVAL));
    return av_dict_count(dictionary(s,stream));
}
int mib_metadata_at(MIBSource *s,int stream,int index,const char **key,const char **value,MIBError *e) {
    int count=mib_metadata_count(s,stream,e);if(count<0)return count;
    if(!key || !value || index<0 || index>=count)return error_at(e,"metadata_index",AVERROR(EINVAL));
    const AVDictionaryEntry *entry=NULL;for(int n=0;n<=index;n++)entry=av_dict_iterate(dictionary(s,stream),entry);
    *key=entry->key;*value=entry->value;return 0;
}
int mib_stream_side_data(MIBSource *s,int stream,int index,MIBSideData *o,MIBError *e) {
    if(!s || !o || stream<0 || stream>=(int)s->inventory.format->nb_streams)return error_at(e,"stream_side_scope",AVERROR(EINVAL));
    AVCodecParameters *p=s->inventory.format->streams[stream]->codecpar;
    if(index<0 || index>=p->nb_coded_side_data)return error_at(e,"stream_side_index",AVERROR(ERANGE));
    AVPacketSideData *d=&p->coded_side_data[index];if(d->size>s->limits.metadata_bytes)return error_at(e,"stream_side_bound",AVERROR(EFBIG));
    *o=(MIBSideData){d->type,av_packet_side_data_name(d->type),{d->data,d->size}};return 0;
}

/* MPEG-4 prefix facts only. Raw decoder PTS is kept separately. A single-VOP
 * packet receives an exact bitstream time in its opaque identity. Multiple VOPs
 * remain explicitly unmapped rather than pretending COPY_OPAQUE is one-to-one.
 */
typedef struct {const uint8_t *data;size_t bits,at;} Bits;
static int read_bits(Bits *b,int count,int *out) {
    if(count<0 || count>24 || b->at>b->bits || (size_t)count>b->bits-b->at)return AVERROR_INVALIDDATA;
    int v=0;for(int n=0;n<count;n++){v=(v<<1)|((b->data[b->at/8]>>(7-b->at%8))&1);b->at++;}*out=v;return 0;
}
static int marker(Bits *b){int v;int c=read_bits(b,1,&v);return c<0?c:v==1?0:AVERROR_INVALIDDATA;}
#define BREAD(n,v) do {int bit_code=read_bits(&b,(n),&(v));if(bit_code<0)return bit_code;} while(0)
#define MARK() do {int bit_code=marker(&b);if(bit_code<0)return bit_code;} while(0)
static int parse_vol(const uint8_t *data,size_t size,VOPClock *clock) {
    Bits b={data,size*8,0};int v,object,version=1;BREAD(1,v);BREAD(8,object);if(object!=1 && object!=17)return AVERROR(ENOTSUP);
    BREAD(1,v);if(v){BREAD(4,version);BREAD(3,v);}BREAD(4,v);if(v==15)BREAD(16,v);
    BREAD(1,v);if(v){BREAD(2,v);if(v!=1)return AVERROR(ENOTSUP);BREAD(1,v);BREAD(1,v);
        if(v){int widths[]={15,15,15,14,15};for(int n=0;n<5;n++){BREAD(widths[n],v);MARK();}}}
    BREAD(2,v);if(v!=0)return AVERROR(ENOTSUP);MARK();int resolution;BREAD(16,resolution);if(!resolution)return AVERROR_INVALIDDATA;MARK();
    int width=1;while(width<16 && (1<<width)<resolution)width++;BREAD(1,v);if(v)BREAD(width,v);
    if(clock->valid && (clock->resolution!=resolution || clock->bits!=width))return AVERROR_INVALIDDATA;
    clock->resolution=resolution;clock->bits=width;clock->valid=1;(void)version;return 0;
}
static int packet_vop(VOPClock *clock,const uint8_t *data,size_t size,MIBPacketIdentity *identity) {
    int vops=0,code=0;MIBTime time={0};int type=-1;
    for(size_t i=0;i+4<=size;i++)if(data[i]==0 && data[i+1]==0 && data[i+2]==1) {
        size_t end=i+4;while(end+3<size && !(data[end]==0 && data[end+1]==0 && data[end+2]==1))end++;
        if(end+3>=size)end=size;const uint8_t *payload=data+i+4;size_t count=end-i-4;int kind=data[i+3];
        if(kind>=0x20 && kind<=0x2f){code=parse_vol(payload,count,clock);if(code<0)return code;}
        if(kind==0xb3){Bits b={payload,count*8,0};int h,m,s,v;BREAD(5,h);BREAD(6,m);MARK();BREAD(6,s);BREAD(2,v);
            if(h>=24 || m>=60 || s>=60)return AVERROR_INVALIDDATA;clock->base=h*3600+m*60+s;}
        if(kind==0xb6){vops++;if(!clock->valid)return AVERROR_INVALIDDATA;Bits b={payload,count*8,0};int modulo=0,v,increment;
            BREAD(2,type);if(type>2)return AVERROR(ENOTSUP);do{BREAD(1,v);if(v && ++modulo>65535)return AVERROR(EFBIG);}while(v);
            MARK();BREAD(clock->bits,increment);MARK();BREAD(1,v);if(!v || increment>=clock->resolution)return AVERROR_INVALIDDATA;
            int64_t base=type==2?clock->previous_base:clock->base;
            if(base>INT64_MAX-modulo)return AVERROR(EOVERFLOW);base+=modulo;
            if(base>(INT64_MAX-increment)/clock->resolution)return AVERROR(EOVERFLOW);
            if(type!=2){clock->previous_base=clock->base;clock->base=base;}
            time=time_at(base*clock->resolution+increment,(AVRational){1,clock->resolution});}
        i=end-1;
    }
    identity->vop_count=vops;identity->vop_type=type;if(vops==1)identity->vop_time=time;return 0;
}
#undef BREAD
#undef MARK
static void clear_decoder(MIBCursor *c) {
    avcodec_free_context(&c->decoder);av_frame_free(&c->frame);av_packet_free(&c->packet);
    swr_free(&c->swr);av_channel_layout_uninit(&c->audio_layout);
    c->audio_skip_remaining=0;c->packet_pending=c->sent_eof=c->eof=0;c->packet_ordinal=c->frame_ordinal=0;memset(&c->vop,0,sizeof(c->vop));
}
static int setup_cursor(MIBCursor *c) {
    int code=open_input(&c->input,c->source);if(code<0)return code;
    if(c->stream>=(int)c->input.format->nb_streams)return AVERROR_INVALIDDATA;
    AVStream *st=c->input.format->streams[c->stream];AVCodecParameters *p=st->codecpar;
    c->packet=av_packet_alloc();if(!c->packet)return AVERROR(ENOMEM);
    if(p->codec_id==AV_CODEC_ID_MPEG4 && p->extradata_size>0) {
        MIBPacketIdentity identity={0};code=packet_vop(&c->vop,p->extradata,(size_t)p->extradata_size,&identity);if(code<0)return code;
    }
    if(c->kind==MIB_PACKET_CURSOR)return 0;
    if((c->kind==MIB_VIDEO_CURSOR && p->codec_type!=AVMEDIA_TYPE_VIDEO) ||
       (c->kind==MIB_AUDIO_CURSOR && p->codec_type!=AVMEDIA_TYPE_AUDIO))return AVERROR(EINVAL);
    const AVCodec *codec=avcodec_find_decoder(p->codec_id);if(!codec)return AVERROR_DECODER_NOT_FOUND;
    if(codec->capabilities&AV_CODEC_CAP_HARDWARE)return AVERROR(ENOTSUP);
    c->decoder=avcodec_alloc_context3(codec);if(!c->decoder)return AVERROR(ENOMEM);
    code=avcodec_parameters_to_context(c->decoder,p);if(code<0)return code;
    c->decoder->pkt_timebase=st->time_base;c->decoder->thread_count=1;c->decoder->thread_type=0;
    c->decoder->flags|=AV_CODEC_FLAG_BITEXACT|AV_CODEC_FLAG_COPY_OPAQUE;
    c->decoder->flags2|=AV_CODEC_FLAG2_SKIP_MANUAL;c->decoder->apply_cropping=0;
    c->decoder->max_pixels=(int64_t)c->source->limits.max_width*c->source->limits.max_height;
    c->decoder->max_samples=c->source->limits.max_audio_samples;
    code=avcodec_open2(c->decoder,codec,NULL);if(code<0)return code;
    c->frame=av_frame_alloc();return c->frame?0:AVERROR(ENOMEM);
}
int mib_cursor_open(MIBSource *s,int stream,int kind,MIBCursor **out,MIBError *e) {
    if(!s || !out || stream<0 || stream>=(int)s->inventory.format->nb_streams || kind<0 || kind>2)return error_at(e,"cursor_arguments",AVERROR(EINVAL));*out=NULL;
    if(atomic_fetch_add(&s->cursors,1)>=s->limits.cursors){atomic_fetch_sub(&s->cursors,1);return error_at(e,"cursor_count_bound",AVERROR(EMFILE));}
    MIBCursor *c=av_mallocz(sizeof(*c));if(!c){atomic_fetch_sub(&s->cursors,1);return error_at(e,"cursor_alloc",AVERROR(ENOMEM));}
    c->source=s;c->stream=stream;c->kind=kind;atomic_fetch_add(&s->references,1);
    int code=setup_cursor(c);if(code<0){mib_cursor_close(&c);return error_at(e,"cursor_open",code);}*out=c;return 0;
}
void mib_cursor_close(MIBCursor **cursor) {
    if(!cursor || !*cursor)return;MIBCursor *c=*cursor;MIBSource *s=c->source;
    clear_decoder(c);close_input(&c->input);av_free(c->scratch);av_free(c);*cursor=NULL;
    atomic_fetch_sub(&s->cursors,1);release_source(s);
}
static int next_packet(MIBCursor *c) {
    if(!c->packet || !c->input.format)return AVERROR(EINVAL);
    av_packet_unref(c->packet);int code;
    for(;;){if((code=check_source(c->source))<0)return code;code=av_read_frame(c->input.format,c->packet);if(code<0)return code;
        if(c->packet->stream_index==c->stream)break;av_packet_unref(c->packet);}
    if(c->packet->size<0 || (size_t)c->packet->size>c->source->limits.packet_bytes)return AVERROR(EFBIG);
    size_t side_bytes=0;if(c->packet->side_data_elems<0 || c->packet->side_data_elems>1024)return AVERROR(EFBIG);
    for(int n=0;n<c->packet->side_data_elems;n++){size_t bytes=c->packet->side_data[n].size;
        if(bytes>c->source->limits.metadata_bytes-side_bytes)return AVERROR(EFBIG);side_bytes+=bytes;}
    if(c->packet_ordinal==INT64_MAX)return AVERROR(EOVERFLOW);
    MIBPacketIdentity identity={0};AVStream *st=c->input.format->streams[c->stream];AVPacket *p=c->packet;
    identity.ordinal=c->packet_ordinal++;identity.ordinal_valid=1;identity.position=p->pos;identity.flags=p->flags;
    identity.pts=time_at(p->pts,st->time_base);identity.dts=time_at(p->dts,st->time_base);identity.duration=time_at(p->duration,st->time_base);
    code=sha_bytes(p->data,(size_t)p->size,identity.payload_sha256);if(code<0)return code;
    if(st->codecpar->codec_id==AV_CODEC_ID_MPEG4){code=packet_vop(&c->vop,p->data,(size_t)p->size,&identity);if(code<0)return code;}
    av_buffer_unref(&p->opaque_ref);p->opaque_ref=av_buffer_alloc(sizeof(identity));if(!p->opaque_ref)return AVERROR(ENOMEM);
    memcpy(p->opaque_ref->data,&identity,sizeof(identity));return 0;
}
int mib_next_packet(MIBCursor *c,MIBPacket *o,MIBError *e) {
    if(!c || !o || c->kind!=MIB_PACKET_CURSOR)return error_at(e,"packet_arguments",AVERROR(EINVAL));
    int code=next_packet(c);if(code==AVERROR_EOF){code=check_source(c->source);return code<0?error_at(e,"packet_terminal_identity",code):0;}
    if(code<0)return error_at(e,"packet_read",code);memset(o,0,sizeof(*o));o->stream=c->stream;
    memcpy(&o->identity,c->packet->opaque_ref->data,sizeof(o->identity));o->bytes=(MIBSpan){c->packet->data,(size_t)c->packet->size};o->side_data_count=c->packet->side_data_elems;return 1;
}
int mib_packet_side_data(MIBCursor *c,int index,MIBSideData *o,MIBError *e) {
    if(!c || !o || !c->packet || index<0 || index>=c->packet->side_data_elems)return error_at(e,"packet_side_index",AVERROR(EINVAL));
    AVPacketSideData *d=&c->packet->side_data[index];if(d->size>c->source->limits.metadata_bytes)return error_at(e,"packet_side_bound",AVERROR(EFBIG));
    *o=(MIBSideData){d->type,av_packet_side_data_name(d->type),{d->data,d->size}};return 0;
}
static int ensure(MIBCursor *c,size_t bytes) {
    if(bytes>c->source->limits.frame_bytes)return AVERROR(EFBIG);if(bytes<=c->capacity)return 0;
    uint8_t *next=av_realloc(c->scratch,bytes);if(!next)return AVERROR(ENOMEM);c->scratch=next;c->capacity=bytes;return 0;
}
static int decoded_facts(MIBCursor *c,MIBDecodedFrame *o) {
    AVFrame *f=c->frame;AVStream *st=c->input.format->streams[c->stream];memset(o,0,sizeof(*o));
    if(c->frame_ordinal==INT64_MAX)return AVERROR(EOVERFLOW);
    size_t side_bytes=0;if(f->nb_side_data<0 || f->nb_side_data>1024)return AVERROR(EFBIG);
    for(int n=0;n<f->nb_side_data;n++){size_t bytes=f->side_data[n]->size;
        if(bytes>c->source->limits.metadata_bytes-side_bytes)return AVERROR(EFBIG);side_bytes+=bytes;}
    o->stream=c->stream;o->ordinal=c->frame_ordinal++;
    o->pts=time_at(f->pts,st->time_base);o->best_effort_pts=time_at(f->best_effort_timestamp,st->time_base);
    o->packet_dts=time_at(f->pkt_dts,st->time_base);o->duration=time_at(f->duration,st->time_base);
    if(f->opaque_ref && f->opaque_ref->size==sizeof(MIBPacketIdentity)){o->has_packet_identity=1;memcpy(&o->packet_identity,f->opaque_ref->data,sizeof(o->packet_identity));}
    o->flags=f->flags;o->decode_error_flags=f->decode_error_flags;o->side_data_count=f->nb_side_data;
    if(c->kind==MIB_VIDEO_CURSOR) {
        const AVPixFmtDescriptor *d=av_pix_fmt_desc_get(f->format);
        if(!d || (d->flags&(AV_PIX_FMT_FLAG_HWACCEL|AV_PIX_FMT_FLAG_PAL)) || f->width<=0 || f->height<=0 ||
           f->width>c->source->limits.max_width || f->height>c->source->limits.max_height)return AVERROR(EFBIG);
        int size=av_image_get_buffer_size(f->format,f->width,f->height,1);if(size<0)return size;int code=ensure(c,(size_t)size);if(code<0)return code;
        code=av_image_copy_to_buffer(c->scratch,size,(const uint8_t *const *)f->data,f->linesize,f->format,f->width,f->height,1);if(code<0)return code;
        uint8_t *planes[4];int lines[4];code=av_image_fill_arrays(planes,lines,c->scratch,f->format,f->width,f->height,1);if(code<0)return code;
        o->width=f->width;o->height=f->height;o->pixel_format=f->format;o->pixel_format_name=d->name;o->components=d->nb_components;
        o->depth=d->comp[0].depth;o->chroma_log2_width=d->log2_chroma_w;o->chroma_log2_height=d->log2_chroma_h;
        o->pixel_format_flags=d->flags;o->pixel_is_rgb=(d->flags&AV_PIX_FMT_FLAG_RGB)!=0;o->pixel_has_alpha=(d->flags&AV_PIX_FMT_FLAG_ALPHA)!=0;
        o->color_range=f->color_range;o->primaries=f->color_primaries;o->transfer=f->color_trc;o->matrix=f->colorspace;o->chroma_location=f->chroma_location;
        o->sample_aspect_ratio=facts_rational(f->sample_aspect_ratio);o->crop_left=f->crop_left;o->crop_right=f->crop_right;o->crop_top=f->crop_top;o->crop_bottom=f->crop_bottom;
        o->image_bytes=(MIBSpan){c->scratch,(size_t)size};
        for(int n=0;n<4;n++)if(planes[n]){int h=n==1||n==2?AV_CEIL_RSHIFT(f->height,d->log2_chroma_h):f->height;
            int w=n==1||n==2?AV_CEIL_RSHIFT(f->width,d->log2_chroma_w):f->width;
            o->plane[n]=(MIBPlane){{planes[n],(size_t)lines[n]*(size_t)h},lines[n],w,h};o->planes=n+1;}
        return 0;
    }
    if(f->nb_samples<0 || f->nb_samples>c->source->limits.max_audio_samples || f->sample_rate<=0 ||
       f->ch_layout.nb_channels<=0 || f->ch_layout.nb_channels>c->source->limits.max_channels)return AVERROR(EFBIG);
    if(!c->swr){c->audio_format=f->format;c->audio_rate=f->sample_rate;
        int code=av_channel_layout_copy(&c->audio_layout,&f->ch_layout);if(code<0)return code;
        code=swr_alloc_set_opts2(&c->swr,&c->audio_layout,AV_SAMPLE_FMT_S32,f->sample_rate,&f->ch_layout,f->format,f->sample_rate,0,NULL);if(code<0)return code;
        code=swr_init(c->swr);if(code<0)return code;}
    if(c->audio_format!=f->format || c->audio_rate!=f->sample_rate || av_channel_layout_compare(&c->audio_layout,&f->ch_layout))return AVERROR(ENOTSUP);
    int capacity=swr_get_out_samples(c->swr,f->nb_samples);if(capacity<0)return capacity;
    size_t bytes=(size_t)capacity*(size_t)f->ch_layout.nb_channels*4;int code=ensure(c,bytes);if(code<0)return code;
    uint8_t *output[]={c->scratch};int count=swr_convert(c->swr,output,capacity,(const uint8_t **)f->extended_data,f->nb_samples);if(count<0)return count;
    o->channel_order=f->ch_layout.order;o->channel_mask=(f->ch_layout.order==AV_CHANNEL_ORDER_NATIVE || f->ch_layout.order==AV_CHANNEL_ORDER_AMBISONIC)?f->ch_layout.u.mask:0;
    for(int n=0;n<f->ch_layout.nb_channels;n++)o->channel_id[n]=av_channel_layout_channel_from_index(&f->ch_layout,(unsigned)n);
    o->sample_rate=f->sample_rate;o->channels=f->ch_layout.nb_channels;o->native_sample_format=f->format;o->decoded_samples=f->nb_samples;o->normalized_samples=count;
    av_channel_layout_describe(&f->ch_layout,c->layout,sizeof(c->layout));o->channel_layout=c->layout;
    o->s32_interleaved=(MIBSpan){c->scratch,(size_t)count*(size_t)o->channels*4};
    AVFrameSideData *skip=av_frame_get_side_data(f,AV_FRAME_DATA_SKIP_SAMPLES);
    if(skip){if(skip->size<10)return AVERROR_INVALIDDATA;o->skip_start=AV_RL32(skip->data);o->skip_end=AV_RL32(skip->data+4);o->skip_start_reason=skip->data[8];o->skip_end_reason=skip->data[9];
        c->audio_skip_remaining=o->skip_start;}
    o->audible_offset=(int)FFMIN(c->audio_skip_remaining,(uint64_t)f->nb_samples);
    c->audio_skip_remaining-=(uint64_t)o->audible_offset;
    o->audible_samples=f->nb_samples-o->audible_offset;
    if(f->flags&AV_FRAME_FLAG_DISCARD)o->audible_samples=0;
    else if(o->skip_end<=(uint32_t)o->audible_samples)o->audible_samples-=(int)o->skip_end;
    else if(o->skip_end)return AVERROR(ENOTSUP);
    /* Same-rate format conversion must not introduce a hidden sample delay. */
    if(count!=f->nb_samples || swr_get_delay(c->swr,f->sample_rate)!=0)return AVERROR(ENOTSUP);
    return 0;
}
static int audio_end_before(MIBTime p,int samples,int rate,MIBTime target,int *before) {
    /* Exact rational overlap; fail rather than overflow on extreme clocks. */
    int64_t a=p.base.den,b=rate;while(b){int64_t remainder=a%b;a=b;b=remainder;}
    int64_t factor=rate/a,den=(int64_t)p.base.den*factor;
    __int128 n=(__int128)p.value*p.base.num*factor+(__int128)samples*(p.base.den/a);
    __int128 left,right,scaled=(__int128)target.value*target.base.num;
    if(__builtin_mul_overflow(n,(__int128)target.base.den,&left) || __builtin_mul_overflow(scaled,(__int128)den,&right))return AVERROR(EOVERFLOW);
    *before=left<=right;return 0;
}
int mib_next_frame(MIBCursor *c,MIBDecodedFrame *o,MIBError *e) {
    if(!c || !o || c->kind==MIB_PACKET_CURSOR || !c->frame || !c->decoder)return error_at(e,"frame_arguments",AVERROR(EINVAL));
    av_frame_unref(c->frame);
    for(;;) {
        int code=check_source(c->source);if(code<0)return error_at(e,"frame_source",code);
        code=avcodec_receive_frame(c->decoder,c->frame);
        if(code==0) {
            code=decoded_facts(c,o);if(code<0)return error_at(e,"decoded_sample_facts",code);
            if(c->seeking) {
                MIBTime p=c->seek_clock==MIB_MPEG4_VOP_CLOCK?o->packet_identity.vop_time:o->pts;
                if(!p.valid)return error_at(e,"seek_unknown_frame_clock",AVERROR(ENODATA));
                int before=av_compare_ts(p.value,rational(p.base),c->seek_target.value,rational(c->seek_target.base))<0;
                if(c->kind==MIB_AUDIO_CURSOR && before) {
                    code=audio_end_before(p,o->normalized_samples,o->sample_rate,c->seek_target,&before);
                    if(code<0)return error_at(e,"seek_audio_rational_overflow",code);
                }
                if(before){av_frame_unref(c->frame);continue;}c->seeking=0;
            }
            return 1;
        }
        if(code==AVERROR_EOF){if(c->swr && swr_get_delay(c->swr,c->audio_rate)!=0)return error_at(e,"audio_undrained_delay",AVERROR(ENOTSUP));c->eof=1;return 0;}
        if(code!=AVERROR(EAGAIN))return error_at(e,"decoder_receive",code);
        if(c->sent_eof)return error_at(e,"decoder_incomplete_terminal_drain",AVERROR_INVALIDDATA);
        if(!c->packet_pending) {
            code=next_packet(c);
            if(code==AVERROR_EOF){code=avcodec_send_packet(c->decoder,NULL);if(code<0 && code!=AVERROR_EOF)return error_at(e,"decoder_send_drain",code);c->sent_eof=1;continue;}
            if(code<0)return error_at(e,"decoder_demux",code);c->packet_pending=1;
        }
        code=avcodec_send_packet(c->decoder,c->packet);
        if(code==AVERROR(EAGAIN))return error_at(e,"decoder_send_receive_stall",AVERROR_BUG);
        if(code<0)return error_at(e,"decoder_send",code);
        c->packet_pending=0;av_packet_unref(c->packet);
    }
}
int mib_frame_side_data(MIBCursor *c,int index,MIBSideData *o,MIBError *e) {
    if(!c || !o || !c->frame || index<0 || index>=c->frame->nb_side_data)return error_at(e,"frame_side_index",AVERROR(EINVAL));
    AVFrameSideData *d=c->frame->side_data[index];if(d->size>c->source->limits.metadata_bytes)return error_at(e,"frame_side_bound",AVERROR(EFBIG));
    *o=(MIBSideData){d->type,av_frame_side_data_name(d->type),{d->data,d->size}};return 0;
}
int mib_cursor_rewind(MIBCursor *c,MIBError *e) {
    if(!c)return error_at(e,"rewind_arguments",AVERROR(EINVAL));
    if(c->decoder)avcodec_flush_buffers(c->decoder);clear_decoder(c);close_input(&c->input);c->seeking=0;
    int code=setup_cursor(c);return code<0?error_at(e,"rewind_reopen_flush",code):0;
}
int mib_cursor_seek_with_clock(MIBCursor *c,MIBTime target,int clock,MIBError *e) {
    if(!c || c->kind==MIB_PACKET_CURSOR || !target.valid || target.base.num<=0 || target.base.den<=0 || clock<0 || clock>1 || (clock==MIB_MPEG4_VOP_CLOCK && (c->kind!=MIB_VIDEO_CURSOR || !c->input.format || c->input.format->streams[c->stream]->codecpar->codec_id!=AV_CODEC_ID_MPEG4)))return error_at(e,"seek_arguments",AVERROR(EINVAL));
    int code=mib_cursor_rewind(c,e);if(code<0)return code;c->seek_target=target;c->seek_clock=clock;c->seeking=1;return 0;
}
int mib_cursor_seek(MIBCursor *c,MIBTime target,MIBError *e) {return mib_cursor_seek_with_clock(c,target,MIB_RAW_FRAME_CLOCK,e);}
size_t mib_cursor_scratch_capacity(const MIBCursor *c){return c?c->capacity:0;}

/* ABI/loaded-image facts for explicit private decoder policy identity. */
#include <dlfcn.h>
#include <libswscale/swscale.h>
#include "matroska_tracks.h"
#include "carrier_pixels.h"
int mib_copy_abi_contract_v1(char *output, size_t capacity) {
 char data[32768]; size_t used=0;
 #define ABI_APPEND(...) do { int n=snprintf(data+used,sizeof(data)-used,__VA_ARGS__); if(n<0 || (size_t)n>=sizeof(data)-used)return -EOVERFLOW; used+=(size_t)n; } while(0)
 const uint16_t endian=1;
 ABI_APPEND("{\"schemaID\":\"mirmir.software-input-bridge-abi.v1\",\"bridgeABIVersion\":1,\"pointerBytes\":%zu,\"littleEndian\":%s,\"types\":{",sizeof(void *),*(const uint8_t *)&endian ? "true":"false");
 ABI_APPEND("\"MIBAssetFacts\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBAssetFacts),_Alignof(MIBAssetFacts));
 ABI_APPEND("\"sha256\":%zu",offsetof(MIBAssetFacts,sha256));
 ABI_APPEND(",\"bytes\":%zu",offsetof(MIBAssetFacts,bytes));
 ABI_APPEND(",\"device\":%zu",offsetof(MIBAssetFacts,device));
 ABI_APPEND(",\"inode\":%zu",offsetof(MIBAssetFacts,inode));
 ABI_APPEND(",\"demuxer\":%zu",offsetof(MIBAssetFacts,demuxer));
 ABI_APPEND(",\"start\":%zu",offsetof(MIBAssetFacts,start));
 ABI_APPEND(",\"duration\":%zu",offsetof(MIBAssetFacts,duration));
 ABI_APPEND(",\"streams\":%zu",offsetof(MIBAssetFacts,streams));
 ABI_APPEND(",\"chapters\":%zu",offsetof(MIBAssetFacts,chapters));
 ABI_APPEND(",\"programs\":%zu",offsetof(MIBAssetFacts,programs));
 ABI_APPEND(",\"groups\":%zu",offsetof(MIBAssetFacts,groups));
 ABI_APPEND(",\"denied_secondary_opens\":%zu",offsetof(MIBAssetFacts,denied_secondary_opens));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBCancellation\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBCancellation),_Alignof(MIBCancellation));
 ABI_APPEND("\"is_cancelled\":%zu",offsetof(MIBCancellation,is_cancelled));
 ABI_APPEND(",\"context\":%zu",offsetof(MIBCancellation,context));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBDecodedFrame\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBDecodedFrame),_Alignof(MIBDecodedFrame));
 ABI_APPEND("\"stream\":%zu",offsetof(MIBDecodedFrame,stream));
 ABI_APPEND(",\"ordinal\":%zu",offsetof(MIBDecodedFrame,ordinal));
 ABI_APPEND(",\"pts\":%zu",offsetof(MIBDecodedFrame,pts));
 ABI_APPEND(",\"best_effort_pts\":%zu",offsetof(MIBDecodedFrame,best_effort_pts));
 ABI_APPEND(",\"duration\":%zu",offsetof(MIBDecodedFrame,duration));
 ABI_APPEND(",\"packet_dts\":%zu",offsetof(MIBDecodedFrame,packet_dts));
 ABI_APPEND(",\"has_packet_identity\":%zu",offsetof(MIBDecodedFrame,has_packet_identity));
 ABI_APPEND(",\"packet_identity\":%zu",offsetof(MIBDecodedFrame,packet_identity));
 ABI_APPEND(",\"flags\":%zu",offsetof(MIBDecodedFrame,flags));
 ABI_APPEND(",\"decode_error_flags\":%zu",offsetof(MIBDecodedFrame,decode_error_flags));
 ABI_APPEND(",\"side_data_count\":%zu",offsetof(MIBDecodedFrame,side_data_count));
 ABI_APPEND(",\"pixel_format\":%zu",offsetof(MIBDecodedFrame,pixel_format));
 ABI_APPEND(",\"width\":%zu",offsetof(MIBDecodedFrame,width));
 ABI_APPEND(",\"height\":%zu",offsetof(MIBDecodedFrame,height));
 ABI_APPEND(",\"planes\":%zu",offsetof(MIBDecodedFrame,planes));
 ABI_APPEND(",\"components\":%zu",offsetof(MIBDecodedFrame,components));
 ABI_APPEND(",\"depth\":%zu",offsetof(MIBDecodedFrame,depth));
 ABI_APPEND(",\"chroma_log2_width\":%zu",offsetof(MIBDecodedFrame,chroma_log2_width));
 ABI_APPEND(",\"chroma_log2_height\":%zu",offsetof(MIBDecodedFrame,chroma_log2_height));
 ABI_APPEND(",\"pixel_format_flags\":%zu",offsetof(MIBDecodedFrame,pixel_format_flags));
 ABI_APPEND(",\"pixel_is_rgb\":%zu",offsetof(MIBDecodedFrame,pixel_is_rgb));
 ABI_APPEND(",\"pixel_has_alpha\":%zu",offsetof(MIBDecodedFrame,pixel_has_alpha));
 ABI_APPEND(",\"pixel_format_name\":%zu",offsetof(MIBDecodedFrame,pixel_format_name));
 ABI_APPEND(",\"color_range\":%zu",offsetof(MIBDecodedFrame,color_range));
 ABI_APPEND(",\"primaries\":%zu",offsetof(MIBDecodedFrame,primaries));
 ABI_APPEND(",\"transfer\":%zu",offsetof(MIBDecodedFrame,transfer));
 ABI_APPEND(",\"matrix\":%zu",offsetof(MIBDecodedFrame,matrix));
 ABI_APPEND(",\"chroma_location\":%zu",offsetof(MIBDecodedFrame,chroma_location));
 ABI_APPEND(",\"sample_aspect_ratio\":%zu",offsetof(MIBDecodedFrame,sample_aspect_ratio));
 ABI_APPEND(",\"crop_left\":%zu",offsetof(MIBDecodedFrame,crop_left));
 ABI_APPEND(",\"crop_right\":%zu",offsetof(MIBDecodedFrame,crop_right));
 ABI_APPEND(",\"crop_top\":%zu",offsetof(MIBDecodedFrame,crop_top));
 ABI_APPEND(",\"crop_bottom\":%zu",offsetof(MIBDecodedFrame,crop_bottom));
 ABI_APPEND(",\"plane\":%zu",offsetof(MIBDecodedFrame,plane));
 ABI_APPEND(",\"image_bytes\":%zu",offsetof(MIBDecodedFrame,image_bytes));
 ABI_APPEND(",\"sample_rate\":%zu",offsetof(MIBDecodedFrame,sample_rate));
 ABI_APPEND(",\"channels\":%zu",offsetof(MIBDecodedFrame,channels));
 ABI_APPEND(",\"native_sample_format\":%zu",offsetof(MIBDecodedFrame,native_sample_format));
 ABI_APPEND(",\"decoded_samples\":%zu",offsetof(MIBDecodedFrame,decoded_samples));
 ABI_APPEND(",\"normalized_samples\":%zu",offsetof(MIBDecodedFrame,normalized_samples));
 ABI_APPEND(",\"channel_layout\":%zu",offsetof(MIBDecodedFrame,channel_layout));
 ABI_APPEND(",\"channel_order\":%zu",offsetof(MIBDecodedFrame,channel_order));
 ABI_APPEND(",\"channel_id\":%zu",offsetof(MIBDecodedFrame,channel_id));
 ABI_APPEND(",\"channel_mask\":%zu",offsetof(MIBDecodedFrame,channel_mask));
 ABI_APPEND(",\"skip_start\":%zu",offsetof(MIBDecodedFrame,skip_start));
 ABI_APPEND(",\"skip_end\":%zu",offsetof(MIBDecodedFrame,skip_end));
 ABI_APPEND(",\"skip_start_reason\":%zu",offsetof(MIBDecodedFrame,skip_start_reason));
 ABI_APPEND(",\"skip_end_reason\":%zu",offsetof(MIBDecodedFrame,skip_end_reason));
 ABI_APPEND(",\"audible_offset\":%zu",offsetof(MIBDecodedFrame,audible_offset));
 ABI_APPEND(",\"audible_samples\":%zu",offsetof(MIBDecodedFrame,audible_samples));
 ABI_APPEND(",\"s32_interleaved\":%zu",offsetof(MIBDecodedFrame,s32_interleaved));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBError\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBError),_Alignof(MIBError));
 ABI_APPEND("\"code\":%zu",offsetof(MIBError,code));
 ABI_APPEND(",\"stage\":%zu",offsetof(MIBError,stage));
 ABI_APPEND(",\"message\":%zu",offsetof(MIBError,message));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBLimits\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBLimits),_Alignof(MIBLimits));
 ABI_APPEND("\"packet_bytes\":%zu",offsetof(MIBLimits,packet_bytes));
 ABI_APPEND(",\"frame_bytes\":%zu",offsetof(MIBLimits,frame_bytes));
 ABI_APPEND(",\"metadata_bytes\":%zu",offsetof(MIBLimits,metadata_bytes));
 ABI_APPEND(",\"streams\":%zu",offsetof(MIBLimits,streams));
 ABI_APPEND(",\"cursors\":%zu",offsetof(MIBLimits,cursors));
 ABI_APPEND(",\"max_width\":%zu",offsetof(MIBLimits,max_width));
 ABI_APPEND(",\"max_height\":%zu",offsetof(MIBLimits,max_height));
 ABI_APPEND(",\"max_channels\":%zu",offsetof(MIBLimits,max_channels));
 ABI_APPEND(",\"max_audio_samples\":%zu",offsetof(MIBLimits,max_audio_samples));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBPacket\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBPacket),_Alignof(MIBPacket));
 ABI_APPEND("\"stream\":%zu",offsetof(MIBPacket,stream));
 ABI_APPEND(",\"identity\":%zu",offsetof(MIBPacket,identity));
 ABI_APPEND(",\"bytes\":%zu",offsetof(MIBPacket,bytes));
 ABI_APPEND(",\"side_data_count\":%zu",offsetof(MIBPacket,side_data_count));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBPacketIdentity\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBPacketIdentity),_Alignof(MIBPacketIdentity));
 ABI_APPEND("\"ordinal\":%zu",offsetof(MIBPacketIdentity,ordinal));
 ABI_APPEND(",\"position\":%zu",offsetof(MIBPacketIdentity,position));
 ABI_APPEND(",\"ordinal_valid\":%zu",offsetof(MIBPacketIdentity,ordinal_valid));
 ABI_APPEND(",\"payload_sha256\":%zu",offsetof(MIBPacketIdentity,payload_sha256));
 ABI_APPEND(",\"pts\":%zu",offsetof(MIBPacketIdentity,pts));
 ABI_APPEND(",\"dts\":%zu",offsetof(MIBPacketIdentity,dts));
 ABI_APPEND(",\"duration\":%zu",offsetof(MIBPacketIdentity,duration));
 ABI_APPEND(",\"vop_time\":%zu",offsetof(MIBPacketIdentity,vop_time));
 ABI_APPEND(",\"flags\":%zu",offsetof(MIBPacketIdentity,flags));
 ABI_APPEND(",\"vop_type\":%zu",offsetof(MIBPacketIdentity,vop_type));
 ABI_APPEND(",\"vop_count\":%zu",offsetof(MIBPacketIdentity,vop_count));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBPlane\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBPlane),_Alignof(MIBPlane));
 ABI_APPEND("\"bytes\":%zu",offsetof(MIBPlane,bytes));
 ABI_APPEND(",\"row_bytes\":%zu",offsetof(MIBPlane,row_bytes));
 ABI_APPEND(",\"width\":%zu",offsetof(MIBPlane,width));
 ABI_APPEND(",\"height\":%zu",offsetof(MIBPlane,height));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBProgramFacts\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBProgramFacts),_Alignof(MIBProgramFacts));
 ABI_APPEND("\"id\":%zu",offsetof(MIBProgramFacts,id));
 ABI_APPEND(",\"flags\":%zu",offsetof(MIBProgramFacts,flags));
 ABI_APPEND(",\"discard\":%zu",offsetof(MIBProgramFacts,discard));
 ABI_APPEND(",\"program_number\":%zu",offsetof(MIBProgramFacts,program_number));
 ABI_APPEND(",\"pmt_pid\":%zu",offsetof(MIBProgramFacts,pmt_pid));
 ABI_APPEND(",\"pcr_pid\":%zu",offsetof(MIBProgramFacts,pcr_pid));
 ABI_APPEND(",\"pmt_version\":%zu",offsetof(MIBProgramFacts,pmt_version));
 ABI_APPEND(",\"stream_count\":%zu",offsetof(MIBProgramFacts,stream_count));
 ABI_APPEND(",\"stream_ordinals\":%zu",offsetof(MIBProgramFacts,stream_ordinals));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBRational\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBRational),_Alignof(MIBRational));
 ABI_APPEND("\"num\":%zu",offsetof(MIBRational,num));
 ABI_APPEND(",\"den\":%zu",offsetof(MIBRational,den));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBSideData\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBSideData),_Alignof(MIBSideData));
 ABI_APPEND("\"type\":%zu",offsetof(MIBSideData,type));
 ABI_APPEND(",\"name\":%zu",offsetof(MIBSideData,name));
 ABI_APPEND(",\"bytes\":%zu",offsetof(MIBSideData,bytes));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBSpan\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBSpan),_Alignof(MIBSpan));
 ABI_APPEND("\"data\":%zu",offsetof(MIBSpan,data));
 ABI_APPEND(",\"size\":%zu",offsetof(MIBSpan,size));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBStreamFacts\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBStreamFacts),_Alignof(MIBStreamFacts));
 ABI_APPEND("\"ordinal\":%zu",offsetof(MIBStreamFacts,ordinal));
 ABI_APPEND(",\"container_id\":%zu",offsetof(MIBStreamFacts,container_id));
 ABI_APPEND(",\"media_type\":%zu",offsetof(MIBStreamFacts,media_type));
 ABI_APPEND(",\"codec_id\":%zu",offsetof(MIBStreamFacts,codec_id));
 ABI_APPEND(",\"codec_tag\":%zu",offsetof(MIBStreamFacts,codec_tag));
 ABI_APPEND(",\"codec_name\":%zu",offsetof(MIBStreamFacts,codec_name));
 ABI_APPEND(",\"profile\":%zu",offsetof(MIBStreamFacts,profile));
 ABI_APPEND(",\"level\":%zu",offsetof(MIBStreamFacts,level));
 ABI_APPEND(",\"disposition\":%zu",offsetof(MIBStreamFacts,disposition));
 ABI_APPEND(",\"width\":%zu",offsetof(MIBStreamFacts,width));
 ABI_APPEND(",\"height\":%zu",offsetof(MIBStreamFacts,height));
 ABI_APPEND(",\"pixel_format\":%zu",offsetof(MIBStreamFacts,pixel_format));
 ABI_APPEND(",\"raw_depth\":%zu",offsetof(MIBStreamFacts,raw_depth));
 ABI_APPEND(",\"coded_depth\":%zu",offsetof(MIBStreamFacts,coded_depth));
 ABI_APPEND(",\"color_range\":%zu",offsetof(MIBStreamFacts,color_range));
 ABI_APPEND(",\"primaries\":%zu",offsetof(MIBStreamFacts,primaries));
 ABI_APPEND(",\"transfer\":%zu",offsetof(MIBStreamFacts,transfer));
 ABI_APPEND(",\"matrix\":%zu",offsetof(MIBStreamFacts,matrix));
 ABI_APPEND(",\"chroma_location\":%zu",offsetof(MIBStreamFacts,chroma_location));
 ABI_APPEND(",\"field_order\":%zu",offsetof(MIBStreamFacts,field_order));
 ABI_APPEND(",\"video_delay\":%zu",offsetof(MIBStreamFacts,video_delay));
 ABI_APPEND(",\"sample_rate\":%zu",offsetof(MIBStreamFacts,sample_rate));
 ABI_APPEND(",\"sample_format\":%zu",offsetof(MIBStreamFacts,sample_format));
 ABI_APPEND(",\"channels\":%zu",offsetof(MIBStreamFacts,channels));
 ABI_APPEND(",\"frame_size\":%zu",offsetof(MIBStreamFacts,frame_size));
 ABI_APPEND(",\"initial_padding\":%zu",offsetof(MIBStreamFacts,initial_padding));
 ABI_APPEND(",\"trailing_padding\":%zu",offsetof(MIBStreamFacts,trailing_padding));
 ABI_APPEND(",\"seek_preroll\":%zu",offsetof(MIBStreamFacts,seek_preroll));
 ABI_APPEND(",\"side_data_count\":%zu",offsetof(MIBStreamFacts,side_data_count));
 ABI_APPEND(",\"channel_order\":%zu",offsetof(MIBStreamFacts,channel_order));
 ABI_APPEND(",\"channel_id\":%zu",offsetof(MIBStreamFacts,channel_id));
 ABI_APPEND(",\"channel_mask\":%zu",offsetof(MIBStreamFacts,channel_mask));
 ABI_APPEND(",\"time_base\":%zu",offsetof(MIBStreamFacts,time_base));
 ABI_APPEND(",\"average_frame_rate\":%zu",offsetof(MIBStreamFacts,average_frame_rate));
 ABI_APPEND(",\"real_frame_rate\":%zu",offsetof(MIBStreamFacts,real_frame_rate));
 ABI_APPEND(",\"sample_aspect_ratio\":%zu",offsetof(MIBStreamFacts,sample_aspect_ratio));
 ABI_APPEND(",\"start\":%zu",offsetof(MIBStreamFacts,start));
 ABI_APPEND(",\"duration\":%zu",offsetof(MIBStreamFacts,duration));
 ABI_APPEND(",\"declared_frames\":%zu",offsetof(MIBStreamFacts,declared_frames));
 ABI_APPEND(",\"channel_layout\":%zu",offsetof(MIBStreamFacts,channel_layout));
 ABI_APPEND(",\"extradata\":%zu",offsetof(MIBStreamFacts,extradata));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MIBTime\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MIBTime),_Alignof(MIBTime));
 ABI_APPEND("\"valid\":%zu",offsetof(MIBTime,valid));
 ABI_APPEND(",\"value\":%zu",offsetof(MIBTime,value));
 ABI_APPEND(",\"base\":%zu",offsetof(MIBTime,base));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MTECancellation\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MTECancellation),_Alignof(MTECancellation));
 ABI_APPEND("\"is_cancelled\":%zu",offsetof(MTECancellation,is_cancelled));
 ABI_APPEND(",\"context\":%zu",offsetof(MTECancellation,context));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MTEError\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MTEError),_Alignof(MTEError));
 ABI_APPEND("\"code\":%zu",offsetof(MTEError,code));
 ABI_APPEND(",\"offset\":%zu",offsetof(MTEError,offset));
 ABI_APPEND(",\"reason\":%zu",offsetof(MTEError,reason));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MTEFacts\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MTEFacts),_Alignof(MTEFacts));
 ABI_APPEND("\"source_sha256\":%zu",offsetof(MTEFacts,source_sha256));
 ABI_APPEND(",\"source_bytes\":%zu",offsetof(MTEFacts,source_bytes));
 ABI_APPEND(",\"doc_type\":%zu",offsetof(MTEFacts,doc_type));
 ABI_APPEND(",\"count\":%zu",offsetof(MTEFacts,count));
 ABI_APPEND(",\"metadata_read_bytes\":%zu",offsetof(MTEFacts,metadata_read_bytes));
 ABI_APPEND(",\"skipped_payload_bytes\":%zu",offsetof(MTEFacts,skipped_payload_bytes));
 ABI_APPEND(",\"source_hash_read_bytes\":%zu",offsetof(MTEFacts,source_hash_read_bytes));
 ABI_APPEND("}}");
 ABI_APPEND(",\"MTETrack\":{\"size\":%zu,\"alignment\":%zu,\"offsets\":{",sizeof(MTETrack),_Alignof(MTETrack));
 ABI_APPEND("\"number\":%zu",offsetof(MTETrack,number));
 ABI_APPEND(",\"uid\":%zu",offsetof(MTETrack,uid));
 ABI_APPEND(",\"type\":%zu",offsetof(MTETrack,type));
 ABI_APPEND(",\"enabled\":%zu",offsetof(MTETrack,enabled));
 ABI_APPEND(",\"default_track\":%zu",offsetof(MTETrack,default_track));
 ABI_APPEND(",\"forced\":%zu",offsetof(MTETrack,forced));
 ABI_APPEND(",\"lacing\":%zu",offsetof(MTETrack,lacing));
 ABI_APPEND(",\"flags_present\":%zu",offsetof(MTETrack,flags_present));
 ABI_APPEND(",\"has_video\":%zu",offsetof(MTETrack,has_video));
 ABI_APPEND(",\"pixel_width\":%zu",offsetof(MTETrack,pixel_width));
 ABI_APPEND(",\"pixel_height\":%zu",offsetof(MTETrack,pixel_height));
 ABI_APPEND(",\"crop_left\":%zu",offsetof(MTETrack,crop_left));
 ABI_APPEND(",\"crop_right\":%zu",offsetof(MTETrack,crop_right));
 ABI_APPEND(",\"crop_top\":%zu",offsetof(MTETrack,crop_top));
 ABI_APPEND(",\"crop_bottom\":%zu",offsetof(MTETrack,crop_bottom));
 ABI_APPEND(",\"display_width\":%zu",offsetof(MTETrack,display_width));
 ABI_APPEND(",\"display_height\":%zu",offsetof(MTETrack,display_height));
 ABI_APPEND(",\"display_unit\":%zu",offsetof(MTETrack,display_unit));
 ABI_APPEND(",\"alpha_mode\":%zu",offsetof(MTETrack,alpha_mode));
 ABI_APPEND(",\"video_fields_present\":%zu",offsetof(MTETrack,video_fields_present));
 ABI_APPEND(",\"codec_id\":%zu",offsetof(MTETrack,codec_id));
 ABI_APPEND(",\"codec_private\":%zu",offsetof(MTETrack,codec_private));
 ABI_APPEND(",\"codec_private_size\":%zu",offsetof(MTETrack,codec_private_size));
 ABI_APPEND(",\"raw_entry\":%zu",offsetof(MTETrack,raw_entry));
 ABI_APPEND(",\"raw_entry_size\":%zu",offsetof(MTETrack,raw_entry_size));
 ABI_APPEND(",\"entry_offset\":%zu",offsetof(MTETrack,entry_offset));
 ABI_APPEND(",\"entry_sha256\":%zu",offsetof(MTETrack,entry_sha256));
 ABI_APPEND("}}");
 ABI_APPEND("}}");
 #undef ABI_APPEND
 if(!output && capacity==0)return (int)used;
 if(!output || capacity<=used)return -ENOBUFS;
 memcpy(output,data,used); output[used]=0; return (int)used;
}
static const char *implementation_path_v1(const void *symbol) {
 Dl_info info; memset(&info,0,sizeof(info));
 return dladdr(symbol,&info) && info.dli_fname ? info.dli_fname : NULL;
}
const char *mib_implementation_image_path_v1(int role) {
 switch(role) {
 case 0:return implementation_path_v1((const void *)mib_source_open_fd_with_cancel);
 case 1:return implementation_path_v1((const void *)mte_read_fd_with_cancel);
 case 2:return implementation_path_v1((const void *)mib_biplanar_working);
 default:return NULL;
 }
}
const char *mib_library_image_path_v1(int library) {
 switch(library) {
 case 0:return implementation_path_v1((const void *)avformat_version);
 case 1:return implementation_path_v1((const void *)avcodec_version);
 case 2:return implementation_path_v1((const void *)avutil_version);
 case 3:return implementation_path_v1((const void *)swresample_version);
 case 4:return implementation_path_v1((const void *)swscale_version);
 default:return NULL;
 }
}
unsigned int mib_library_runtime_version_v1(int library) {
 switch(library) {case 0:return avformat_version();case 1:return avcodec_version();case 2:return avutil_version();case 3:return swresample_version();case 4:return swscale_version();default:return 0;}
}
unsigned int mib_library_compiled_version_v1(int library) {
 switch(library) {case 0:return LIBAVFORMAT_VERSION_INT;case 1:return LIBAVCODEC_VERSION_INT;case 2:return LIBAVUTIL_VERSION_INT;case 3:return LIBSWRESAMPLE_VERSION_INT;case 4:return LIBSWSCALE_VERSION_INT;default:return 0;}
}
