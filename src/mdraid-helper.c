#include "mdraid-superblock.h"

#include <fcntl.h>
#include <gio/gio.h>
#include <linux/fs.h>
#include <linux/major.h>
#include <linux/raid/md_u.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

typedef struct {
    int fd;
    char path[64];
    char sysfs[64];
    char number[32];
} Block;

static char *
read_attr (const char *dir, const char *attribute)
{
    g_autofree char *path = g_build_filename (dir, attribute, NULL);
    char *value = NULL;
    if (!g_file_get_contents (path, &value, NULL, NULL))
        return NULL;
    return g_strstrip (value);
}

static gboolean
is_attr (const char *dir, const char *attribute, const char *expected)
{
    g_autofree char *value = read_attr (dir, attribute);
    return g_strcmp0 (value, expected) == 0;
}

static gboolean
uuid_matches (const char *dir, const char *expected)
{
    g_autofree char *value = read_attr (dir, "uuid");
    if (!value)
        return FALSE;
    g_strdelimit (value, "-", ':');
    char kernel[33] = { 0 }, requested[33] = { 0 };
    guint left = 0, right = 0;
    for (const char *p = value; *p; p++)
        if (*p != ':' && left < 32) kernel[left++] = *p;
    for (const char *p = expected; *p; p++)
        if (*p != ':' && right < 32) requested[right++] = *p;
    return left == 32 && right == 32 && g_str_equal (kernel, requested);
}

static gboolean
open_block (Block *block, const char *number)
{
    guint major_number, minor_number;
    char tail;
    struct stat st;
    if (strlen (number) > 21 || sscanf (number, "%u:%u%c", &major_number, &minor_number, &tail) != 2)
        return FALSE;
    g_snprintf (block->number, sizeof (block->number), "%u:%u", major_number, minor_number);
    if (!g_str_equal (number, block->number))
        return FALSE;
    g_snprintf (block->path, sizeof (block->path), "/dev/block/%s", block->number);
    g_snprintf (block->sysfs, sizeof (block->sysfs), "/sys/dev/block/%s", block->number);
    block->fd = open (block->path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_DIRECT);
    return block->fd >= 0 && fstat (block->fd, &st) == 0 && S_ISBLK (st.st_mode) &&
        major (st.st_rdev) == major_number && minor (st.st_rdev) == minor_number &&
        is_attr (block->sysfs, "dev", block->number);
}

static char *
disk_sequence (const Block *block)
{
    guint64 sequence;
    if (ioctl (block->fd, BLKGETDISKSEQ, &sequence) != 0 || !sequence)
        return NULL;
    g_autofree char *partition = read_attr (block->sysfs, "partition");
    g_autofree char *live = read_attr (block->sysfs, partition ? "../diskseq" : "diskseq");
    g_autofree char *opened = g_strdup_printf ("%" G_GUINT64_FORMAT, sequence);
    return g_strcmp0 (live, opened) == 0 ? g_steal_pointer (&live) : NULL;
}

static char *
mdadm_path (const Block *block)
{
    g_autofree char *path = realpath (block->path, NULL);
    struct stat live, original;
    if (!path || !g_str_has_prefix (path, "/dev/") || path[5] == 0 ||
        stat (path, &live) != 0 || fstat (block->fd, &original) != 0 ||
        !S_ISBLK (live.st_mode) || live.st_rdev != original.st_rdev)
        return NULL;
    for (const char *p = path + 5; *p; p++)
        if (!g_ascii_isalnum (*p) && *p != '_' && *p != '-')
            return NULL;
    return g_steal_pointer (&path);
}

static gboolean
idle_block (const Block *block)
{
    g_autofree char *holders = g_build_filename (block->sysfs, "holders", NULL);
    g_autoptr (GDir) dir = g_dir_open (holders, 0, NULL);
    if (!dir || g_dir_read_name (dir))
        return FALSE;
    g_autoptr (GDir) children = g_dir_open (block->sysfs, 0, NULL);
    if (!children)
        return FALSE;
    const char *child;
    while ((child = g_dir_read_name (children))) {
        g_autofree char *path = g_build_filename (block->sysfs, child, "partition", NULL);
        if (g_file_test (path, G_FILE_TEST_EXISTS))
            return FALSE;
    }
    const char *mounts[] = { "/proc/self/mountinfo", "/proc/1/mountinfo" };
    for (guint i = 0; i < G_N_ELEMENTS (mounts); i++) {
        g_autofree char *contents = NULL;
        if (!g_file_get_contents (mounts[i], &contents, NULL, NULL))
            return FALSE;
        g_auto (GStrv) lines = g_strsplit (contents, "\n", -1);
        for (guint j = 0; lines[j] && *lines[j]; j++) {
            g_auto (GStrv) fields = g_strsplit (lines[j], " ", 4);
            if (g_strv_length (fields) != 4 || g_str_equal (fields[2], block->number))
                return FALSE;
        }
    }
    g_autofree char *swaps = NULL;
    if (!g_file_get_contents ("/proc/swaps", &swaps, NULL, NULL))
        return FALSE;
    g_auto (GStrv) lines = g_strsplit (swaps, "\n", -1);
    for (guint i = 1; lines[i] && *lines[i]; i++) {
        char *end = strpbrk (lines[i], " \t");
        if (!end)
            return FALSE;
        *end = 0;
        struct stat info;
        if (stat (lines[i], &info) != 0)
            return FALSE;
        if (S_ISBLK (info.st_mode)) {
            g_autofree char *number = g_strdup_printf ("%u:%u", major (info.st_rdev), minor (info.st_rdev));
            if (g_str_equal (number, block->number))
                return FALSE;
        }
    }
    return TRUE;
}

typedef struct {
    const char *array_uuid;
    const char *member_uuid;
    guint version, layout, count, slot, features;
    gint level;
    guint64 events, resync, sectors;
} Metadata;

static gboolean
read_metadata (GVariant *record, const char *uuid, Metadata *metadata)
{
    if (!record)
        return FALSE;
    g_variant_get (record, "(&s&suiuuuuttt)", &metadata->array_uuid, &metadata->member_uuid,
        &metadata->version, &metadata->level, &metadata->layout, &metadata->count, &metadata->slot,
        &metadata->features, &metadata->events, &metadata->resync, &metadata->sectors);
    return g_str_equal (metadata->array_uuid, uuid) && metadata->level == 1 &&
        metadata->layout == 0 && metadata->count == 2 && metadata->slot < 2 &&
        metadata->events > 0 && metadata->resync == G_MAXUINT64 && metadata->sectors > 0 &&
        (metadata->features & ~1U) == 0;
}

static gboolean
verify_array (const Block *array, const Block *member, const char *md, const char *uuid,
              GVariant *target_record, const Metadata *target, const char *review)
{
    gboolean readd = review != NULL;
    g_autofree char *version = g_strdup_printf ("1.%u", target->version);
    if (!uuid_matches (md, uuid) || !is_attr (md, "level", "raid1") ||
        !is_attr (md, "raid_disks", "2") || !is_attr (md, "metadata_version", version) ||
        !is_attr (md, "array_state", "clean") || !is_attr (md, "sync_action", "idle") ||
        !is_attr (md, "degraded", readd ? "1" : "0") || !idle_block (array) ||
        (readd && !idle_block (member)))
        return FALSE;
    g_autoptr (GDir) dir = g_dir_open (md, 0, NULL);
    if (!dir)
        return FALSE;
    guint found = 0;
    gboolean found_target = FALSE, found_survivor = FALSE;
    const char *entry;
    while ((entry = g_dir_read_name (dir))) {
        if (!g_str_has_prefix (entry, "dev-"))
            continue;
        g_autofree char *device = g_build_filename (md, entry, NULL);
        g_autofree char *number = read_attr (device, "block/dev");
        gboolean selected = g_strcmp0 (number, member->number) == 0;
        if (!number || (selected && readd) || !is_attr (device, "state", "in_sync"))
            return FALSE;
        guint slot = selected ? target->slot : 1U - target->slot;
        if (!is_attr (device, "slot", slot ? "1" : "0"))
            return FALSE;
        if (selected) {
            found_target = TRUE;
        } else {
            Block survivor = { .fd = -1 };
            gboolean opened = open_block (&survivor, number);
            g_autofree char *survivor_seq = opened ? disk_sequence (&survivor) : NULL;
            g_autofree char *target_seq = disk_sequence (member);
            g_autofree char *token = NULL;
            g_autoptr (GVariant) record = opened && !readd ? majoris_mdraid_read_superblock (survivor.fd) : NULL;
            MajorisMdRaidReadd eligibility = opened && readd ?
                majoris_mdraid_review_readd (target_record, survivor.fd, md, &token) :
                MAJORIS_MDRAID_READD_INCOMPATIBLE;
            if (survivor.fd >= 0) close (survivor.fd);
            Metadata metadata;
            if (!survivor_seq || !target_seq || g_str_equal (survivor_seq, target_seq))
                return FALSE;
            if (readd) {
                if (eligibility == MAJORIS_MDRAID_READD_STALE)
                    g_printerr ("The former member predates the retained bitmap history.\n");
                else if (eligibility == MAJORIS_MDRAID_READD_UNVERIFIED_BITMAP)
                    g_printerr ("Bitmap history could not be verified. Re-addition is unavailable.\n");
                if (!token || !g_str_equal (token, review))
                    return FALSE;
            } else if (!read_metadata (record, uuid, &metadata) || metadata.slot != slot ||
                       g_str_equal (metadata.member_uuid, target->member_uuid) ||
                       metadata.version != target->version || metadata.sectors != target->sectors ||
                       metadata.events != target->events) {
                return FALSE;
            }
            found_survivor = TRUE;
        }
        found++;
    }
    return found_survivor && found_target == !readd && found == (readd ? 1U : 2U);
}

int
main (int argc, char **argv)
{
    if (geteuid () != 0 || argc < 2 ||
        (!g_str_equal (argv[1], "mark-faulty") && !g_str_equal (argv[1], "re-add-member")))
        return 2;
    gboolean readd = g_str_equal (argv[1], "re-add-member");
    if (argc != (readd ? 11 : 10))
        return 2;
    Block array = { .fd = -1 }, member = { .fd = -1 };
    if (!open_block (&array, argv[2]) || !open_block (&member, argv[4]))
        return 2;
    g_autofree char *array_seq = disk_sequence (&array);
    g_autofree char *member_seq = disk_sequence (&member);
    g_autofree char *md = g_build_filename (array.sysfs, "md", NULL);
    g_autoptr (GVariant) record = majoris_mdraid_read_superblock (member.fd);
    Metadata target;
    guint64 events;
    gboolean valid_events = g_ascii_string_to_unsigned (argv[9], 10, 1, G_MAXUINT64, &events, NULL);
    if (!array_seq || !member_seq || !g_str_equal (array_seq, argv[3]) ||
        !g_str_equal (member_seq, argv[5]) || !read_metadata (record, argv[6], &target) ||
        !g_str_equal (target.member_uuid, argv[7]) || !g_str_equal (argv[8], target.slot ? "1" : "0") ||
        !valid_events || events != target.events ||
        !verify_array (&array, &member, md, argv[6], record, &target, readd ? argv[10] : NULL)) {
        g_printerr ("The reviewed RAID1 metadata, redundancy or device identity could not be verified.\n");
        return 2;
    }
    if (!readd) {
        struct stat st;
        if (fstat (member.fd, &st) != 0 || ioctl (array.fd, SET_DISK_FAULTY, st.st_rdev) != 0) {
            g_printerr ("The kernel did not accept the RAID member fault request.\n");
            return 3;
        }
        return 0;
    }
    g_autofree char *array_path = mdadm_path (&array);
    g_autofree char *member_path = mdadm_path (&member);
    g_autofree char *current_array_seq = disk_sequence (&array);
    g_autofree char *current_member_seq = disk_sequence (&member);
    if (!array_path || !member_path ||
        g_strcmp0 (current_array_seq, array_seq) != 0 || g_strcmp0 (current_member_seq, member_seq) != 0)
        return 2;
    const char *command[] = { "/usr/sbin/mdadm", "--manage", array_path, "--re-add", member_path, NULL };
    const char *environment[] = { "PATH=/usr/sbin:/usr/bin", "LC_ALL=C", NULL };
    gint status = 0;
    g_autoptr (GError) error = NULL;
    if (!g_spawn_sync ("/", (char **) command, (char **) environment, 0, NULL, NULL,
                       NULL, NULL, &status, &error) || !g_spawn_check_wait_status (status, &error)) {
        g_printerr ("mdadm did not confirm re-addition: %s\n", error->message);
        return 3;
    }
    return 0;
}
