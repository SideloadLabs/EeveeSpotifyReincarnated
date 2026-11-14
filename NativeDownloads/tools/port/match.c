// Find where code windows of an old arm64 binary moved to in a new one.
// Instructions are normalised (branch/page/literal offsets masked) and matched by k-gram diagonal voting.
// usage: match old.bin old_text_fileoff new.bin new_text_fileoff new_text_size queries.txt
//   queries.txt lines: <name> <old_file_offset_of_window_start> <nwords>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define K 6
static uint32_t norm(uint32_t w) {
    if ((w & 0x9f000000) == 0x90000000) return w & 0x9f00001f;           // adrp
    if ((w & 0x9f000000) == 0x10000000) return w & 0x9f00001f;           // adr
    if ((w & 0x7c000000) == 0x14000000) return w & 0xfc000000;           // b / bl
    if ((w & 0xff000010) == 0x54000000) return w & 0xff00001f;           // b.cond
    if ((w & 0x7e000000) == 0x34000000) return w & 0xff00001f;           // cbz / cbnz
    if ((w & 0x7e000000) == 0x36000000) return w & 0xfff8001f;           // tbz / tbnz
    if ((w & 0x3b000000) == 0x18000000) return w & 0xff00001f;           // ldr literal
    if ((w & 0x1f000000) == 0x11000000) return w & 0xff8003ff;           // add/sub immediate: keep regs, drop imm12
    if ((w & 0x3b000000) == 0x39000000) return w & 0xffc003ff;           // ldr/str unsigned offset
    return w;
}
static uint64_t gram(const uint32_t *n) {
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < K; i++) { h ^= n[i]; h *= 1099511628211ULL; h ^= h >> 29; }
    return h;
}
typedef struct { uint64_t h; int q; int qi; int next; } Ent;
typedef struct { int64_t diag; int votes; } Vote;
typedef struct { char name[64]; int nwords; uint32_t *n; int ngrams; Vote *v; int nv, cap; } Query;

static void *mapfile(const char *p, size_t *sz) {
    int fd = open(p, O_RDONLY); struct stat st; fstat(fd, &st);
    void *m = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); *sz = st.st_size; return m;
}
static void addvote(Query *q, int64_t diag) {
    for (int i = 0; i < q->nv; i++) if (q->v[i].diag == diag) { q->v[i].votes++; return; }
    if (q->nv == q->cap) { q->cap = q->cap ? q->cap * 2 : 256; q->v = realloc(q->v, q->cap * sizeof(Vote)); }
    q->v[q->nv].diag = diag; q->v[q->nv].votes = 1; q->nv++;
}
int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage\n"); return 2; }
    size_t osz, nsz; const uint8_t *old = mapfile(argv[1], &osz), *nw = mapfile(argv[3], &nsz);
    (void)strtoull(argv[2], 0, 0);
    uint64_t ntoff = strtoull(argv[4], 0, 0), ntsz = strtoull(argv[5], 0, 0);
    FILE *qf = fopen(argv[6], "r"); Query *qs = calloc(4096, sizeof(Query)); int nq = 0;
    char name[64]; unsigned long long off; int nwords;
    while (fscanf(qf, "%63s %llu %d", name, &off, &nwords) == 3) {
        Query *q = &qs[nq++]; strcpy(q->name, name); q->nwords = nwords; q->n = malloc(nwords * 4);
        for (int i = 0; i < nwords; i++) { uint32_t w; memcpy(&w, old + off + i * 4, 4); q->n[i] = norm(w); }
    }
    const int TB = 1 << 20; int *table = malloc(TB * sizeof(int)); memset(table, -1, TB * sizeof(int));
    Ent *ents = malloc(sizeof(Ent) * 400000); int ne = 0;
    for (int qi_ = 0; qi_ < nq; qi_++) {
        Query *q = &qs[qi_];
        for (int i = 0; i + K <= q->nwords; i++) {
            uint64_t h = gram(q->n + i); int slot = h & (TB - 1);
            ents[ne] = (Ent){h, qi_, i, table[slot]}; table[slot] = ne++; q->ngrams++;
        }
    }
    uint64_t nwords_new = ntsz / 4; const uint32_t *nt = (const uint32_t *)(nw + ntoff);
    uint32_t win[K];
    for (int i = 0; i < K - 1; i++) win[i] = norm(nt[i]);
    for (uint64_t j = 0; j + K <= nwords_new; j++) {
        win[K - 1] = norm(nt[j + K - 1]);
        uint64_t h = gram(win); int e = table[h & (TB - 1)];
        while (e >= 0) { if (ents[e].h == h) addvote(&qs[ents[e].q], (int64_t)j - ents[e].qi); e = ents[e].next; }
        for (int i = 0; i < K - 1; i++) win[i] = win[i + 1];
    }
    for (int i = 0; i < nq; i++) {
        Query *q = &qs[i];
        for (int pass = 0; pass < 4; pass++) {
            int best = -1;
            for (int k = 0; k < q->nv; k++) if (q->v[k].votes > 0 && (best < 0 || q->v[k].votes > q->v[best].votes)) best = k;
            if (best < 0) break;
            printf("%s %d %lld %d\n", q->name, q->ngrams, (long long)(q->v[best].diag * 4 + (int64_t)ntoff), q->v[best].votes);
            q->v[best].votes = -q->v[best].votes;
        }
    }
    return 0;
}
