/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once

#include <glib.h>

#define MAJORIS_NBD_STATE "/run/majoris-disks-nbd"
#define MAJORIS_NBD_CLIENT "/usr/sbin/nbd-client"

char *majoris_nbd_identity (guint index, guint *client_pid);
char *majoris_nbd_token (guint index, guint uid);
