#include "carrier_pixels.h"
#include <errno.h>
#include <limits.h>
#include <libavutil/pixdesc.h>
int mib_carrier_pixel_format_supported(int pixel_format) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(pixel_format);
    if (!d || d->flags != AV_PIX_FMT_FLAG_PLANAR || d->nb_components != 3 ||
        !((d->log2_chroma_w == 1 && (d->log2_chroma_h == 0 || d->log2_chroma_h == 1)) ||
          (d->log2_chroma_w == 0 && d->log2_chroma_h == 0))) return 0;
    for (int p = 0; p < 3; p++) {
        if (d->comp[p].plane != p || d->comp[p].step != 1 || d->comp[p].offset != 0 ||
            d->comp[p].shift != 0 || d->comp[p].depth != 8) return 0;
    }
    return 1;
}
int mib_carrier_pack_yuyv420(const MIBDecodedFrame *f, uint8_t *out, size_t bytes) {
    if (!f || !out || f->depth != 8 || f->planes != 3 || f->components != 3 ||
        f->width <= 0 || f->height <= 0 || (f->width & 1) || (f->height & 1) ||
        f->width > 8192 || f->height > 8192 || f->crop_left || f->crop_right || f->crop_top || f->crop_bottom ||
        !((f->chroma_log2_width == 1 && (f->chroma_log2_height == 0 || f->chroma_log2_height == 1)) ||
          (f->chroma_log2_width == 0 && f->chroma_log2_height == 0))) return -EINVAL;
    if (!mib_carrier_pixel_format_supported(f->pixel_format)) return -EINVAL;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(f->pixel_format);
    if (descriptor->log2_chroma_w != f->chroma_log2_width ||
        descriptor->log2_chroma_h != f->chroma_log2_height) return -EINVAL;
    size_t wanted = (size_t)f->width * (size_t)f->height * 2;
    if (bytes != wanted) return -EINVAL;
    const MIBPlane *planes = f->plane;
    for (int p = 0; p < 3; p++) {
        int w = p ? f->width >> f->chroma_log2_width : f->width;
        int h = p ? f->height >> f->chroma_log2_height : f->height;
        if (!planes[p].bytes.data || planes[p].width != w || planes[p].height != h ||
            planes[p].row_bytes < w || planes[p].bytes.size < (size_t)planes[p].row_bytes * (size_t)h) return -EINVAL;
    }
    for (int y = 0; y < f->height; y++) {
        const uint8_t *luma = planes[0].bytes.data + (size_t)y * (size_t)planes[0].row_bytes;
        uint8_t *row = out + (size_t)y * (size_t)f->width * 2;
        for (int x = 0; x < f->width; x += 2) {
            row[x * 2] = luma[x]; row[x * 2 + 2] = luma[x + 1];
            for (int p = 1; p < 3; p++) {
                unsigned value;
                if (f->chroma_log2_height == 1) {
                    value = planes[p].bytes.data[(size_t)(y / 2) * (size_t)planes[p].row_bytes + (size_t)(x / 2)];
                } else {
                    int cy = y & ~1;
                    const uint8_t *a = planes[p].bytes.data + (size_t)cy * (size_t)planes[p].row_bytes;
                    const uint8_t *b = a + planes[p].row_bytes;
                    if (f->chroma_log2_width == 1) value = ((unsigned)a[x/2] + b[x/2] + 1) / 2;
                    else value = ((unsigned)a[x] + a[x+1] + b[x] + b[x+1] + 2) / 4;
                }
                row[x * 2 + (p == 1 ? 1 : 3)] = (uint8_t)value;
            }
        }
    }
    return 0;
}

#include <errno.h>
#include <libavutil/pixdesc.h>
#include <stdint.h>
int mirmir_rgb8_layout_supported(int pixel_format) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(pixel_format);
    if (!d || d->nb_components != 3 || !(d->flags & AV_PIX_FMT_FLAG_RGB) ||
        (d->flags & ~(AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PLANAR)) ||
        d->log2_chroma_w || d->log2_chroma_h) return 0;
    for (int c = 0; c < 3; c++) {
        const AVComponentDescriptor *v = &d->comp[c];
        if (v->depth != 8 || v->shift || v->plane < 0 || v->plane > 2 ||
            v->step < 1 || v->step > 4 || v->offset < 0 || v->offset >= v->step) return 0;
    }
    return 1;
}
static uint8_t rounded_code(int64_t numerator, int64_t denominator) {
    /* All admitted full-range RGB values keep these numerators nonnegative. */
    int64_t q = numerator / denominator, r = numerator % denominator;
    if (r * 2 > denominator || (r * 2 == denominator && (q & 1))) q++;
    return q < 0 ? 0 : q > 255 ? 255 : (uint8_t)q;
}
static int64_t component(const MIBDecodedFrame *f, const AVPixFmtDescriptor *d,
                         int c, int x, int y) {
    const AVComponentDescriptor *v = &d->comp[c];
    const MIBPlane *p = &f->plane[v->plane];
    return p->bytes.data[(size_t)y * (size_t)p->row_bytes + (size_t)x * (size_t)v->step + (size_t)v->offset];
}
int mirmir_rgb8_to_yuyv420(const MIBDecodedFrame *f, int matrix,
                         int source_full_range, uint8_t *out, size_t bytes) {
    if (!f || !out || !source_full_range || f->color_range != AVCOL_RANGE_JPEG ||
        f->matrix != AVCOL_SPC_RGB || !mirmir_rgb8_layout_supported(f->pixel_format) ||
        f->depth != 8 || f->components != 3 || f->width <= 0 || f->height <= 0 ||
        f->width > 8192 || f->height > 8192 || (f->width & 1) || (f->height & 1) ||
        f->chroma_log2_width || f->chroma_log2_height || f->crop_left || f->crop_right ||
        f->crop_top || f->crop_bottom || bytes != (size_t)f->width * (size_t)f->height * 2) return -EINVAL;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(f->pixel_format);
    int highest = 0;
    for (int c = 0; c < 3; c++) {
        const AVComponentDescriptor *v = &d->comp[c];
        const MIBPlane *p = &f->plane[v->plane];
        if (v->plane > highest) highest = v->plane;
        size_t last = (size_t)(f->width - 1) * (size_t)v->step + (size_t)v->offset + 1;
        if (!p->bytes.data || p->width != f->width || p->height != f->height ||
            p->row_bytes <= 0 || (size_t)p->row_bytes < last ||
            p->bytes.size < (size_t)p->row_bytes * (size_t)f->height) return -EINVAL;
    }
    if (f->planes != highest + 1) return -EINVAL;
    int64_t kr, kb, w = 10000;
    if (matrix == 1) { kr = 2126; kb = 722; }
    else if (matrix == 6) { kr = 2990; kb = 1140; }
    else if (matrix == 9) { kr = 2627; kb = 593; }
    else return -EINVAL;
    const int64_t kg = w - kr - kb, cbden = 8 * (w - kb), crden = 8 * (w - kr);
    for (int y = 0; y < f->height; y += 2) {
        for (int x = 0; x < f->width; x += 2) {
            int64_t sumr = 0, sumg = 0, sumb = 0;
            for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
                int64_t r = component(f, d, 0, x + dx, y + dy);
                int64_t g = component(f, d, 1, x + dx, y + dy);
                int64_t b = component(f, d, 2, x + dx, y + dy);
                sumr += r; sumg += g; sumb += b;
                out[((size_t)(y + dy) * (size_t)f->width + (size_t)(x + dx)) * 2] = rounded_code(kr*r + kg*g + kb*b,w);
            }
            int64_t sumy = kr*sumr + kg*sumg + kb*sumb;
            uint8_t cb = rounded_code(128*cbden + w*sumb - sumy,cbden);
            uint8_t cr = rounded_code(128*crden + w*sumr - sumy,crden);
            for (int dy = 0; dy < 2; dy++) {
                size_t p = ((size_t)(y + dy) * (size_t)f->width + (size_t)x) * 2;
                out[p + 1] = cb; out[p + 3] = cr;
            }
        }
    }
    return 0;
}

#include "carrier_pixels.h"
#include <errno.h>
#include <limits.h>
#include <libavutil/pixdesc.h>
int mib_biplanar_layout_supported(int pixel_format) {
 const AVPixFmtDescriptor *d=av_pix_fmt_desc_get(pixel_format);
 if(!d || (d->flags & ~(AV_PIX_FMT_FLAG_PLANAR|AV_PIX_FMT_FLAG_BE)) ||
    !(d->nb_components==1 || d->nb_components==3) ||
    d->log2_chroma_w>1 || d->log2_chroma_h>1) return 0;
 int depth=d->comp[0].depth;
 if(depth<8 || depth>16)return 0;
 for(int c=0;c<d->nb_components;c++) {
  const AVComponentDescriptor *v=&d->comp[c];
  if(v->depth!=depth || v->shift<0 || v->shift+depth>16 ||
     v->plane<0 || v->plane>2 || v->step<1 || v->step>8 ||
     v->offset<0 || v->offset+(v->shift+depth+7)/8>v->step) return 0;
 }
 return 1;
}
static void be32(uint8_t *p,uint32_t x) {for(int i=0;i<4;i++)p[i]=(uint8_t)(x>>(24-i*8));}
static uint32_t read_code(const MIBDecodedFrame *f,const AVPixFmtDescriptor *d,int c,int x,int y) {
 const AVComponentDescriptor *v=&d->comp[c];
 const uint8_t *p=f->plane[v->plane].bytes.data+(size_t)y*(size_t)f->plane[v->plane].row_bytes+(size_t)x*(size_t)v->step+(size_t)v->offset;
 int n=(v->depth+v->shift+7)/8;uint32_t code;
 if(n==1)code=p[0];else if(d->flags&AV_PIX_FMT_FLAG_BE)code=((uint32_t)p[0]<<8)|p[1];else code=((uint32_t)p[1]<<8)|p[0];
 return (code>>v->shift)&((UINT32_C(1)<<v->depth)-1);
}
static uint32_t working_code(uint64_t sum,unsigned count,int source_depth,int dest_depth,int full) {
 uint64_t numerator,denominator;
 if(full) {numerator=sum*((UINT64_C(1)<<dest_depth)-1);denominator=(uint64_t)count*((UINT64_C(1)<<source_depth)-1);}
 else if(source_depth<=dest_depth) {numerator=sum<<(dest_depth-source_depth);denominator=count;}
 else {numerator=sum;denominator=(uint64_t)count<<(source_depth-dest_depth);}
 uint64_t q=(numerator+denominator/2)/denominator,max=(UINT64_C(1)<<dest_depth)-1;
 return (uint32_t)(q>max?max:q);
}
static void write_code(uint8_t *p,size_t index,int depth,uint32_t code) {
 if(depth==8)p[index]=(uint8_t)code;
 else {uint32_t stored=code<<6;p[index*2]=(uint8_t)stored;p[index*2+1]=(uint8_t)(stored>>8);}
}
int mib_biplanar_working(const MIBDecodedFrame *f,int depth,int full,int range_policy,uint8_t *out,size_t bytes) {
 if(!f || !out || !(depth==8 || depth==10) || !(full==0 || full==1) ||
    !mib_biplanar_layout_supported(f->pixel_format) || f->width<=0 || f->height<=0 ||
    f->width>8192 || f->height>8192 || f->crop_left || f->crop_right || f->crop_top || f->crop_bottom) return -EINVAL;
 if(range_policy==MIB_RANGE_DECLARED) {
  if(f->color_range!=(full?AVCOL_RANGE_JPEG:AVCOL_RANGE_MPEG))return -EINVAL;
 } else if(range_policy==MIB_RANGE_QUALIFIED_UNSPECIFIED_8BIT) {
  if(f->depth!=8 || f->color_range!=AVCOL_RANGE_UNSPECIFIED)return -EINVAL;
 } else return -EINVAL;
 const AVPixFmtDescriptor *d=av_pix_fmt_desc_get(f->pixel_format);
 if(f->depth!=d->comp[0].depth || f->components!=d->nb_components ||
    f->chroma_log2_width!=d->log2_chroma_w || f->chroma_log2_height!=d->log2_chroma_h ||
    f->pixel_format_flags!=d->flags || f->pixel_is_rgb || f->pixel_has_alpha)return -EINVAL;
 size_t w=(size_t)f->width,h=(size_t)f->height,cw=(w+1)/2,ch=(h+1)/2,bpc=depth==8?1:2;
 size_t ystride=w*bpc,uvstride=cw*2*bpc,ysize=ystride*h,uvsize=uvstride*ch;
 if(bytes!=16+ysize+uvsize || bytes>UINT32_MAX)return -EINVAL;
 int highest=0;
 for(int c=0;c<d->nb_components;c++) {
  const AVComponentDescriptor *v=&d->comp[c];const MIBPlane *p=&f->plane[v->plane];
  int width=c?(f->width+(1<<d->log2_chroma_w)-1)>>d->log2_chroma_w:f->width;
  int height=c?(f->height+(1<<d->log2_chroma_h)-1)>>d->log2_chroma_h:f->height;
  size_t last=(size_t)(width-1)*(size_t)v->step+(size_t)v->offset+(size_t)(v->depth+v->shift+7)/8;
  if(v->plane>highest)highest=v->plane;
  if(!p->bytes.data || p->row_bytes<0 || last>(size_t)p->row_bytes || p->height<height ||
     (size_t)(height-1)*(size_t)p->row_bytes+last>p->bytes.size)return -EINVAL;
 }
 if(f->planes!=highest+1)return -EINVAL;
 for(int plane=0;plane<=highest;plane++) {
  int expected_width=0,expected_height=0;
  for(int c=0;c<d->nb_components;c++)if(d->comp[c].plane==plane) {
   int width=c?(f->width+(1<<d->log2_chroma_w)-1)>>d->log2_chroma_w:f->width;
   int height=c?(f->height+(1<<d->log2_chroma_h)-1)>>d->log2_chroma_h:f->height;
   if(width>expected_width)expected_width=width;
   if(height>expected_height)expected_height=height;
  }
  if(f->plane[plane].width!=expected_width || f->plane[plane].height!=expected_height)return -EINVAL;
 }

 uintptr_t output_begin=(uintptr_t)out;
 if(bytes>UINTPTR_MAX-output_begin)return -EINVAL;
 uintptr_t output_end=output_begin+bytes;
 for(int plane=0;plane<=highest;plane++) {
  uintptr_t input_begin=(uintptr_t)f->plane[plane].bytes.data;
  if(f->plane[plane].bytes.size>UINTPTR_MAX-input_begin)return -EINVAL;
  uintptr_t input_end=input_begin+f->plane[plane].bytes.size;
  if(output_begin<input_end && input_begin<output_end)return -EINVAL;
 }
 // No writes occur until every original input span and output extent is checked.
 be32(out,16);be32(out+4,(uint32_t)ystride);be32(out+8,(uint32_t)(16+ysize));be32(out+12,(uint32_t)uvstride);
 uint8_t *yout=out+16,*uvout=yout+ysize;
 for(int y=0;y<f->height;y++)for(int x=0;x<f->width;x++)
  write_code(yout,(size_t)y*w+(size_t)x,depth,working_code(read_code(f,d,0,x,y),1,f->depth,depth,full));
 for(size_t y=0;y<ch;y++)for(size_t x=0;x<cw;x++)for(int c=1;c<3;c++) {
  uint32_t code=UINT32_C(1)<<(depth-1);
  if(d->nb_components==3) {
   int nx=2>>d->log2_chroma_w,ny=2>>d->log2_chroma_h;
   int sw=(f->width+(1<<d->log2_chroma_w)-1)>>d->log2_chroma_w;
   int sh=(f->height+(1<<d->log2_chroma_h)-1)>>d->log2_chroma_h;
   uint64_t sum=0;unsigned count=0;
   for(int j=0;j<ny;j++)for(int i=0;i<nx;i++) {
    int sx=(int)x*nx+i,sy=(int)y*ny+j;
    if(sx<sw && sy<sh){sum+=read_code(f,d,c,sx,sy);count++;}
   }
   code=working_code(sum,count,f->depth,depth,full);
  }
  write_code(uvout,(y*cw+x)*2+(size_t)(c-1),depth,code);
 }
 return 0;
}

#include <string.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
int mib_presentation_bgra(const MIBDecodedFrame *f, int matrix, int full,
                          int range_policy, int source_location, uint8_t *out, size_t bytes) {
 if(!f || !out || !(full==0 || full==1) || f->width<=0 || f->height<=0 ||
    f->width>8192 || f->height>8192 || f->crop_left || f->crop_right || f->crop_top || f->crop_bottom ||
    f->pixel_has_alpha || (f->flags&AV_FRAME_FLAG_INTERLACED) ||
    !(mib_biplanar_layout_supported(f->pixel_format) || mirmir_rgb8_layout_supported(f->pixel_format)) ||
    bytes!=(size_t)f->width*(size_t)f->height*4 || bytes>64*1024*1024)return -EINVAL;
 const AVPixFmtDescriptor *d=av_pix_fmt_desc_get(f->pixel_format);
 if(f->pixel_format_flags!=d->flags || f->components!=d->nb_components ||
    f->depth!=d->comp[0].depth || f->chroma_log2_width!=d->log2_chroma_w ||
    f->chroma_log2_height!=d->log2_chroma_h || f->pixel_is_rgb!=!!(d->flags&AV_PIX_FMT_FLAG_RGB) ||
    (f->transfer!=AVCOL_TRC_BT709 && f->transfer!=AVCOL_TRC_SMPTE170M &&
     f->transfer!=AVCOL_TRC_IEC61966_2_1 &&
     !(f->transfer==AVCOL_TRC_UNSPECIFIED && f->depth==8)))return -EINVAL;
 if(range_policy==MIB_RANGE_DECLARED) {
  if(f->color_range!=(full?AVCOL_RANGE_JPEG:AVCOL_RANGE_MPEG))return -EINVAL;
 } else if(range_policy==MIB_RANGE_QUALIFIED_UNSPECIFIED_8BIT) {
  if(f->depth!=8 || f->color_range!=AVCOL_RANGE_UNSPECIFIED)return -EINVAL;
 } else return -EINVAL;
 int rgb=!!(d->flags&AV_PIX_FMT_FLAG_RGB);
 if(rgb) {if(!full || matrix!=0 || f->matrix!=AVCOL_SPC_RGB)return -EINVAL;}
 else {
  if(!(matrix==1 || matrix==6 || matrix==9))return -EINVAL;
  if(f->matrix!=matrix && !(matrix==6 && f->matrix==AVCOL_SPC_BT470BG) &&
     !(f->matrix==AVCOL_SPC_UNSPECIFIED && f->depth==8))return -EINVAL;
  if(d->log2_chroma_w || d->log2_chroma_h) {
   if(source_location<1 || source_location>6 ||
      (f->chroma_location!=source_location && f->chroma_location!=AVCHROMA_LOC_UNSPECIFIED))return -EINVAL;
  }
 }
 const uint8_t *input[4]={0};int strides[4]={0};int highest=0;
 for(int c=0;c<d->nb_components;c++)if(d->comp[c].plane>highest)highest=d->comp[c].plane;
 if(f->planes!=highest+1)return -EINVAL;
 uintptr_t begin=(uintptr_t)out;if(bytes>UINTPTR_MAX-begin)return -EINVAL;
 for(int plane=0;plane<=highest;plane++) {
  int rows=(plane==1 || plane==2)?(f->height+(1<<d->log2_chroma_h)-1)>>d->log2_chroma_h:f->height;
  int width=(plane==1 || plane==2)?(f->width+(1<<d->log2_chroma_w)-1)>>d->log2_chroma_w:f->width;
  int line=av_image_get_linesize(f->pixel_format,f->width,plane);const MIBPlane *p=&f->plane[plane];
  if(line<=0 || !p->bytes.data || p->width!=width || p->height!=rows || p->row_bytes<line ||
     p->bytes.size<(size_t)p->row_bytes*(size_t)rows)return -EINVAL;
  uintptr_t a=(uintptr_t)p->bytes.data;if(p->bytes.size>UINTPTR_MAX-a)return -EINVAL;
  if(begin<a+p->bytes.size && a<begin+bytes)return -EINVAL;
  input[plane]=p->bytes.data;strides[plane]=p->row_bytes;
 }
 int input_format=f->pixel_format,unpacked=0;
 switch(f->pixel_format) {
  case AV_PIX_FMT_Y210BE:input_format=AV_PIX_FMT_YUV422P10LE;unpacked=1;break;
  case AV_PIX_FMT_Y212BE:input_format=AV_PIX_FMT_YUV422P12LE;unpacked=1;break;
  case AV_PIX_FMT_Y216BE:input_format=AV_PIX_FMT_YUV422P16LE;unpacked=1;break;
  default:break;
 }
 if(!sws_isSupportedInput(input_format))return -ENOTSUP;
 AVFrame *source=av_frame_alloc(),*target=av_frame_alloc();SwsContext *sws=NULL;int code=-ENOMEM;
 if(!source || !target)goto done;
 source->format=input_format;source->width=f->width;source->height=f->height;
 target->format=AV_PIX_FMT_BGRA;target->width=f->width;target->height=f->height;
 if((code=av_frame_get_buffer(source,32))<0 || (code=av_frame_get_buffer(target,32))<0)goto done;
 if(unpacked) {
  // Preserve every original component code, depth and422sample coordinate.
  for(int c=0;c<3;c++)for(int y=0;y<f->height;y++) {
   uint8_t *row=source->data[c]+(size_t)y*(size_t)source->linesize[c];
   int width=c?(f->width+1)/2:f->width;
   for(int x=0;x<width;x++) {
    uint32_t value=read_code(f,d,c,x,y);row[x*2]=(uint8_t)value;row[x*2+1]=(uint8_t)(value>>8);
   }
  }
 } else av_image_copy(source->data,source->linesize,input,strides,f->pixel_format,f->width,f->height);
 sws=sws_alloc_context();if(!sws){code=-ENOMEM;goto done;}
 #define SET(name,value) do{code=av_opt_set_int(sws,name,value,0);if(code<0)goto done;}while(0)
 SET("srcw",f->width);SET("srch",f->height);SET("dstw",f->width);SET("dsth",f->height);
 SET("src_format",input_format);SET("dst_format",AV_PIX_FMT_BGRA);SET("src_range",full);SET("dst_range",1);
 SET("sws_flags",SWS_BILINEAR|SWS_ACCURATE_RND|SWS_BITEXACT|SWS_FULL_CHR_H_INT);SET("threads",1);SET("sws_dither",SWS_DITHER_NONE);
 if(!rgb && (d->log2_chroma_w || d->log2_chroma_h)) {
  int x=0,y=0;code=av_chroma_location_enum_to_pos(&x,&y,source_location);if(code<0)goto done;
  if(d->log2_chroma_w)SET("src_h_chr_pos",x);
  if(d->log2_chroma_h)SET("src_v_chr_pos",y);
 }
 #undef SET
 if((code=sws_init_context(sws,NULL,NULL))<0)goto done;
 if(!rgb) {
  const int *coefficients=sws_getCoefficients(matrix==1?SWS_CS_ITU709:matrix==9?SWS_CS_BT2020:SWS_CS_ITU601);
  if((code=sws_setColorspaceDetails(sws,coefficients,full,coefficients,1,0,1<<16,1<<16))<0)goto done;
 }
 code=sws_scale(sws,(const uint8_t *const *)source->data,source->linesize,0,f->height,target->data,target->linesize);
 if(code!=f->height){code=code<0?code:-EINVAL;goto done;}
 for(int y=0;y<f->height;y++)memcpy(out+(size_t)y*(size_t)f->width*4,target->data[0]+(size_t)y*(size_t)target->linesize[0],(size_t)f->width*4);
 code=0;
 done:sws_freeContext(sws);av_frame_free(&source);av_frame_free(&target);return code;
}

/* Reuse the qualified rational RGB arithmetic, then pack its exact 4:2:0
 * codes directly. Native YUYV decoding must not filter these working samples. */
#include <stdlib.h>
int mirmir_rgb8_working(const MIBDecodedFrame *f, int matrix, int full,
                       uint8_t *out, size_t bytes) {
 if (!f || !out || full != 1 || !mirmir_rgb8_layout_supported(f->pixel_format) ||
     f->width <= 0 || f->height <= 0 || f->width > 8192 || f->height > 8192 ||
     (f->width & 1) || (f->height & 1) || f->planes < 1 || f->planes > 3 ||
     f->decode_error_flags || (f->flags & (AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_CORRUPT)) ||
     !(f->transfer == AVCOL_TRC_BT709 || f->transfer == AVCOL_TRC_SMPTE170M ||
       f->transfer == AVCOL_TRC_IEC61966_2_1 || f->transfer == AVCOL_TRC_UNSPECIFIED)) return -EINVAL;
 const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(f->pixel_format);
 if (f->pixel_format_flags != d->flags || !f->pixel_is_rgb || f->pixel_has_alpha) return -EINVAL;
 size_t w = (size_t)f->width, h = (size_t)f->height, ysize = w * h;
 if (bytes != 16 + ysize + ysize / 2 || bytes > 64 * 1024 * 1024) return -EINVAL;
 uintptr_t begin = (uintptr_t)out;
 if (bytes > UINTPTR_MAX - begin) return -EINVAL;
 for (int p = 0; p < f->planes; p++) {
  uintptr_t input = (uintptr_t)f->plane[p].bytes.data;
  if (!input || f->plane[p].bytes.size > UINTPTR_MAX - input ||
      (begin < input + f->plane[p].bytes.size && input < begin + bytes)) return -EINVAL;
 }
 uint8_t *packed = malloc(ysize * 2);
 if (!packed) return -ENOMEM;
 int result = mirmir_rgb8_to_yuyv420(f, matrix, full, packed, ysize * 2);
 if (result < 0) { free(packed); return result; }
 // No output writes occur before every source/layout/range and alias check.
 be32(out, 16); be32(out + 4, (uint32_t)w);
 be32(out + 8, (uint32_t)(16 + ysize)); be32(out + 12, (uint32_t)w);
 for (size_t i = 0; i < ysize; i++) out[16 + i] = packed[i * 2];
 for (size_t y = 0; y < h / 2; y++) for (size_t x = 0; x < w; x += 2) {
  size_t source = (y * 2 * w + x) * 2, target = 16 + ysize + y * w + x;
  out[target] = packed[source + 1]; out[target + 1] = packed[source + 3];
 }
 free(packed);
 return 0;
}
