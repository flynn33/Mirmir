#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void json_string(const char *s) {
    putchar('"');
    for (const unsigned char *p=(const unsigned char *)s; *p; ++p) {
        if (*p=='"' || *p=='\\') {putchar('\\');putchar(*p);}
        else if (*p<32) printf("\\u%04x",*p);
        else putchar(*p);
    }
    putchar('"');
}
int main(int argc,char **argv) {
    const char *names[]={"libavcodec.62.dylib","libavformat.62.dylib","libavutil.60.dylib","libswresample.6.dylib","libswscale.9.dylib"};
    const char *prefix[]={"avcodec","avformat","avutil","swresample","swscale"};
    char expected[PATH_MAX];
    if (argc!=2 || !realpath(argv[1],expected)) return 64;
    printf("{\"scope\":\"private packaged loader\",\"libraries\":[");
    for(size_t i=0;i<5;i++) {
        char load[128],symbol[128],resolved[PATH_MAX];
        snprintf(load,sizeof(load),"@rpath/%s",names[i]);
        void *handle=dlopen(load,RTLD_NOW|RTLD_LOCAL);
        if(!handle) {fprintf(stderr,"dlopen %s: %s\n",load,dlerror());return 1;}
        snprintf(symbol,sizeof(symbol),"%s_version",prefix[i]);
        unsigned (*version)(void)=(unsigned (*)(void))dlsym(handle,symbol);
        snprintf(symbol,sizeof(symbol),"%s_license",prefix[i]);
        const char *(*license)(void)=(const char *(*)(void))dlsym(handle,symbol);
        snprintf(symbol,sizeof(symbol),"%s_configuration",prefix[i]);
        const char *(*configuration)(void)=(const char *(*)(void))dlsym(handle,symbol);
        Dl_info info;
        if(!version || !license || !configuration || !dladdr((void *)version,&info) || !realpath(info.dli_fname,resolved)) return 2;
        size_t n=strlen(expected);
        if(strncmp(resolved,expected,n) || resolved[n]!='/' || strcmp(resolved+n+1,names[i])) {fprintf(stderr,"unexpected image: %s\n",resolved);return 3;}
        if(i)putchar(',');
        printf("{\"name\":");json_string(names[i]);printf(",\"path\":");json_string(resolved);
        printf(",\"version\":%u,\"license\":",version());json_string(license());printf(",\"configuration\":");json_string(configuration());putchar('}');
        dlclose(handle);
    }
    puts("]}");return 0;
}
