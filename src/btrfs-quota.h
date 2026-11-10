/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <glib.h>

#define MAJORIS_QUOTA_REPORT "(sttbsa(ttttttb)a(tt)b)"

typedef enum {
    QUOTA_READ, QUOTA_ENABLE, QUOTA_ENABLE_SIMPLE, QUOTA_DISABLE, QUOTA_RESCAN,
    QGROUP_CREATE, QGROUP_DELETE, QGROUP_ASSIGN, QGROUP_UNASSIGN,
    QGROUP_REFERENCED, QGROUP_EXCLUSIVE
} MajorisQuotaAction;

GVariant *majoris_btrfs_quota_read (int fd, const char *uuid, GError **error);
GVariant *majoris_btrfs_quota_read_with_ioctl (int fd, const char *uuid,
    int (*request) (int, unsigned long, void *), GError **error);
gboolean majoris_btrfs_quota_id (const char *text, guint64 *id);
gboolean majoris_btrfs_quota_apply (int fd, MajorisQuotaAction action, GVariant *before,
                                   guint64 id, guint64 value, GError **error);
gboolean majoris_btrfs_quota_verified (MajorisQuotaAction action, GVariant *before,
                                      GVariant *after, guint64 id, guint64 value);
