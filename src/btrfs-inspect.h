/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <glib.h>
#include <linux/btrfs.h>

struct btrfs_ioctl_space_args *majoris_btrfs_query_spaces (int fd);
struct btrfs_ioctl_space_args *majoris_btrfs_read_spaces (
    int fd, int (*query) (int, struct btrfs_ioctl_space_args *), gpointer (*allocate) (gsize));

char *majoris_btrfs_inspect_subvolume (const char *path, guint64 id, const char *filesystem,
                                      const char *origin, gboolean *read_only);
int majoris_btrfs_mount_use (const char *filesystem, guint64 id, const char *path);
GVariant *majoris_btrfs_allocation (const char *path, const char *filesystem);
GVariant *majoris_btrfs_allocation_fd (int fd, const char *filesystem);
