/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <dlfcn.h>
#include <errno.h>
#include <glib.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Loaded only into the disposable test's direct helper process. */
int
ioctl (int fd, unsigned long request, ...)
{
    va_list args;
    va_start (args, request);
    void *argument = va_arg (args, void *);
    va_end (args);
    static gboolean quota_changed;
    const char *quota_fault = getenv ("MAJORIS_TEST_BTRFS_QUOTA_FAULT");
    if (quota_fault && request == BTRFS_IOC_TREE_SEARCH_V2) {
        if (strcmp (quota_fault, "helper-exit") == 0) _exit (42);
        if (strcmp (quota_fault, "status-timeout") == 0) sleep (30);
        if (quota_changed || strcmp (quota_fault, "status-unavailable") == 0) {
            errno = EIO;
            return -1;
        }
    }
    if (quota_fault && request == BTRFS_IOC_QUOTA_RESCAN && strcmp (quota_fault, "rescan-failure") == 0) {
        errno = EIO;
        return -1;
    }
    if (quota_fault && request == BTRFS_IOC_QGROUP_LIMIT && strcmp (quota_fault, "false-limit-success") == 0)
        return 0;
    const char *fault = getenv ("MAJORIS_TEST_BTRFS_BALANCE_FAULT");
    if (request == BTRFS_IOC_SCRUB_PROGRESS && fault && strcmp (fault, "active-scrub") == 0)
        return 0;
    if (request == BTRFS_IOC_SCRUB_PROGRESS && fault && strcmp (fault, "scrub-status-unavailable") == 0) {
        errno = EIO;
        return -1;
    }
    if (request == BTRFS_IOC_SPACE_INFO && fault && strcmp (fault, "allocation-failure") == 0) {
        errno = EIO;
        return -1;
    }
    if (request == BTRFS_IOC_BALANCE_V2 && fault) {
        struct btrfs_ioctl_balance_args *balance = argument;
        if (strcmp (fault, "enospc") == 0) {
            errno = ENOSPC;
            return -1;
        }
        if (strcmp (fault, "force") == 0) {
            errno = balance->flags & BTRFS_BALANCE_FORCE ? EINVAL : EPROTO;
            return -1;
        }
        if (strcmp (fault, "false-complete") == 0)
            return 0;
        if (strcmp (fault, "timeout") == 0) {
            sleep (30);
            errno = EINTR;
            return -1;
        }
    }
    int (*real_ioctl) (int, unsigned long, ...) = dlsym (RTLD_NEXT, "ioctl");
    if (!real_ioctl) {
        errno = ENOSYS;
        return -1;
    }
    int rc = real_ioctl (fd, request, argument);
    if (rc >= 0 && quota_fault && request == BTRFS_IOC_QGROUP_LIMIT &&
        strcmp (quota_fault, "limit-readback-failure") == 0)
        quota_changed = TRUE;
    if (rc == 0 && fault && request == BTRFS_IOC_GET_DEV_STATS && strcmp (fault, "device-errors") == 0) {
        struct btrfs_ioctl_get_dev_stats *stats = argument;
        stats->values[BTRFS_DEV_STAT_WRITE_ERRS] = 1;
    }
    if (rc == 0 && fault && request == BTRFS_IOC_SPACE_INFO && strcmp (fault, "unknown-profile") == 0) {
        struct btrfs_ioctl_space_args *spaces = argument;
        for (unsigned int i = 0; i < spaces->space_slots && i < spaces->total_spaces; i++)
            if (spaces->spaces[i].flags & BTRFS_BLOCK_GROUP_DATA)
                spaces->spaces[i].flags |= 1ULL << 40;
    }
    return rc;
}

gboolean
g_file_get_contents (const gchar *name, gchar **contents, gsize *length, GError **error)
{
    const char *fault = getenv ("MAJORIS_TEST_BTRFS_BALANCE_FAULT");
    if (fault && g_str_has_suffix (name, "/exclusive_operation") &&
        (strcmp (fault, "active-replacement") == 0 || strcmp (fault, "active-balance") == 0 ||
         strcmp (fault, "unknown-exclusive") == 0)) {
        *contents = g_strdup (strcmp (fault, "active-replacement") == 0 ? "device replace\n" :
            strcmp (fault, "active-balance") == 0 ? "balance\n" : "future operation\n");
        if (length) *length = strlen (*contents);
        return TRUE;
    }
    gboolean (*real_read) (const gchar *, gchar **, gsize *, GError **) = dlsym (RTLD_NEXT, "g_file_get_contents");
    return real_read (name, contents, length, error);
}
