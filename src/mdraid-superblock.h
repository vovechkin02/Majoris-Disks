#pragma once

#include <glib.h>

GVariant *majoris_mdraid_read_superblock (int fd);

typedef enum {
    MAJORIS_MDRAID_READD_INCOMPATIBLE,
    MAJORIS_MDRAID_READD_UNVERIFIED_BITMAP,
    MAJORIS_MDRAID_READD_STALE,
    MAJORIS_MDRAID_READD_CURRENT,
    MAJORIS_MDRAID_READD_BITMAP
} MajorisMdRaidReadd;

MajorisMdRaidReadd majoris_mdraid_review_readd (GVariant *former, int survivor_fd,
                                               const char *md, char **token);
