/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "btrfs-inspect.h"
#include <fcntl.h>
#include <linux/btrfs.h>
#include <linux/openat2.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
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
        ioctl (fd, BTRFS_IOC_GET_SUBVOL_INFO, &subvol) == 0 && subvol.treeid == id &&
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
