#include "storage-sanitization.h"

#include <linux/loop.h>
#include <sys/ioctl.h>

gboolean
majoris_overwrite_loop_matches (int fd, guint64 backing_device, guint64 backing_inode)
{
    struct loop_info64 info = { 0 };

    return ioctl (fd, LOOP_GET_STATUS64, &info) == 0 &&
        info.lo_device == backing_device && info.lo_inode == backing_inode &&
        info.lo_offset == 0 && info.lo_sizelimit == 0;
}
