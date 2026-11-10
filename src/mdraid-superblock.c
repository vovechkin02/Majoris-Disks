#include "mdraid-superblock.h"

#include <fcntl.h>
#include <linux/fs.h>
#include <linux/raid/md_p.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
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

GVariant *
majoris_mdraid_read_superblock (int fd)
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
        g_autofree char *uuid = uuid_string (super->set_uuid);
        g_autofree char *member = uuid_string (super->device_uuid);
        found = g_variant_ref_sink (g_variant_new ("(ssuiuuuuttt)", uuid, member, minor,
            (gint32) GUINT32_FROM_LE (super->level), GUINT32_FROM_LE (super->layout),
            GUINT32_FROM_LE (super->raid_disks), (guint32) GUINT16_FROM_LE (super->dev_roles[device]),
            GUINT32_FROM_LE (super->feature_map), GUINT64_FROM_LE (super->events),
            GUINT64_FROM_LE (super->resync_offset), GUINT64_FROM_LE (super->size)));
    }
    return g_steal_pointer (&found);
}
