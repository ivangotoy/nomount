#ifndef _NOMOUNT_READDIR_H
#define _NOMOUNT_READDIR_H

/*
 * Readdir cursor of one open directory stream: which positions are NoMount
 * virtual cursors. Pure logic (u16/u64/loff_t/bool only), also built on the
 * host by tests/readdir_model.c.
 *
 * Real filesystems may hand out any position value (ext4 htree hashes, FUSE
 * offsets from the daemon), so a fixed signature in the value can collide.
 * Instead each stream picks its cursor tag (bits 63-48, or 31-16 for 32-bit
 * callers) from NM_RD_TAGS candidates, skipping every candidate that the tag
 * of a real position already handed out on this stream matches. A real
 * position that turns up later with the chosen tag retires it: old cursors
 * then resolve as real positions and the next virtual phase picks again.
 */
#define NM_RD_TAGS 64
#define NM_RD_TAG_BASE 0x6E6DU /* "nm": the first choice, as before */
#define NM_RD_TAG_STEP 0x0201U
#define NM_RD_TAG_STEP_INV 0x7E01U /* NM_RD_TAG_STEP * NM_RD_TAG_STEP_INV == 1 mod 0x8000 */

struct nm_rd_state {
    u64 seen;   /* bit k: candidate k matched the tag of a real position */
    u16 tag;    /* tag of the current cursors, 0 = none */
};

static inline u16 nm_rd_candidate(unsigned int k)
{
    return (u16)((NM_RD_TAG_BASE + k * NM_RD_TAG_STEP) & 0x7FFFU);
}

static inline u16 nm_rd_tag_of(loff_t pos, bool compat)
{
    return compat ? (u16)(((u64)pos >> 16) & 0xFFFF) : (u16)(((u64)pos >> 48) & 0xFFFF);
}

static inline bool nm_rd_is_virtual(const struct nm_rd_state *st, loff_t pos, bool compat)
{
    if (!st || !st->tag) return false;
    if (compat && ((u64)pos >> 32)) return false;
    return nm_rd_tag_of(pos, compat) == st->tag;
}

/* a real position was handed out (an entry's d_off or the final position) */
static inline void nm_rd_note_real(struct nm_rd_state *st, loff_t pos, bool compat)
{
    u16 t;
    unsigned int k;

    if (compat && ((u64)pos >> 32)) return;
    t = nm_rd_tag_of(pos, compat);
    if (t & 0x8000U) return;
    k = (((t - NM_RD_TAG_BASE) & 0x7FFFU) * NM_RD_TAG_STEP_INV) & 0x7FFFU;
    if (k >= NM_RD_TAGS) return;
    st->seen |= 1ULL << k;
    if (t == st->tag) st->tag = 0;
}

/* before the first virtual cursor of a phase; false = no free tag, skip the virtual phase */
static inline bool nm_rd_enter_virtual(struct nm_rd_state *st)
{
    unsigned int k;

    if (st->tag) return true;
    for (k = 0; k < NM_RD_TAGS; k++) {
        if (!(st->seen & (1ULL << k))) {
            st->tag = nm_rd_candidate(k);
            return true;
        }
    }
    return false;
}

static inline loff_t nm_rd_pack(const struct nm_rd_state *st, u32 id, u32 frag, bool compat)
{
    if (compat) return (loff_t)(((u64)st->tag << 16) | (id & 0xFFFF));
    return (loff_t)(((u64)st->tag << 48) | ((u64)(frag & 0xFFFF) << 32) | id);
}

static inline u32 nm_rd_unpack_id(loff_t pos, bool compat)
{
    return compat ? (u32)(pos & 0xFFFF) : (u32)pos;
}

static inline u32 nm_rd_unpack_frag(loff_t pos, bool compat)
{
    return compat ? 0 : (u32)(((u64)pos >> 32) & 0xFFFF);
}

#endif /* _NOMOUNT_READDIR_H */
