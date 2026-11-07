/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nbd-identity.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

char *
majoris_nbd_identity (guint index, guint *client_pid)
{
    g_autofree char *path = g_strdup_printf ("/sys/block/nbd%u/pid", index);
    struct stat opened, current;
    char buffer[32];
    int fd = open (path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return NULL;
    ssize_t length = read (fd, buffer, sizeof buffer - 1);
    gboolean stable = fstat (fd, &opened) == 0 && stat (path, &current) == 0 &&
                      opened.st_ino == current.st_ino && opened.st_dev == current.st_dev;
    close (fd);
    if (!stable || length <= 0)
        return NULL;
    buffer[length] = '\0';
    guint64 pid;
    if (!g_ascii_string_to_unsigned (g_strstrip (buffer), 10, 1, G_MAXUINT, &pid, NULL))
        return NULL;
    if (client_pid != NULL)
        *client_pid = (guint) pid;
    return g_strdup_printf ("%u:%" G_GUINT64_FORMAT ":%" G_GINT64_FORMAT ":%ld",
        (guint) pid, (guint64) opened.st_ino, (gint64) opened.st_ctim.tv_sec, opened.st_ctim.tv_nsec);
}

char *
majoris_nbd_token (guint index, guint uid)
{
    struct stat info;
    if (lstat (MAJORIS_NBD_STATE, &info) != 0 || !S_ISDIR (info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 0022) != 0)
        return NULL;
    g_autofree char *path = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", index);
    if (lstat (path, &info) != 0 || !S_ISREG (info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 0022) != 0)
        return NULL;
    g_autoptr(GKeyFile) record = g_key_file_new ();
    if (!g_key_file_load_from_file (record, path, G_KEY_FILE_NONE, NULL))
        return NULL;
    g_autoptr(GError) error = NULL;
    if (g_key_file_get_uint64 (record, "attachment", "uid", &error) != uid || error != NULL)
        return NULL;
    g_autofree char *token = g_key_file_get_string (record, "attachment", "token", NULL);
    g_autofree char *saved = g_key_file_get_string (record, "attachment", "identity", NULL);
    g_autofree char *live = majoris_nbd_identity (index, NULL);
    if (token == NULL || !g_uuid_string_is_valid (token) || live == NULL || g_strcmp0 (saved, live) != 0)
        return NULL;
    return g_steal_pointer (&token);
}
