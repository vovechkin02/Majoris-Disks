#pragma once

#include <gio/gio.h>

guint majoris_register_mock_open_device (GDBusConnection *connection, const char *path,
                                        GDBusInterfaceInfo *info, GError **error);
