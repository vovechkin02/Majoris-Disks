#pragma once

#include <glib.h>

gboolean majoris_overwrite_loop_matches (int fd, guint64 backing_device, guint64 backing_inode);
