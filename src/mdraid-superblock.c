#include "mdraid-superblock.h"

#include <fcntl.h>
#include <linux/fs.h>
#include <linux/raid/md_p.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static char *
uuid_string (const guint8 bytes[16])
{
    GString *uuid = g_string_sized_new (35);
    for (guint i = 0; i < 16; i++) {
        if (i > 0 && i % 4 == 0)
            g_string_append_c (uuid, ':');
        g_string_append_printf (uuid, "%02x", bytes[i]);
    }
    return g_string_free (uuid, FALSE);
}

static gboolean
checksum_valid (const struct mdp_superblock_1 *super, guint roles)
{
    const guint8 *data = (const guint8 *) super;
    const guint size = sizeof (*super) + 2 * roles;
    guint64 sum = 0;
    guint offset = 0;
    for (; offset + 4 <= size; offset += 4) {
        if (offset == offsetof (struct mdp_superblock_1, sb_csum))
            continue;
        guint32 word;
        memcpy (&word, data + offset, sizeof (word));
        sum += GUINT32_FROM_LE (word);
    }
    if (offset < size) {
        guint16 word;
        memcpy (&word, data + offset, sizeof (word));
        sum += GUINT16_FROM_LE (word);
    }
    return (guint32) (sum + (sum >> 32)) == GUINT32_FROM_LE (super->sb_csum);
}

static guint32
bitmap_u32 (const guint8 *header, guint offset)
{
    guint32 value;
    memcpy (&value, header + offset, sizeof (value));
    return GUINT32_FROM_LE (value);
}

static guint64
bitmap_u64 (const guint8 *header, guint offset)
{
    guint64 value;
    memcpy (&value, header + offset, sizeof (value));
    return GUINT64_FROM_LE (value);
}

/* Linux 6.12 md-bitmap.h: portable, non-clustered bitmap, with no header checksum. */
static GVariant *
read_bitmap (int fd, const struct mdp_superblock_1 *super, guint64 sectors, guint roles)
{
    if (!(GUINT32_FROM_LE (super->feature_map) & MD_FEATURE_BITMAP_OFFSET))
        return NULL;
    const gint64 base = GUINT64_FROM_LE (super->super_offset);
    const gint32 relative = (gint32) GUINT32_FROM_LE (super->bitmap_offset);
    const gint64 start = base + relative;
    const guint64 data = GUINT64_FROM_LE (super->data_offset);
    const guint64 size = GUINT64_FROM_LE (super->size);
    const guint64 super_end = base + (sizeof (*super) + 2 * roles + 511) / 512;
    if (!relative || start < 0 || (guint64) start >= sectors ||
        data >= sectors || !size || size > sectors - data ||
        ((guint64) start >= data && (guint64) start < data + size) ||
        (start >= base && (guint64) start < super_end))
        return NULL;

    /* A native bitmap can start inside a 4 KiB-aligned direct I/O window. */
    g_autofree void *buffer = NULL;
    guint64 aligned = (guint64) start & ~(guint64) 7;
    if (sectors - aligned < 8 || posix_memalign (&buffer, 4096, 4096) != 0 ||
        pread (fd, buffer, 4096, (off_t) (aligned * 512)) != 4096)
        return NULL;
    const guint8 *header = (guint8 *) buffer + (start - aligned) * 512;
    guint32 chunk = bitmap_u32 (header, 52);
    guint64 sync_size = bitmap_u64 (header, 40);
    if (bitmap_u32 (header, 0) != 0x6d746962 || bitmap_u32 (header, 4) != 4 ||
        memcmp (header + 8, super->set_uuid, 16) != 0 || bitmap_u32 (header, 48) != 0 ||
        bitmap_u32 (header, 68) != 0 || sync_size != size ||
        chunk < 512 || (chunk & (chunk - 1)) != 0)
        return NULL;
    guint64 chunk_sectors = chunk / 512;
    guint64 bits = (sync_size + chunk_sectors - 1) / chunk_sectors;
    guint64 length = (256 + (bits + 7) / 8 + 511) / 512;
    guint32 reserved = bitmap_u32 (header, 64);
    if (length > sectors - start || (reserved && (reserved < length || reserved > sectors - start)) ||
        (start < base && length > (guint64) (base - start)) ||
        ((guint64) start < data && length > data - start))
        return NULL;
    return g_variant_ref_sink (g_variant_new ("(iutttu)", relative, chunk, sync_size,
        bitmap_u64 (header, 24), bitmap_u64 (header, 32), reserved));
}

static GVariant *
read_superblock (int fd, GVariant **bitmap)
{
    struct stat info;
    guint64 bytes;
    int flags = fcntl (fd, F_GETFL);
    if (flags < 0 || (flags & O_DIRECT) == 0 ||
        fstat (fd, &info) != 0 || !S_ISBLK (info.st_mode) ||
        ioctl (fd, BLKGETSIZE64, &bytes) != 0 || bytes < 24 * 512 || bytes > G_MAXINT64)
        return NULL;

    const guint64 sectors = bytes / 512;
    const guint64 locations[] = { (sectors - 16) & ~(guint64) 7, 0, 8 };
    // md updates member superblocks through bios, outside the block file's page cache.
    void *buffer = NULL;
    if (posix_memalign (&buffer, 4096, 4096) != 0)
        return NULL;
    g_autofree struct mdp_superblock_1 *super = buffer;
    g_autoptr (GVariant) found = NULL;
    for (guint minor = 0; minor < G_N_ELEMENTS (locations); minor++) {
        if (pread (fd, super, 4096, (off_t) (locations[minor] * 512)) != 4096 ||
            GUINT32_FROM_LE (super->magic) != MD_SB_MAGIC)
            continue;
        guint count = GUINT32_FROM_LE (super->max_dev);
        guint device = GUINT32_FROM_LE (super->dev_number);
        if (found || GUINT32_FROM_LE (super->major_version) != 1 ||
            GUINT64_FROM_LE (super->super_offset) != locations[minor] ||
            count > (4096 - sizeof (*super)) / 2 || device >= count ||
            !checksum_valid (super, count))
            return NULL;
        if (GUINT32_FROM_LE (super->level) == 1) {
            guint64 data = GUINT64_FROM_LE (super->data_offset);
            guint64 size = GUINT64_FROM_LE (super->size);
            if (data >= sectors || !size || size > sectors - data)
                return NULL;
        }
        g_autofree char *uuid = uuid_string (super->set_uuid);
        g_autofree char *member = uuid_string (super->device_uuid);
        found = g_variant_ref_sink (g_variant_new ("(ssuiuuuuttt)", uuid, member, minor,
            (gint32) GUINT32_FROM_LE (super->level), GUINT32_FROM_LE (super->layout),
            GUINT32_FROM_LE (super->raid_disks), (guint32) GUINT16_FROM_LE (super->dev_roles[device]),
            GUINT32_FROM_LE (super->feature_map), GUINT64_FROM_LE (super->events),
            GUINT64_FROM_LE (super->resync_offset), GUINT64_FROM_LE (super->size)));
        if (bitmap)
            *bitmap = read_bitmap (fd, super, sectors, count);
    }
    return g_steal_pointer (&found);
}

GVariant *
majoris_mdraid_read_superblock (int fd)
{
    return read_superblock (fd, NULL);
}

static char *
read_attr (const char *md, const char *attr)
{
    g_autofree char *path = g_build_filename (md, attr, NULL);
    char *value = NULL;
    return g_file_get_contents (path, &value, NULL, NULL) ? g_strstrip (value) : NULL;
}

MajorisMdRaidReadd
majoris_mdraid_review_readd (GVariant *former, int survivor_fd, const char *md, char **token)
{
    *token = NULL;
    g_autoptr (GVariant) bitmap = NULL;
    g_autoptr (GVariant) survivor = read_superblock (survivor_fd, &bitmap);
    struct stat st;
    guint64 sequence;
    if (!former || !survivor || fstat (survivor_fd, &st) != 0 ||
        ioctl (survivor_fd, BLKGETDISKSEQ, &sequence) != 0 || !sequence)
        return MAJORIS_MDRAID_READD_INCOMPATIBLE;

    const char *uuid, *member, *old_uuid, *old_member;
    guint version, layout, count, slot, features, old_version, old_layout, old_count, old_slot, old_features;
    gint level, old_level;
    guint64 events, clean, size, old_events, old_clean, old_size;
    g_variant_get (survivor, "(&s&suiuuuuttt)", &uuid, &member, &version, &level, &layout,
        &count, &slot, &features, &events, &clean, &size);
    g_variant_get (former, "(&s&suiuuuuttt)", &old_uuid, &old_member, &old_version, &old_level, &old_layout,
        &old_count, &old_slot, &old_features, &old_events, &old_clean, &old_size);
    g_autofree char *component = read_attr (md, "component_size");
    guint64 kib;
    if (!g_str_equal (uuid, old_uuid) || g_str_equal (member, old_member) ||
        g_str_equal (member, "00000000:00000000:00000000:00000000") ||
        g_str_equal (old_member, "00000000:00000000:00000000:00000000") ||
        version != old_version || level != 1 || old_level != 1 || layout != 0 || old_layout != 0 ||
        count != 2 || old_count != 2 || slot >= 2 || old_slot != 1 - slot ||
        ((features | old_features) & ~MD_FEATURE_BITMAP_OFFSET) != 0 ||
        !old_events || old_events > events || clean != G_MAXUINT64 || old_clean != G_MAXUINT64 ||
        size != old_size || !component ||
        !g_ascii_string_to_unsigned (component, 10, 1, G_MAXUINT64 / 2, &kib, NULL) || kib * 2 != size)
        return MAJORIS_MDRAID_READD_INCOMPATIBLE;

    g_autofree char *location = read_attr (md, "bitmap/location");
    g_autofree char *policy = read_attr (md, "consistency_policy");
    g_autofree char *bitmap_record = NULL;
    if (g_strcmp0 (location, "none") == 0 && g_strcmp0 (policy, "resync") == 0 &&
        !features && !old_features && old_events == events) {
        bitmap_record = g_strdup ("none");
    } else {
        g_autofree char *metadata = read_attr (md, "bitmap/metadata");
        g_autofree char *chunksize = read_attr (md, "bitmap/chunksize");
        g_autofree char *can_clear = read_attr (md, "bitmap/can_clear");
        if (!bitmap || !(old_features & MD_FEATURE_BITMAP_OFFSET) ||
            g_strcmp0 (policy, "bitmap") != 0 || g_strcmp0 (metadata, "internal") != 0 ||
            (g_strcmp0 (can_clear, "true") != 0 && g_strcmp0 (can_clear, "false") != 0))
            return MAJORIS_MDRAID_READD_UNVERIFIED_BITMAP;
        gint offset;
        guint chunk, reserved;
        guint64 sync_size, bitmap_events, cleared;
        g_variant_get (bitmap, "(iutttu)", &offset, &chunk, &sync_size, &bitmap_events, &cleared, &reserved);
        g_autofree char *expected_location = g_strdup_printf ("%+d", offset);
        g_autofree char *expected_chunk = g_strdup_printf ("%u", chunk);
        if (g_strcmp0 (location, expected_location) != 0 || g_strcmp0 (chunksize, expected_chunk) != 0 ||
            bitmap_events < events || bitmap_events - events > 1 || !cleared || cleared > events)
            return MAJORIS_MDRAID_READD_UNVERIFIED_BITMAP;
        if (old_events < cleared)
            return MAJORIS_MDRAID_READD_STALE;
        g_autofree char *header_record = g_variant_print (bitmap, TRUE);
        bitmap_record = g_strjoin ("\n", header_record, can_clear, NULL);
    }
    g_autofree char *old_record = g_variant_print (former, TRUE);
    g_autofree char *live_record = g_variant_print (survivor, TRUE);
    g_autofree char *evidence = g_strdup_printf ("%u:%u:%" G_GUINT64_FORMAT "\n%s\n%s\n%s",
        major (st.st_rdev), minor (st.st_rdev), sequence, old_record, live_record, bitmap_record);
    *token = g_compute_checksum_for_string (G_CHECKSUM_SHA256, evidence, -1);
    return old_events == events ? MAJORIS_MDRAID_READD_CURRENT : MAJORIS_MDRAID_READD_BITMAP;
}
