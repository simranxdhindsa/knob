#include "loopback.h"
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static _Atomic(KnLoopback*) current=NULL;
static pthread_mutex_t lifecycle=PTHREAD_MUTEX_INITIALIZER;
/* The audio thread may still be writing to a block just replaced, so a block is only unmapped
   after several later attaches, each seconds apart at the least. */
enum { RETIRED=4 };
static KnLoopback* retired[RETIRED];
static UInt32 next_retired=0;

KnLoopback* kn_loopback_current(void) { return atomic_load_explicit(&current,memory_order_acquire); }

static void replace(KnLoopback* block) {
    KnLoopback* old=atomic_exchange_explicit(&current,block,memory_order_acq_rel);
    if(!old) return;
    if(retired[next_retired]) munmap(retired[next_retired],sizeof(KnLoopback));
    retired[next_retired]=old; next_retired=(next_retired+1)%RETIRED;
}
static KnLoopback* open_block(const char* name) {
    int file=shm_open(name,O_RDWR);
    if(file<0) return NULL;
    struct stat info; KnLoopback* block=NULL;
    if(fstat(file,&info)==0 && (UInt64)info.st_size>=sizeof(KnLoopback)) {
        void* mapped=mmap(NULL,sizeof(KnLoopback),PROT_READ|PROT_WRITE,MAP_SHARED,file,0);
        if(mapped!=MAP_FAILED) block=mapped;
    }
    close(file);
    if(block && (block->magic!=KN_LOOP_MAGIC || block->version!=KN_LOOP_VERSION || block->frames!=KN_LOOP_FRAMES)) {
        munmap(block,sizeof(KnLoopback)); block=NULL;
    }
    return block;
}
OSStatus kn_loopback_attach(CFStringRef name) {
    char text[KN_LOOP_NAME_MAX+1];
    if(!name || !CFStringGetCString(name,text,sizeof(text),kCFStringEncodingUTF8)) return kAudioHardwareIllegalOperationError;
    OSStatus status=noErr;
    pthread_mutex_lock(&lifecycle);
    if(!text[0]) replace(NULL);
    else if(strncmp(text,KN_LOOP_PREFIX,strlen(KN_LOOP_PREFIX))!=0 || strchr(text+1,'/')) status=kAudioHardwareIllegalOperationError;
    else {
        KnLoopback* block=open_block(text);
        if(block) {
            replace(block);
            __atomic_store_n(&block->attached,1,__ATOMIC_RELEASE);
        } else status=kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_unlock(&lifecycle);
    return status;
}
