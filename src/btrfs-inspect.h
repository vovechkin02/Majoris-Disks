/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <glib.h>

char *majoris_btrfs_inspect_subvolume (const char *path, guint64 id, const char *filesystem,
                                      const char *origin, gboolean *read_only);
int majoris_btrfs_mount_use (const char *filesystem, guint64 id, const char *path);
GVariant *majoris_btrfs_allocation (const char *path, const char *filesystem);
