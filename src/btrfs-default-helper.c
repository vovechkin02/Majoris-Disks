/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <dlfcn.h>
#include "btrfs-inspect.h"
#include <fcntl.h>
#include <glib.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <errno.h>
#include <linux/openat2.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

typedef int (*GetDefault) (int, guint64 *);
typedef int (*SetDefault) (int, guint64);
typedef int (*SubvolumePath) (int, guint64, char **);

static void
close_fd (int *fd)
{
    if (*fd >= 0)
        close (*fd);
}

static int
open_directory (const char *path)
{
    struct open_how how = { .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_NO_SYMLINKS };
    return syscall (SYS_openat2, AT_FDCWD, path, &how, sizeof how);
}

static gboolean
matches_uuid (int fd, const char *uuid)
{
    struct btrfs_ioctl_fs_info_args info = { 0 };
    if (ioctl (fd, BTRFS_IOC_FS_INFO, &info) != 0)
        return FALSE;
    const guint8 *u = info.fsid;
    g_autofree char *actual = g_strdup_printf (
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9],
        u[10], u[11], u[12], u[13], u[14], u[15]);
    return g_ascii_strcasecmp (actual, uuid) == 0;
}

static gboolean
filesystem_member (const char *uuid, dev_t device)
{
    g_autofree char *canonical_uuid = g_ascii_strdown (uuid, -1);
    g_autofree char *members = g_strdup_printf ("/sys/fs/btrfs/%s/devices", canonical_uuid);
    g_autofree char *block = g_strdup_printf ("/sys/dev/block/%u:%u", major (device), minor (device));
    struct stat expected;
    if (stat (block, &expected) != 0)
        return FALSE;
    g_autoptr(GDir) directory = g_dir_open (members, 0, NULL);
    if (directory == NULL)
        return FALSE;
    const char *entry;
    while ((entry = g_dir_read_name (directory)) != NULL) {
        g_autofree char *candidate = g_build_filename (members, entry, NULL);
        struct stat actual;
        if (stat (candidate, &actual) == 0 &&
            actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino)
            return TRUE;
    }
    return FALSE;
}

static gboolean
matches_mount (int fd, const char *path, guint64 device, const char *uuid, dev_t *source_device)
{
    struct statx opened;
    g_autofree char *mountinfo = NULL;
    if (statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID, &opened) != 0 ||
        !(opened.stx_mask & STATX_MNT_ID) ||
        !g_file_get_contents ("/proc/self/mountinfo", &mountinfo, NULL, NULL))
        return FALSE;

    g_auto(GStrv) lines = g_strsplit (mountinfo, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        g_auto(GStrv) parts = g_strsplit (lines[i], " - ", 2);
        if (parts[1] == NULL)
            continue;
        g_auto(GStrv) mount = g_strsplit (parts[0], " ", 6);
        g_auto(GStrv) source = g_strsplit (parts[1], " ", 3);
        if (g_strv_length (mount) < 6 || g_strv_length (source) < 3 ||
            g_ascii_strtoull (mount[0], NULL, 10) != opened.stx_mnt_id ||
            !g_str_equal (source[0], "btrfs"))
            continue;
        g_autofree char *actual_path = g_strcompress (mount[4]);
        g_autofree char *node = g_strcompress (source[1]);
        struct stat info;
        gboolean valid = g_str_equal (actual_path, path) && g_str_has_prefix (node, "/dev/") &&
            stat (node, &info) == 0 && S_ISBLK (info.st_mode) &&
            ((guint64) info.st_rdev == device ||
             (filesystem_member (uuid, info.st_rdev) && filesystem_member (uuid, (dev_t) device)));
        if (valid && source_device != NULL) *source_device = info.st_rdev;
        return valid;
    }
    return FALSE;
}

static gboolean
system_filesystem (const char *uuid)
{
    const char *critical[] = { "/", "/boot", "/boot/efi", "/usr", "/var", "/etc", "/efi" };
    for (guint i = 0; i < G_N_ELEMENTS (critical); i++) {
        int fd __attribute__((cleanup(close_fd))) = open (critical[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd >= 0 && matches_uuid (fd, uuid))
            return TRUE;
    }
    return FALSE;
}

static int
fail (const char *message)
{
    g_printerr ("%s\n", message);
    return 1;
}

static int
check_removable_member (int mount, const char *filesystem, dev_t target, guint64 expected, gboolean allow_allocated)
{
    struct btrfs_ioctl_fs_info_args info = { 0 };
    struct statvfs state;
    if (expected < 2 || ioctl (mount, BTRFS_IOC_FS_INFO, &info) != 0 || info.num_devices != expected ||
        fstatvfs (mount, &state) != 0 || (state.f_flag & ST_RDONLY) || system_filesystem (filesystem))
        return fail ("The Btrfs filesystem is protected, read-only, or its membership changed.");
    g_autofree char *uuid = g_ascii_strdown (filesystem, -1);
    g_autofree char *operation_file = g_strdup_printf ("/sys/fs/btrfs/%s/exclusive_operation", uuid);
    g_autofree char *operation = NULL;
    if (!g_file_get_contents (operation_file, &operation, NULL, NULL) || !g_str_equal (g_strstrip (operation), "none"))
        return fail ("Another exclusive Btrfs operation is active or its state is unknown.");

    const guint slots = 64;
    g_autofree struct btrfs_ioctl_space_args *spaces =
        g_malloc0 (sizeof *spaces + slots * sizeof (struct btrfs_ioctl_space_info));
    spaces->space_slots = slots;
    if (ioctl (mount, BTRFS_IOC_SPACE_INFO, spaces) != 0 || spaces->total_spaces == 0 || spaces->total_spaces >= slots)
        return fail ("Could not verify Btrfs allocation profiles.");
    for (guint64 i = 0; i < spaces->total_spaces; i++) {
        guint64 profile = spaces->spaces[i].flags & BTRFS_BLOCK_GROUP_PROFILE_MASK;
        if (profile != 0 && profile != BTRFS_BLOCK_GROUP_DUP)
            return fail ("Only single and DUP allocation profiles are supported for this member-removal workflow.");
    }

    g_autofree char *devinfo = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", uuid);
    g_autoptr(GDir) devices = g_dir_open (devinfo, 0, NULL);
    if (devices == NULL)
        return fail ("Could not verify the kernel Btrfs member list.");
    const char *entry;
    guint64 count = 0, allocated = 0, largest_destination = 0;
    gboolean found = FALSE;
    while ((entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (!g_ascii_string_to_unsigned (entry, 10, 1, G_MAXUINT64, &id, NULL))
            return fail ("The kernel Btrfs member list is invalid.");
        struct btrfs_ioctl_dev_info_args device = { .devid = id };
        struct stat block;
        if (ioctl (mount, BTRFS_IOC_DEV_INFO, &device) != 0 ||
            memchr (device.path, 0, sizeof device.path) == NULL ||
            stat ((const char *) device.path, &block) != 0 || !S_ISBLK (block.st_mode) ||
            !filesystem_member (uuid, block.st_rdev) || device.bytes_used > device.total_bytes)
            return fail ("A Btrfs member is missing or changed.");
        struct btrfs_ioctl_scrub_args scrub = { .devid = id };
        if (ioctl (mount, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
            return fail ("A Btrfs scrub is active or its state is unknown.");
        count++;
        if (block.st_rdev == target) {
            if (found)
                return fail ("The Btrfs device list contains a duplicate removal target.");
            allocated = device.bytes_used;
            found = TRUE;
        } else {
            largest_destination = MAX (largest_destination, device.total_bytes - device.bytes_used);
        }
    }
    if (!found || count != expected)
        return fail ("Could not verify all Btrfs members and the removal target.");
    if (allocated == 0)
        return 0;
    if (!allow_allocated)
        return fail ("The selected member still holds allocated Btrfs chunks.");
    // Single and DUP chunks can be placed on one device. Require space for the full
    // physical allocation plus headroom on one surviving member. The kernel still
    // decides whether the actual free extents can accommodate every chunk.
    const guint64 reserve = 256 * G_GUINT64_CONSTANT (1024) * 1024;
    if (largest_destination < reserve || allocated > largest_destination - reserve)
        return fail ("No surviving Btrfs member has sufficient relocation capacity and headroom.");
    return 0;
}

static gboolean
verify_maintenance_topology (int fd, const char *uuid, guint64 expected, gboolean reject_scrub)
{
    struct btrfs_ioctl_fs_info_args fs = { 0 };
    if (expected == 0 || ioctl (fd, BTRFS_IOC_FS_INFO, &fs) != 0 || fs.num_devices != expected)
        return FALSE;
    g_autofree char *canonical = g_ascii_strdown (uuid, -1);
    g_autofree char *directory = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", canonical);
    g_autoptr(GDir) devices = g_dir_open (directory, 0, NULL);
    if (devices == NULL) return FALSE;
    guint64 count = 0;
    const char *entry;
    while ((entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (!g_ascii_string_to_unsigned (entry, 10, 1, G_MAXUINT64, &id, NULL)) return FALSE;
        struct btrfs_ioctl_dev_info_args device = { .devid = id };
        struct stat info;
        if (ioctl (fd, BTRFS_IOC_DEV_INFO, &device) != 0 ||
            memchr (device.path, 0, sizeof device.path) == NULL ||
            stat ((const char *) device.path, &info) != 0 || !S_ISBLK (info.st_mode) ||
            !filesystem_member (canonical, info.st_rdev))
            return FALSE;
        if (reject_scrub) {
            struct btrfs_ioctl_scrub_args scrub = { .devid = id };
            if (ioctl (fd, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
                return FALSE;
        }
        count++;
    }
    return count == expected;
}

static int
balance_status (int fd)
{
    struct btrfs_ioctl_balance_args balance = { 0 };
    if (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &balance) != 0) {
        if (errno != ENOTCONN) return fail ("Could not query Btrfs balance status.");
        g_print ("idle 0 0 0\n");
        return 0;
    }
    const char *state = balance.state & BTRFS_BALANCE_STATE_RUNNING ? "running" : "paused";
    g_print ("%s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT "\n", state,
        (guint64) balance.stat.completed, (guint64) balance.stat.considered, (guint64) balance.stat.expected);
    return 0;
}

static int
run_balance (int fd, const char *uuid, const char *operation, guint64 usage)
{
    if (g_str_equal (operation, "balance-status")) return balance_status (fd);
    struct statvfs state;
    if (system_filesystem (uuid) || fstatvfs (fd, &state) != 0 || (state.f_flag & ST_RDONLY))
        return fail ("The filesystem is protected or read-only.");
    if (g_str_equal (operation, "balance-pause") || g_str_equal (operation, "balance-cancel")) {
        int command = g_str_equal (operation, "balance-pause") ? BTRFS_BALANCE_CTL_PAUSE : BTRFS_BALANCE_CTL_CANCEL;
        if (ioctl (fd, BTRFS_IOC_BALANCE_CTL, (unsigned long) command) != 0)
            return fail ("The kernel did not accept the balance control request.");
        return balance_status (fd);
    }

    struct btrfs_ioctl_balance_args balance = { 0 };
    if (g_str_equal (operation, "balance-resume")) {
        balance.flags = BTRFS_BALANCE_RESUME;
    } else if (g_str_equal (operation, "balance-data")) {
        balance.flags = BTRFS_BALANCE_DATA;
        balance.data.flags = BTRFS_BALANCE_ARGS_USAGE;
        balance.data.usage = usage;
    } else if (g_str_equal (operation, "balance-metadata")) {
        balance.flags = BTRFS_BALANCE_METADATA;
        balance.meta.flags = BTRFS_BALANCE_ARGS_USAGE;
        balance.meta.usage = usage;
    } else {
        return fail ("Unsupported balance operation.");
    }
    if (ioctl (fd, BTRFS_IOC_BALANCE_V2, &balance) != 0) {
        if (errno == ECANCELED) {
            struct btrfs_ioctl_balance_args paused = { 0 };
            if (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &paused) == 0) return balance_status (fd);
            if (errno == ENOTCONN) {
                g_print ("interrupted 0 0 0\n");
                return 0;
            }
        }
        return fail ("The kernel did not complete the Btrfs balance.");
    }
    g_print ("completed %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT "\n",
        (guint64) balance.stat.completed, (guint64) balance.stat.considered, (guint64) balance.stat.expected);
    return 0;
}

typedef struct {
    int fd;
    int error;
    struct btrfs_ioctl_scrub_args args;
} ScrubWork;

static gpointer
read_only_scrub (gpointer data)
{
    ScrubWork *work = data;
    if (ioctl (work->fd, BTRFS_IOC_SCRUB, &work->args) != 0)
        work->error = errno;
    return NULL;
}

static int
run_scrub (int fd, const char *uuid, const char *operation, guint64 expected)
{
    if (g_str_equal (operation, "scrub-cancel")) {
        if (system_filesystem (uuid) || ioctl (fd, BTRFS_IOC_SCRUB_CANCEL) != 0)
            return fail ("The kernel did not accept the scrub cancellation.");
        g_print ("interrupted 0 0 0\n");
        return 0;
    }
    gboolean query = g_str_equal (operation, "scrub-status");
    if (!query && (!g_str_equal (operation, "scrub-readonly") || system_filesystem (uuid)))
        return fail ("Scrub is unavailable for this request or protected filesystem.");
    g_autofree char *canonical = g_ascii_strdown (uuid, -1);
    if (!query) {
        g_autofree char *exclusive_path = g_strdup_printf ("/sys/fs/btrfs/%s/exclusive_operation", canonical);
        g_autofree char *exclusive = NULL;
        if (!g_file_get_contents (exclusive_path, &exclusive, NULL, NULL) ||
            !g_str_equal (g_strstrip (exclusive), "none"))
            return fail ("A conflicting exclusive Btrfs operation is active or unknown.");
    }
    g_autofree char *path = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", canonical);
    g_autoptr(GDir) devices = g_dir_open (path, 0, NULL);
    if (devices == NULL || expected > 64)
        return fail ("Could not verify the scrub device set.");
    ScrubWork work[64] = { 0 };
    GThread *workers[64] = { 0 };
    guint count = 0;
    const char *entry;
    while ((entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (count == expected || !g_ascii_string_to_unsigned (entry, 10, 1, G_MAXUINT64, &id, NULL))
            return fail ("The scrub device set changed.");
        work[count].fd = fd;
        work[count].args.devid = id;
        work[count].args.end = G_MAXUINT64;
        work[count].args.flags = BTRFS_SCRUB_READONLY;
        count++;
    }
    if (count != expected)
        return fail ("The scrub device count changed.");
    gboolean running = FALSE;
    for (guint i = 0; i < count; i++) {
        if (ioctl (fd, BTRFS_IOC_SCRUB_PROGRESS, &work[i].args) == 0)
            running = TRUE;
        else if (errno != ENOTCONN)
            return fail ("Could not verify the current scrub state.");
    }
    if (running && !query)
        return fail ("A Btrfs scrub is already running.");
    if (!query)
        for (guint i = 0; i < count; i++)
            workers[i] = g_thread_new ("btrfs-scrub", read_only_scrub, &work[i]);

    guint64 read_errors = 0, checksums = 0, uncorrectable = 0;
    gboolean interrupted = FALSE, failed = FALSE;
    for (guint i = 0; i < count; i++) {
        if (!query) g_thread_join (workers[i]);
        struct btrfs_scrub_progress *p = &work[i].args.progress;
        read_errors += MIN (G_MAXUINT64 - read_errors, p->read_errors);
        checksums += MIN (G_MAXUINT64 - checksums, p->csum_errors);
        uncorrectable += MIN (G_MAXUINT64 - uncorrectable, p->uncorrectable_errors);
        interrupted |= work[i].error == ECANCELED;
        failed |= work[i].error != 0 && work[i].error != ECANCELED;
    }
    if (failed) return fail ("At least one Btrfs member scrub could not complete.");
    g_print ("%s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT "\n",
        query ? (running ? "running" : "idle") : interrupted ? "interrupted" : "completed",
        read_errors, checksums, uncorrectable);
    return 0;
}

int
main (int argc, char **argv)
{
    gboolean set = argc == 7 && g_str_equal (argv[1], "set-default");
    gboolean check = argc == 7 && g_str_equal (argv[1], "check-unmounted");
    gboolean allow_allocated = argc == 7 && g_str_equal (argv[1], "check-removable-member");
    gboolean check_member = allow_allocated || (argc == 7 && g_str_equal (argv[1], "check-empty-member"));
    gboolean balance = (argc == 6 || argc == 7) && g_str_has_prefix (argv[1], "balance-");
    gboolean scrub = argc == 6 && g_str_has_prefix (argv[1], "scrub-");
    guint64 device, expected = 0, target = 0, current;
    if (geteuid () != 0 || (!set && !check && !check_member && !balance && !scrub && (argc != 5 || !g_str_equal (argv[1], "get-default"))) ||
        !g_path_is_absolute (argv[2]) || !g_uuid_string_is_valid (argv[3]) ||
        !g_ascii_string_to_unsigned (argv[4], 10, 1, G_MAXUINT64, &device, NULL) ||
        (set && (!g_ascii_string_to_unsigned (argv[5], 10, 5, G_MAXUINT64, &expected, NULL) ||
                 !g_ascii_string_to_unsigned (argv[6], 10, 5, G_MAXUINT64, &target, NULL))))
        return fail ("Invalid Btrfs default-subvolume request.");

    int mount __attribute__((cleanup(close_fd))) = open_directory (argv[2]);
    dev_t mount_source = 0;
    if (mount < 0 || !matches_mount (mount, argv[2], device, argv[3], &mount_source) || !matches_uuid (mount, argv[3]))
        return fail ("The Btrfs mount or its source identity changed.");

    if (scrub) {
        guint64 count;
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, 64, &count, NULL) ||
            !verify_maintenance_topology (mount, argv[3], count, FALSE))
            return fail ("Could not verify the Btrfs scrub member topology.");
        return run_scrub (mount, argv[3], argv[1], count);
    }
    if (balance) {
        guint64 count, usage = 0;
        gboolean filtered = g_str_equal (argv[1], "balance-data") || g_str_equal (argv[1], "balance-metadata");
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &count, NULL) ||
            (filtered ? argc != 7 || !g_ascii_string_to_unsigned (argv[6], 10, 0, 100, &usage, NULL) : argc != 6) ||
            !verify_maintenance_topology (mount, argv[3], count, filtered || g_str_equal (argv[1], "balance-resume")))
            return fail ("Could not verify the Btrfs maintenance request, member topology or scrub state.");
        return run_balance (mount, argv[3], argv[1], usage);
    }

    if (check_member) {
        guint64 member, count;
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &member, NULL) || member == device || member == (guint64) mount_source ||
            !g_ascii_string_to_unsigned (argv[6], 10, 2, G_MAXUINT64, &count, NULL))
            return fail ("Invalid Btrfs removal candidate.");
        return check_removable_member (mount, argv[3], (dev_t) member, count, allow_allocated);
    }
    if (check) {
        if (!g_ascii_string_to_unsigned (argv[5], 10, 256, G_MAXUINT64, &target, NULL) ||
            argv[6][0] == 0 || strchr (argv[6], 47) != NULL ||
            g_str_equal (argv[6], ".") || g_str_equal (argv[6], ".."))
            return fail ("Invalid Btrfs subvolume identity.");
        g_autofree char *path = g_build_filename (argv[2], argv[6], NULL);
        gboolean read_only;
        g_autofree char *identity = majoris_btrfs_inspect_subvolume (path, target, argv[3], NULL, &read_only);
        if (identity == NULL)
            return fail ("The selected Btrfs subvolume changed.");
        int status = majoris_btrfs_mount_use (argv[3], target, argv[6]);
        if (status == 1)
            return fail ("The selected Btrfs subvolume is mounted.");
        if (status != 0)
            return fail ("Could not verify the selected subvolume across visible mount namespaces.");
        return 0;
    }

    void *library = dlopen ("libbtrfsutil.so.1", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL)
        return fail ("Install libbtrfsutil1 to manage the default Btrfs subvolume.");
    GetDefault get_default = (GetDefault) dlsym (library, "btrfs_util_get_default_subvolume_fd");
    SetDefault set_default = (SetDefault) dlsym (library, "btrfs_util_set_default_subvolume_fd");
    SubvolumePath subvolume_path = (SubvolumePath) dlsym (library, "btrfs_util_subvolume_path_fd");
    if (get_default == NULL || set_default == NULL || subvolume_path == NULL)
        return fail ("The installed libbtrfsutil lacks the required default-subvolume API.");

    if (set) {
        g_autofree char *uuid = g_ascii_strdown (argv[3], -1);
        g_autofree char *lock_name = g_strdup_printf ("/run/majoris-btrfs-%s.lock", uuid);
        int lock __attribute__((cleanup(close_fd))) = open (lock_name,
            O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct statvfs state;
        if (lock < 0 || flock (lock, LOCK_EX | LOCK_NB) != 0 ||
            system_filesystem (uuid) || fstatvfs (mount, &state) != 0 || (state.f_flag & ST_RDONLY))
            return fail ("The Btrfs filesystem is protected, read-only, or already being modified.");
        if (get_default (mount, &current) != 0 || current != expected)
            return fail ("The default Btrfs subvolume changed after confirmation.");
        g_autofree char *path = NULL;
        if (target != 5 && subvolume_path (mount, target, &path) != 0)
            return fail ("The requested Btrfs subvolume no longer exists.");
        if (!matches_mount (mount, argv[2], device, argv[3], NULL) || !matches_uuid (mount, uuid))
            return fail ("The Btrfs mount or source identity changed before writing.");
        if (set_default (mount, target) != 0 || get_default (mount, &current) != 0 || current != target)
            return fail ("The default Btrfs subvolume update could not be verified.");
    } else if (get_default (mount, &current) != 0) {
        return fail ("Could not read the default Btrfs subvolume.");
    }
    g_print ("%" G_GUINT64_FORMAT "\n", current);
    return 0;
}
