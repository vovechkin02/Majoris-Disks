/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Loaded only into the opt-in disposable-device test worker. */
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int wrote;

static int fault(const char *name)
{
    const char *requested = getenv("MAJORIS_LUKS_TEST_FAULT");
    return requested && !strcmp(requested, name);
}

ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset)
{
    ssize_t (*real_write)(int, const void *, size_t, off_t) = dlsym(RTLD_NEXT, "pwrite");
    if (fd == 3) {
        wrote = 1;
        if (fault("short-write"))
            return real_write(fd, buffer, count / 2, offset);
        if (fault("interrupted-write")) {
            real_write(fd, buffer, count / 2, offset);
            raise(SIGKILL);
        }
    }
    return real_write(fd, buffer, count, offset);
}

ssize_t pread(int fd, void *buffer, size_t count, off_t offset)
{
    ssize_t (*real_read)(int, void *, size_t, off_t) = dlsym(RTLD_NEXT, "pread");
    ssize_t bytes = real_read(fd, buffer, count, offset);
    if (fd == 3 && wrote && bytes > 0 && fault("readback"))
        ((unsigned char *) buffer)[0] ^= 1;
    return bytes;
}

int fsync(int fd)
{
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
    if (fd == 3 && wrote && fault("fsync")) {
        errno = EIO;
        return -1;
    }
    return real_sync(fd);
}
