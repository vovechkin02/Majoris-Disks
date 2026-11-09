/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
valid_name (const char *name)
{
    return name[0] != '\0' && name[0] != '-' && strlen (name) <= 127 &&
           strcmp (name, ".") != 0 && strcmp (name, "..") != 0 &&
           strspn (name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+_.-") == strlen (name);
}

int
main (int argc, char **argv)
{
    if (geteuid () != 0 || argc != 2 || !valid_name (argv[1]))
        return 2;

    /* lvs is a report command. Its --readonly mode skips device-mapper
     * status, which is needed to distinguish dirty caches from clean ones. */
    char *const command[] = {
        "/usr/sbin/lvs", "--all", "--reportformat", "json", "--units", "b", "--nosuffix",
        "--options", "vg_uuid,lv_uuid,lv_name,segtype,pool_lv,pool_lv_uuid,cache_mode,cache_dirty_blocks,"
                     "cache_total_blocks,lv_attr,lv_health_status,lv_check_needed",
        "--", argv[1], NULL
    };
    char *const environment[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", NULL };
    execve (command[0], command, environment);
    perror ("lvs");
    return 1;
}
