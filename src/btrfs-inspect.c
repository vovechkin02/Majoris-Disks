/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "btrfs-inspect.h"
#include <fcntl.h>
#include <errno.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <stdlib.h>
#include <sys/statvfs.h>
#include <linux/openat2.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <unistd.h>

static char *
format_uuid (const guint8 *uuid)
{
    return g_strdup_printf ("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
        uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]);
}

char *
majoris_btrfs_inspect_subvolume (const char *path, guint64 id, const char *filesystem,
                                const char *origin, gboolean *read_only)
{
    struct open_how how = { .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC, .resolve = RESOLVE_NO_SYMLINKS };
    int fd = syscall (SYS_openat2, AT_FDCWD, path, &how, sizeof how);
    if (fd < 0)
        return NULL;
    struct stat statbuf;
    struct btrfs_ioctl_fs_info_args fs = { 0 };
    struct btrfs_ioctl_get_subvol_info_args subvol = { 0 };
    __u64 flags = 0;
    gboolean valid = fstat (fd, &statbuf) == 0 && statbuf.st_ino == 256 &&
        ioctl (fd, BTRFS_IOC_FS_INFO, &fs) == 0 &&
        /* Linux 6.12 can return the positive root-backref lookup result after copying the data. */
        ioctl (fd, BTRFS_IOC_GET_SUBVOL_INFO, &subvol) >= 0 && subvol.treeid == id &&
        ioctl (fd, BTRFS_IOC_SUBVOL_GETFLAGS, &flags) == 0;
    close (fd);
    if (!valid)
        return NULL;

    g_autofree char *fsid = format_uuid (fs.fsid);
    if (g_ascii_strcasecmp (fsid, filesystem) != 0)
        return NULL;
    if (origin != NULL) {
        g_autofree char *parent = format_uuid (subvol.parent_uuid);
        if (g_ascii_strcasecmp (parent, origin) != 0)
            return NULL;
    }
    *read_only = (flags & BTRFS_SUBVOL_RDONLY) != 0;
    return format_uuid (subvol.uuid);
}

/* Return 1 for an active target, 0 if clear, and -1 if identity was uncertain. */
static int
check_namespace_mounts (const char *task, const char *filesystem, const char *root, const char *id_option)
{
    g_autofree char *info_path = g_build_filename (task, "mountinfo", NULL);
    g_autofree char *contents = NULL;
    g_autoptr(GError) error = NULL;
    if (!g_file_get_contents (info_path, &contents, NULL, &error))
        return g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT) ? 0 : -1;
    g_auto(GStrv) lines = g_strsplit (contents, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        g_auto(GStrv) parts = g_strsplit (lines[i], " - ", 2);
        if (parts[1] == NULL || !g_str_has_prefix (parts[1], "btrfs "))
            continue;
        g_auto(GStrv) left = g_strsplit (parts[0], " ", 6);
        g_auto(GStrv) right = g_strsplit (parts[1], " ", 3);
        if (g_strv_length (left) != 6 || g_strv_length (right) != 3)
            return -1;
        g_autofree char *mount_root = g_strcompress (left[3]);
        g_autofree char *mount_path = g_strcompress (left[4]);
        g_auto(GStrv) options = g_strsplit (right[2], ",", -1);
        gsize length = strlen (root);
        if (!g_str_equal (root, mount_root) &&
            !(g_str_has_prefix (mount_root, root) && mount_root[length] == '/') &&
            !g_strv_contains ((const char *const *) options, id_option))
            continue;

        g_autofree char *task_root = g_build_filename (task, "root", NULL);
        int base = open (task_root, O_PATH | O_DIRECTORY | O_CLOEXEC);
        if (base < 0)
            return -1;
        struct open_how how = { .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
            .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_SYMLINKS };
        int fd = syscall (SYS_openat2, base, mount_path, &how, sizeof how);
        close (base);
        if (fd < 0)
            return -1;
        struct statx mount;
        struct btrfs_ioctl_fs_info_args fs = { 0 };
        guint64 expected_id;
        gboolean valid = g_ascii_string_to_unsigned (left[0], 10, 1, G_MAXUINT64, &expected_id, NULL) &&
            statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID, &mount) == 0 &&
            (mount.stx_mask & STATX_MNT_ID) && mount.stx_mnt_id == expected_id &&
            ioctl (fd, BTRFS_IOC_FS_INFO, &fs) == 0;
        close (fd);
        if (!valid)
            return -1;
        g_autofree char *actual = format_uuid (fs.fsid);
        if (g_ascii_strcasecmp (actual, filesystem) == 0)
            return 1;
    }
    return 0;
}

static gboolean
pid_name (const char *name)
{
    return *name != '\0' && strspn (name, "0123456789") == strlen (name);
}

int
majoris_btrfs_mount_use (const char *filesystem, guint64 id, const char *path)
{
    g_autoptr(GDir) processes = g_dir_open ("/proc", 0, NULL);
    if (processes == NULL)
        return -1;
    g_autoptr(GHashTable) seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    g_autofree char *root = g_strconcat ("/", path, NULL);
    g_autofree char *option = g_strdup_printf ("subvolid=%" G_GUINT64_FORMAT, id);
    const char *pid;
    while ((pid = g_dir_read_name (processes)) != NULL) {
        if (!pid_name (pid)) continue;
        g_autofree char *tasks_path = g_build_filename ("/proc", pid, "task", NULL);
        g_autoptr(GError) error = NULL;
        g_autoptr(GDir) tasks = g_dir_open (tasks_path, 0, &error);
        if (tasks == NULL) {
            if (g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT)) continue;
            return -1;
        }
        const char *tid;
        while ((tid = g_dir_read_name (tasks)) != NULL) {
            if (!pid_name (tid)) continue;
            g_autofree char *task = g_build_filename (tasks_path, tid, NULL);
            g_autofree char *ns_path = g_build_filename (task, "ns", "mnt", NULL);
            struct stat ns, root_info;
            if (stat (ns_path, &ns) != 0) {
                if (errno == ENOENT) continue;
                return -1;
            }
            g_autofree char *task_root = g_build_filename (task, "root", NULL);
            if (stat (task_root, &root_info) != 0) {
                if (errno == ENOENT) continue;
                return -1;
            }
            // A chroot may hide mounts from mountinfo even within the same namespace.
            g_autofree char *key = g_strdup_printf ("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT
                ":%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT,
                (guint64) ns.st_dev, (guint64) ns.st_ino, (guint64) root_info.st_dev, (guint64) root_info.st_ino);
            if (g_hash_table_contains (seen, key)) continue;
            int status = check_namespace_mounts (task, filesystem, root, option);
            if (status != 0) return status;
            g_hash_table_add (seen, g_steal_pointer (&key));
        }
    }
    return 0;
}

#define MAX_SPACE_RECORDS 4096
#define SPACE_TYPE_MASK (BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA | BTRFS_BLOCK_GROUP_SYSTEM)

static gsize
space_buffer_size (guint64 count)
{
    if (count == 0 ||
        count > (G_MAXSIZE - sizeof (struct btrfs_ioctl_space_args)) /
            sizeof (struct btrfs_ioctl_space_info) ||
        count > MAX_SPACE_RECORDS)
        return 0;
    return sizeof (struct btrfs_ioctl_space_args) + count * sizeof (struct btrfs_ioctl_space_info);
}

struct btrfs_ioctl_space_args *
majoris_btrfs_read_spaces (int fd, int (*query) (int, struct btrfs_ioctl_space_args *),
                          gpointer (*allocate) (gsize))
{
    struct btrfs_ioctl_space_args count = { 0 };
    if (query (fd, &count) != 0 || count.space_slots != 0)
        return NULL;
    for (guint attempt = 0; attempt < 4; attempt++) {
        guint64 slots = count.total_spaces;
        gsize size = space_buffer_size (slots);
        if (size == 0)
            return NULL;
        g_autofree struct btrfs_ioctl_space_args *spaces = allocate (size);
        if (spaces == NULL)
            return NULL;
        spaces->space_slots = slots;
        if (query (fd, spaces) != 0 || spaces->space_slots != slots ||
            spaces->total_spaces == 0 || spaces->total_spaces > slots)
            return NULL;

        /* Linux caps the returned count at space_slots. It appends the global
         * reserve last, so a full buffer without that record was truncated. */
        if (spaces->spaces[spaces->total_spaces - 1].flags == BTRFS_SPACE_INFO_GLOBAL_RSV)
            return g_steal_pointer (&spaces);
        if (spaces->total_spaces != slots)
            return NULL;
        count = (struct btrfs_ioctl_space_args) { 0 };
        if (query (fd, &count) != 0 || count.space_slots != 0 || count.total_spaces <= slots)
            return NULL;
    }
    return NULL;
}

static int
space_info_ioctl (int fd, struct btrfs_ioctl_space_args *spaces)
{
    return ioctl (fd, BTRFS_IOC_SPACE_INFO, spaces);
}

struct btrfs_ioctl_space_args *
majoris_btrfs_query_spaces (int fd)
{
    return majoris_btrfs_read_spaces (fd, space_info_ioctl, g_try_malloc0);
}

static const char *
allocation_profile (guint64 flags)
{
    switch (flags & ~SPACE_TYPE_MASK) {
    case 0: return "single";
    case BTRFS_BLOCK_GROUP_DUP: return "DUP";
    case BTRFS_BLOCK_GROUP_RAID0: return "RAID 0";
    case BTRFS_BLOCK_GROUP_RAID1: return "RAID 1";
    case BTRFS_BLOCK_GROUP_RAID10: return "RAID 10";
    case BTRFS_BLOCK_GROUP_RAID5: return "RAID 5";
    case BTRFS_BLOCK_GROUP_RAID6: return "RAID 6";
    case BTRFS_BLOCK_GROUP_RAID1C3: return "RAID 1C3";
    case BTRFS_BLOCK_GROUP_RAID1C4: return "RAID 1C4";
    default: return "unknown profile";
    }
}

static gboolean
read_device_flag (const char *directory, const char *id, const char *name, gboolean *value)
{
    g_autofree char *path = g_build_filename (directory, id, name, NULL);
    g_autofree char *contents = NULL;
    if (!g_file_get_contents (path, &contents, NULL, NULL))
        return FALSE;
    g_strstrip (contents);
    if (!g_str_equal (contents, "0") && !g_str_equal (contents, "1"))
        return FALSE;
    *value = contents[0] == '1';
    return TRUE;
}

/* SPACE_INFO has no stripe counts, so parity overhead is unknown here. */
static gboolean
allocation_overhead (guint64 flags, guint64 bytes, guint64 *overhead)
{
    guint64 copies;
    switch (flags & ~SPACE_TYPE_MASK) {
    case 0:
    case BTRFS_BLOCK_GROUP_RAID0: copies = 1; break;
    case BTRFS_BLOCK_GROUP_DUP:
    case BTRFS_BLOCK_GROUP_RAID1:
    case BTRFS_BLOCK_GROUP_RAID10: copies = 2; break;
    case BTRFS_BLOCK_GROUP_RAID1C3: copies = 3; break;
    case BTRFS_BLOCK_GROUP_RAID1C4: copies = 4; break;
    default: return FALSE;
    }
    if (copies > 1 && bytes > G_MAXUINT64 / (copies - 1))
        return FALSE;
    *overhead = bytes * (copies - 1);
    return TRUE;
}

static gboolean
verified_device_number (const char *uuid, const struct btrfs_ioctl_dev_info_args *device, guint64 *number)
{
    struct stat block, expected, actual;
    if (memchr (device->path, 0, sizeof device->path) == NULL ||
        !g_str_has_prefix ((const char *) device->path, "/dev/") ||
        stat ((const char *) device->path, &block) != 0 || !S_ISBLK (block.st_mode))
        return FALSE;
    g_autofree char *sysblock = g_strdup_printf ("/sys/dev/block/%u:%u",
        major (block.st_rdev), minor (block.st_rdev));
    g_autofree char *canonical = realpath (sysblock, NULL);
    if (canonical == NULL)
        return FALSE;
    g_autofree char *name = g_path_get_basename (canonical);
    g_autofree char *link = g_build_filename ("/sys/fs/btrfs", uuid, "devices", name, NULL);
    if (stat (link, &actual) != 0 || stat (sysblock, &expected) != 0 ||
        actual.st_dev != expected.st_dev || actual.st_ino != expected.st_ino)
        return FALSE;
    *number = block.st_rdev;
    return TRUE;
}

GVariant *
majoris_btrfs_allocation (const char *path, const char *filesystem)
{
    struct open_how how = { .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC, .resolve = RESOLVE_NO_SYMLINKS };
    int fd = syscall (SYS_openat2, AT_FDCWD, path, &how, sizeof how);
    if (fd < 0)
        return NULL;
    GVariant *report = majoris_btrfs_allocation_fd (fd, filesystem);
    close (fd);
    return report;
}

GVariant *
majoris_btrfs_allocation_fd (int fd, const char *filesystem)
{
    struct btrfs_ioctl_fs_info_args fs = { 0 };
    struct statvfs vfs;
    g_autofree struct btrfs_ioctl_space_args *spaces = majoris_btrfs_query_spaces (fd);
    gboolean valid = ioctl (fd, BTRFS_IOC_FS_INFO, &fs) == 0 && fstatvfs (fd, &vfs) == 0 &&
        vfs.f_frsize > 0 && vfs.f_blocks <= G_MAXUINT64 / vfs.f_frsize &&
        vfs.f_bavail <= vfs.f_bfree && vfs.f_bfree <= vfs.f_blocks &&
        spaces != NULL;
    g_autofree char *uuid = format_uuid (fs.fsid);
    if (!valid || g_ascii_strcasecmp (uuid, filesystem) != 0)
        return NULL;

    GVariantBuilder allocations = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(sttt)"));
    guint64 reserve = 0, overhead = 0;
    gboolean overhead_known = TRUE;
    for (guint64 i = 0; i < spaces->total_spaces; i++) {
        struct btrfs_ioctl_space_info *row = &spaces->spaces[i];
        const guint64 types = row->flags & SPACE_TYPE_MASK;
        const char *kind;
        switch (types) {
        case BTRFS_BLOCK_GROUP_DATA: kind = "Data"; break;
        case BTRFS_BLOCK_GROUP_METADATA: kind = "Metadata"; break;
        case BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA: kind = "Data and metadata"; break;
        case BTRFS_BLOCK_GROUP_SYSTEM: kind = "System"; break;
        default:
            if (row->flags == BTRFS_SPACE_INFO_GLOBAL_RSV) {
                reserve = row->total_bytes;
                continue;
            }
            kind = "Unknown allocation";
            overhead_known = FALSE;
            break;
        }
        guint64 extra;
        if (!allocation_overhead (row->flags, row->total_bytes, &extra) ||
            extra > G_MAXUINT64 - overhead)
            overhead_known = FALSE;
        else
            overhead += extra;
        g_autofree char *label = g_strdup_printf ("%s (%s)", kind, allocation_profile (row->flags));
        g_variant_builder_add (&allocations, "(sttt)", label, row->total_bytes, row->used_bytes, row->flags);
    }

    GVariantBuilder members = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(ttttssbb)"));
    GVariantBuilder details = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(tsat)"));
    g_autofree char *devinfo = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", uuid);
    g_autoptr(GDir) devices = g_dir_open (devinfo, 0, NULL);
    const char *entry;
    while (devices != NULL && (entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (!g_ascii_string_to_unsigned (entry, 10, 0, G_MAXUINT64, &id, NULL))
            continue;
        struct btrfs_ioctl_dev_info_args device = { .devid = id };
        gboolean missing = FALSE, writable = FALSE, replacement = FALSE;
        gboolean missing_known = read_device_flag (devinfo, entry, "missing", &missing);
        gboolean writable_known = read_device_flag (devinfo, entry, "writeable", &writable);
        read_device_flag (devinfo, entry, "replace_target", &replacement);
        guint64 number = 0;
        gboolean known = id != 0 && ioctl (fd, BTRFS_IOC_DEV_INFO, &device) == 0 &&
            device.devid == id && device.total_bytes > 0 && device.bytes_used <= device.total_bytes;
        gboolean present = missing_known && !missing && known && verified_device_number (uuid, &device, &number);
        g_autofree char *member_uuid = known ? format_uuid (device.uuid) : g_strdup ("");
        const char *state = replacement ? "Replacement target" : missing ? "Missing" :
            !present ? "Unavailable" : !writable_known ? "Present, write state unknown" :
            writable ? "Present" : "Read-only";
        struct btrfs_ioctl_get_dev_stats stats = { .devid = id, .nr_items = BTRFS_DEV_STAT_VALUES_MAX };
        gboolean has_errors = FALSE;
        GVariantBuilder counters = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("at"));
        if (present && ioctl (fd, BTRFS_IOC_GET_DEV_STATS, &stats) == 0 &&
            stats.nr_items == BTRFS_DEV_STAT_VALUES_MAX) {
            for (guint i = 0; i < BTRFS_DEV_STAT_VALUES_MAX; i++) {
                has_errors |= stats.values[i] != 0;
                g_variant_builder_add (&counters, "t", (guint64) stats.values[i]);
            }
        }
        g_variant_builder_add (&members, "(ttttssbb)", id, number,
            known ? (guint64) device.total_bytes : 0, known ? (guint64) device.bytes_used : 0,
            member_uuid, state, known, has_errors);
        const char *path = (const char *) device.path;
        g_variant_builder_add (&details, "(ts@at)", id, present && g_utf8_validate (path, -1, NULL) ? path : "",
            g_variant_builder_end (&counters));
    }
    g_autofree char *operation_path = g_build_filename ("/sys/fs/btrfs", uuid, "exclusive_operation", NULL);
    g_autofree char *operation = NULL;
    if (!g_file_get_contents (operation_path, &operation, NULL, NULL))
        operation = g_strdup ("unknown");
    return g_variant_ref_sink (g_variant_new ("(tt@a(sttt)@a(ttttssbb)tttbstb@a(tsat))",
        (guint64) vfs.f_blocks * vfs.f_frsize, (guint64) fs.num_devices,
        g_variant_builder_end (&allocations), g_variant_builder_end (&members),
        (guint64) (vfs.f_blocks - vfs.f_bfree) * vfs.f_frsize,
        (guint64) vfs.f_bavail * vfs.f_frsize, reserve, (vfs.f_flag & ST_RDONLY) != 0,
        g_strstrip (operation), overhead, overhead_known, g_variant_builder_end (&details)));
}
