// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <gio/gio.h>

#define UDISKS "org.freedesktop.UDisks2"
#define DRIVE UDISKS ".Drive"
#define ATA DRIVE ".Ata"
#define NVME UDISKS ".NVMe.Controller"
#define BLOCK UDISKS ".Block"
#define PARTITION UDISKS ".Partition"
#define NAMESPACE UDISKS ".NVMe.Namespace"

typedef enum {
    ATA_NORMAL, ATA_ENHANCED, NVME_BLOCK, NVME_CRYPTO, NVME_OVERWRITE, METHOD_COUNT
} SanitizeMethod;

typedef struct {
    char *owner;
    char *key;
    char *identity;
    char *description;
    char *status;
    int remaining;
    guint32 command;
    gboolean unsupported;
    gboolean unknown;
    gboolean job_running;
} SanitizeScope;

void sanitize_scope_clear(SanitizeScope *scope);
gboolean sanitize_inspect(GDBusConnection *bus, const char *drive, SanitizeMethod method,
                          gboolean check_use, SanitizeScope *scope, GError **error);
