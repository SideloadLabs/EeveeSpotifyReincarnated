#import "SGDSPEffects.h"
#import <ctype.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import "ns-eel.h"

// A script's memory, all of it given up front: past it, reads and writes land in EEL2's spare slot.
enum { kMemory = 1 << 20 };

typedef enum { SectionInit, SectionSlider, SectionBlock, SectionSample, SectionCount } Section;

struct SGDSPLiveprog {
    NSEEL_VMCTX vm;
    NSEEL_CODEHANDLE code[SectionCount];
    EEL_F *spl0, *spl1, *samplesblock;
    void *gram;
};

// EEL2 locks around its memory being grown and its tables being changed, which only a compile does here. On
// the render thread nothing is grown: gmem stays unallocated there, and the lock is never waited on. The
// thread is told apart by pthread_self, not a thread-local, whose first use on a thread allocates.
static pthread_mutex_t sg_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(pthread_t) sg_renderThread;

static bool rendering(void) {
    return pthread_equal(pthread_self(), atomic_load_explicit(&sg_renderThread, memory_order_relaxed));
}

__attribute__((visibility("hidden"))) void NSEEL_HOSTSTUB_EnterMutex(void) {
    if (!rendering()) pthread_mutex_lock(&sg_lock);
}

__attribute__((visibility("hidden"))) void NSEEL_HOSTSTUB_LeaveMutex(void) {
    if (!rendering()) pthread_mutex_unlock(&sg_lock);
}

static void *gmemCalloc(size_t count, size_t size) {
    return rendering() ? NULL : calloc(count, size);
}

static void start(void) {
    nseel_gmem_calloc = gmemCalloc;
    NSEEL_init();
}

static void copyError(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text);
}

// "sliderN:default<...>" or "sliderN:name=default<...>": the variable set to its default before @init.
static void sliderDefault(SGDSPLiveprog *liveprog, const char *line, const char *end) {
    const char *p = line + 6;
    int number = 0;
    while (p < end && isdigit((unsigned char)*p)) number = number * 10 + (*p++ - '0');
    if (!number || p >= end || *p++ != ':') return;
    char name[64];
    snprintf(name, sizeof name, "slider%d", number);
    const char *equals = memchr(p, '=', (size_t)(end - p)), *angle = memchr(p, '<', (size_t)(end - p));
    if (equals && (!angle || equals < angle) && equals - p < (long)sizeof name) {
        memcpy(name, p, (size_t)(equals - p));
        name[equals - p] = 0;
        p = equals + 1;
    }
    char *after;
    double value = strtod(p, &after);
    if (after != p) *NSEEL_VM_regvar(liveprog->vm, name) = value;
}

static bool compile(SGDSPLiveprog *liveprog, const char *script, char *error, size_t errorSize) {
    static const char *markers[SectionCount] = {"@init", "@slider", "@block", "@sample"};
    const char *starts[SectionCount] = {0}, *ends[SectionCount] = {0};
    int lines[SectionCount] = {0};
    int current = -1, number = 0;
    bool header = true;
    for (const char *line = script; *line;) {
        const char *end = strchr(line, '\n');
        if (!end) end = line + strlen(line);
        number++;
        const char *text = line;
        while (text < end && (*text == ' ' || *text == '\t')) text++;
        if (*text == '@') {
            if (current >= 0) ends[current] = line;
            current = -1;
            header = false;
            for (int s = 0; s < SectionCount; s++) {
                size_t length = strlen(markers[s]);
                if (!strncmp(text, markers[s], length) && (text + length == end || isspace((unsigned char)text[length]))) current = s;
            }
            if (current >= 0) {
                starts[current] = *end ? end + 1 : end;
                lines[current] = number;
            }
        } else if (header && !strncmp(text, "slider", 6)) {
            sliderDefault(liveprog, text, end);
        }
        line = *end ? end + 1 : end;
    }
    if (current >= 0) ends[current] = script + strlen(script);
    if (!starts[SectionSample]) {
        copyError(error, errorSize, "No @sample section: Liveprog runs a script's @sample on every sample");
        return false;
    }
    for (int s = 0; s < SectionCount; s++) {
        if (!starts[s]) continue;
        size_t length = (size_t)(ends[s] - starts[s]);
        char *code = malloc(length + 1);
        if (!code) {
            copyError(error, errorSize, "Not enough memory for the script");
            return false;
        }
        memcpy(code, starts[s], length);
        code[length] = 0;
        // Functions an @init defines are every section's; lines count from the marker's, so errors name the file's.
        liveprog->code[s] = NSEEL_code_compile_ex(liveprog->vm, code, lines[s], NSEEL_CODE_COMPILE_FLAG_COMMONFUNCS);
        free(code);
        if (!liveprog->code[s]) {
            const char *message = NSEEL_code_getcodeerror(liveprog->vm);
            int line = 0, used = 0;
            char text[300];
            if (message && sscanf(message, "%d: %n", &line, &used) == 1 && used > 0) {
                snprintf(text, sizeof text, "Line %d: %s", line, message + used);
            } else {
                snprintf(text, sizeof text, "%s: %s", markers[s], message && *message ? message : "does not compile");
            }
            copyError(error, errorSize, text);
            return false;
        }
    }
    return true;
}

SGDSPLiveprog *SGDSPLiveprogCreate(const char *script, double rate, char *error, size_t errorSize) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, start);
    SGDSPLiveprog *liveprog = calloc(1, sizeof *liveprog);
    if (!liveprog || !(liveprog->vm = NSEEL_VM_alloc())) {
        free(liveprog);
        copyError(error, errorSize, "Not enough memory for the script");
        return NULL;
    }
    NSEEL_VM_SetGRAM(liveprog->vm, &liveprog->gram);
    NSEEL_VM_setramsize(liveprog->vm, kMemory);
    liveprog->spl0 = NSEEL_VM_regvar(liveprog->vm, "spl0");
    liveprog->spl1 = NSEEL_VM_regvar(liveprog->vm, "spl1");
    liveprog->samplesblock = NSEEL_VM_regvar(liveprog->vm, "samplesblock");
    *NSEEL_VM_regvar(liveprog->vm, "srate") = rate;
    *NSEEL_VM_regvar(liveprog->vm, "num_ch") = 2;
    *liveprog->samplesblock = kSGDSPEffectMaxFrames;
    if (!script) copyError(error, errorSize, "The script could not be read");
    if (!script || !compile(liveprog, script, error, errorSize)) {
        SGDSPLiveprogFree(liveprog);
        return NULL;
    }
    NSEEL_VM_preallocram(liveprog->vm, -1);
    if (liveprog->code[SectionInit]) NSEEL_code_execute(liveprog->code[SectionInit]);
    if (liveprog->code[SectionSlider]) NSEEL_code_execute(liveprog->code[SectionSlider]);
    return liveprog;
}

void SGDSPLiveprogRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPLiveprog *liveprog = state;
    atomic_store_explicit(&sg_renderThread, pthread_self(), memory_order_relaxed);
    if (liveprog->code[SectionBlock]) {
        *liveprog->samplesblock = frames;
        NSEEL_code_execute(liveprog->code[SectionBlock]);
    }
    NSEEL_CODEHANDLE sample = liveprog->code[SectionSample];
    EEL_F *spl0 = liveprog->spl0, *spl1 = liveprog->spl1;
    for (uint32_t i = 0; i < frames; i++) {
        *spl0 = left[i];
        *spl1 = right[i];
        NSEEL_code_execute(sample);
        left[i] = (float)*spl0;
        right[i] = (float)*spl1;
    }
    atomic_store_explicit(&sg_renderThread, (pthread_t)NULL, memory_order_relaxed);
}

void SGDSPLiveprogFree(void *state) {
    SGDSPLiveprog *liveprog = state;
    if (!liveprog) return;
    for (int s = 0; s < SectionCount; s++) {
        if (liveprog->code[s]) NSEEL_code_free(liveprog->code[s]);
    }
    if (liveprog->vm) NSEEL_VM_free(liveprog->vm);
    NSEEL_VM_FreeGRAM(&liveprog->gram);
    free(liveprog);
}
