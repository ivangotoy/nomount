/*
 * Host model of a hijacked directory stream: real entries from a modelled
 * filesystem, then NoMount's virtual children. The cursor decisions are the
 * driver's own code (kernel/src/nomount_readdir.h, included verbatim); the
 * loop around them follows nm_iterate_view() / nm_emit_virtual_children().
 * Checks for every position family: each entry listed exactly once whatever
 * the getdents buffer size, telldir/seekdir after every entry, rewind.
 *   readdir_model        driver logic, exit 0 when every family passes
 *   readdir_model base   the previous fixed-signature logic (expected to fail)
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t loff_t;
#include "../kernel/src/nomount_readdir.h"

#define MAXE 400
struct dir {
    int n, v;                 /* real entries, virtual children */
    loff_t pos[MAXE];         /* position that re-reads real entry i */
    loff_t eof;
    bool compat;
};
struct ent { int id; loff_t d_off; };   /* id < n real, n + k virtual k */
struct stream { struct nm_rd_state st; loff_t pos; bool base; int fs_error; };

static bool is_virtual(struct stream *s, struct dir *d, loff_t pos)
{
    if (s->base) /* previous driver: fixed "nm" signature */
        return d->compat ? ((u64)pos & 0xFFFF0000ULL) == (0x6E6DULL << 16)
                         : ((u64)pos & 0xFFFF000000000000ULL) == (0x6E6DULL << 48);
    return nm_rd_is_virtual(&s->st, pos, d->compat);
}
static loff_t pack(struct stream *s, struct dir *d, u32 id)
{
    if (s->base) return d->compat ? (loff_t)((0x6E6DULL << 16) | id) : (loff_t)((0x6E6DULL << 48) | id);
    return nm_rd_pack(&s->st, id, 0, d->compat);
}
static void note_real(struct stream *s, struct dir *d, loff_t pos) { if (!s->base) nm_rd_note_real(&s->st, pos, d->compat); }

/* one getdents call, at most cap entries */
static int getdents(struct stream *s, struct dir *d, int cap, struct ent *out)
{
    int got = 0, i;
    if (!is_virtual(s, d, s->pos)) {
        if (s->pos == 0) i = 0;
        else if (s->pos == d->eof) i = d->n;
        else {
            for (i = 0; i < d->n && d->pos[i] != s->pos; i++) {}
            if (i == d->n) { s->fs_error++; return 0; }   /* the filesystem was given a position it never made */
        }
        for (; i < d->n; i++) {
            if (got == cap) { s->pos = d->pos[i]; goto real_done; }
            if (got) out[got - 1].d_off = d->pos[i];
            note_real(s, d, d->pos[i]);
            out[got++].id = i;
        }
        s->pos = d->eof;
real_done:
        note_real(s, d, s->pos);
        if (got) { out[got - 1].d_off = s->pos; return got; }
        if (!s->base && !nm_rd_enter_virtual(&s->st)) return 0;
        s->pos = pack(s, d, 0);
    }
    for (u32 id = d->compat ? nm_rd_unpack_id(s->pos, true) : nm_rd_unpack_id(s->pos, false); ; id++) {
        if ((int)id >= d->v) { s->pos = pack(s, d, id); break; }
        if (got == cap) { s->pos = pack(s, d, id); break; }
        out[got].id = d->n + (int)id;
        out[got++].d_off = pack(s, d, id + 1);
    }
    return got;
}

static int list_all(struct stream *s, struct dir *d, int cap, struct ent *all)
{
    struct ent buf[MAXE];
    int total = 0, got;
    for (int calls = 0; calls < 4 * MAXE && (got = getdents(s, d, cap, buf)) > 0; calls++)
        for (int k = 0; k < got && total < 2 * MAXE; k++) all[total++] = buf[k];
    return total;
}

static u64 rng = 88172645463325252ULL;
static u64 next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static bool used(struct dir *d, int upto, loff_t p) { for (int i = 0; i < upto; i++) if (d->pos[i] == p) return true; return p == 0; }

/* fam: 0 ext4 64-bit hashes, 1 ext4 32-bit (compat), 2 small indices, 3 FUSE any value,
 * 4 ext4 64-bit with cursor-shaped positions, 5 compat with cursor-shaped positions */
static void make(struct dir *d, int fam, int n, int v)
{
    memset(d, 0, sizeof(*d));
    d->n = n; d->v = v; d->compat = fam == 1 || fam == 5;
    for (int i = 0; i < n; i++) {
        loff_t p;
        do {
            switch (fam) {
            case 0: p = (loff_t)(next() >> 1); break;
            case 1: p = (loff_t)(next() >> 33); break;
            case 2: p = i + 2; break;
            case 3: p = (loff_t)next(); break;
            case 4: p = (i % 2) ? (loff_t)(((u64)nm_rd_candidate((unsigned)(next() % 8)) << 48) | (next() % 8)) : (loff_t)(next() >> 1); break;
            default: p = (i % 2) ? (loff_t)(((u64)nm_rd_candidate((unsigned)(next() % 8)) << 16) | (next() % 8)) : (loff_t)(next() >> 33); break;
            }
        } while (used(d, i, p));
        d->pos[i] = p;
    }
    if (fam == 0 || fam == 2 || fam == 4) {
        for (int i = 1; i < n; i++) for (int j = i; j > 0 && d->pos[j - 1] > d->pos[j]; j--) { loff_t t = d->pos[j]; d->pos[j] = d->pos[j - 1]; d->pos[j - 1] = t; }
    }
    switch (fam) {
    case 0: case 4: d->eof = INT64_MAX; break;
    case 1: case 5: d->eof = 0x7FFFFFFF; break;
    case 2: d->eof = n + 2; break;
    default: do d->eof = (loff_t)next(); while (used(d, n, d->eof)); break;
    }
}

static int check(struct dir *d, bool base, const char *what)
{
    struct ent all[2 * MAXE], again[2 * MAXE], one[2];
    int bad = 0;
    for (int cap = 1; cap <= 7; cap += 3) {
        struct stream s = { .base = base };
        int total = list_all(&s, d, cap, all), seen[MAXE * 2] = { 0 };
        for (int k = 0; k < total; k++) seen[all[k].id]++;
        for (int id = 0; id < d->n + d->v; id++)
            if (seen[id] != 1) { if (!bad++) printf("  %s cap %d: entry %d listed %d times (fs errors %d)\n", what, cap, id, seen[id], s.fs_error); }
        if (total != d->n + d->v && !bad++) printf("  %s cap %d: %d entries, want %d\n", what, cap, total, d->n + d->v);
        /* telldir after every entry, seekdir back to each, read one */
        for (int k = 0; k < total && !bad; k++) {
            s.pos = all[k].d_off;
            int got = getdents(&s, d, 1, one);
            int want = k + 1 < total ? all[k + 1].id : -1;
            if ((got ? one[0].id : -1) != want) { bad++; printf("  %s cap %d: seekdir after entry %d gave %d, want %d\n", what, cap, all[k].id, got ? one[0].id : -1, want); }
        }
        /* rewind, list again */
        s.pos = 0;
        int t2 = list_all(&s, d, cap, again);
        if (!bad && (t2 != total || memcmp(again, all, sizeof(all[0]) * (size_t)total))) { bad++; printf("  %s cap %d: second pass after rewind differs\n", what, cap); }
    }
    return bad;
}

int main(int argc, char **argv)
{
    bool base = argc > 1 && !strcmp(argv[1], "base");
    static const char *names[] = { "ext4-64", "ext4-32-compat", "index", "fuse-any", "ext4-64-cursor-shaped", "compat-cursor-shaped" };
    int failed = 0;
    for (int fam = 0; fam < 6; fam++) {
        int bad_dirs = 0;
        for (int seed = 0; seed < 300; seed++) {
            struct dir d;
            make(&d, fam, 1 + (int)(next() % 60), (int)(next() % 9));
            bad_dirs += check(&d, base, names[fam]) != 0;
        }
        printf("%s %s: %d of 300 directories violate an invariant\n", bad_dirs ? "FAIL" : "ok  ", names[fam], bad_dirs);
        failed += bad_dirs != 0;
    }
    /* bound: real positions carrying every candidate tag leave no free tag; the virtual phase is skipped, no real entry is lost */
    if (!base) {
        struct dir d; memset(&d, 0, sizeof(d));
        d.n = NM_RD_TAGS; d.v = 3; d.eof = INT64_MAX;
        for (int i = 0; i < NM_RD_TAGS; i++) d.pos[i] = (loff_t)((u64)nm_rd_candidate((unsigned)i) << 48 | 1);
        struct stream s = { 0 }; struct ent all[2 * MAXE];
        int total = list_all(&s, &d, 4, all);
        printf("bound: all %d candidate tags taken by real positions: %d entries listed (%d real, %d virtual skipped), fs errors %d\n",
               NM_RD_TAGS, total, d.n, d.v, s.fs_error);
        if (total != d.n || s.fs_error) failed++;
    }
    return failed ? 1 : 0;
}
