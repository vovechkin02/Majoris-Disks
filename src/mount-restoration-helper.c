/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <blkid/blkid.h>
#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <libmount/libmount.h>
#include <linux/fs.h>
#include <linux/mount.h>
#include <linux/openat2.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

typedef struct {
    int id, parent;
    char *target, *root, *parent_target, *options, *super;
    struct stat directory, source_directory;
    gboolean parent_selected;
    gboolean removed;
} Step;

static struct libmnt_table *table;
static GPtrArray *plan;
static int rootfd, primary;
static dev_t device, original_device;
static char *mapper_name, *mapper_uuid, *backing;
static guint64 backing_seq;
static guint64 diskseq;
static char *uuid, *source, *fstab;
static gboolean fstab_exists;

static void free_step(gpointer pointer)
{
    Step *step = pointer;
    g_free(step->target);
    g_free(step->root);
    g_free(step->parent_target);
    g_free(step->options);
    g_free(step->super);
    g_free(step);
}

static gboolean refresh(void)
{
    if (table)
        mnt_free_table(table);
    table = mnt_new_table_from_file("/proc/self/mountinfo");
    return table != NULL;
}

static struct libmnt_fs *at(const char *target)
{
    return mnt_table_find_target(table, target, MNT_ITER_BACKWARD);
}

static struct libmnt_fs *by_id(int id)
{
    struct libmnt_iter *iter = mnt_new_iter(MNT_ITER_FORWARD);
    struct libmnt_fs *fs, *match = NULL;
    while (mnt_table_next_fs(table, iter, &fs) == 0)
        if (mnt_fs_get_id(fs) == id) {
            match = fs;
            break;
        }
    mnt_free_iter(iter);
    return match;
}

static gboolean private_mount(struct libmnt_fs *fs)
{
    const char *fields = mnt_fs_get_optional_fields(fs);
    return fields == NULL || *fields == '\0';
}

static int secure_open(int base, const char *path, int flags)
{
    struct open_how how = {
        .flags = flags | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    return syscall(SYS_openat2, base, path, &how, sizeof how);
}

static int mount_id(int fd)
{
    struct statx info;
    if (statx(fd, "", AT_EMPTY_PATH, STATX_MNT_ID, &info) < 0 ||
        !(info.stx_mask & STATX_MNT_ID) || info.stx_mnt_id > G_MAXINT)
        return -1;
    return (int)info.stx_mnt_id;
}

static gboolean ordinary_mount(int fd)
{
#if defined(SYS_statmount) && defined(STATX_MNT_ID_UNIQUE)
    struct statx info;
    struct statmount details = {0};
    struct mnt_id_req request = { .size = MNT_ID_REQ_SIZE_VER0, .param = STATMOUNT_MNT_BASIC };
    if (statx(fd, "", AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE, &info) < 0 ||
        !(info.stx_mask & STATX_MNT_ID_UNIQUE))
        return FALSE;
    request.mnt_id = info.stx_mnt_id;
    return syscall(SYS_statmount, &request, &details, sizeof details, 0) == 0 &&
        (details.mask & STATMOUNT_MNT_BASIC) && !(details.mnt_attr & MOUNT_ATTR_IDMAP) &&
        details.mnt_propagation == MS_PRIVATE;
#else
    return FALSE;
#endif
}

static gboolean safe_path(const char *path)
{
    return path && path[0] == '/' && !strstr(path, "//") &&
        !strstr(path, "/../") && !strstr(path, "/./") &&
        !g_str_has_suffix(path, "/..") && !g_str_has_suffix(path, "/.") &&
        !strchr(path, '\n') && !strchr(path, '\r');
}

static gboolean safe_directory(int fd, struct stat *info)
{
    return fstat(fd, info) == 0 && S_ISDIR(info->st_mode) &&
        info->st_uid == 0 && !(info->st_mode & (S_IWGRP | S_IWOTH));
}

/* Keep each component beneath the verified parent. Open the covered directory
 * through a nonrecursive, detached clone during preflight. */
static int target_directory(const Step *step, gboolean covered)
{
    g_auto(GStrv) names = NULL;
    int parent = secure_open(rootfd, step->parent_target[1] ? step->parent_target + 1 : ".",
                             O_PATH | O_DIRECTORY);
    struct libmnt_fs *fs = at(step->parent_target);
    if (parent < 0)
        return -1;
    if (!fs || !private_mount(fs) || !ordinary_mount(parent) || mount_id(parent) != mnt_fs_get_id(fs) ||
        (!step->parent_selected && mnt_fs_get_id(fs) != step->parent) ||
        (step->parent_selected && mnt_fs_get_devno(fs) != device))
        goto fail;
    if (covered) {
        int clone = syscall(SYS_open_tree, parent, "", AT_EMPTY_PATH | OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
        close(parent);
        parent = clone;
        if (parent < 0)
            return -1;
    }
    if (!g_str_has_prefix(step->target, step->parent_target))
        goto fail;
    const char *relative = step->target + strlen(step->parent_target);
    if (step->parent_target[1] && *relative++ != '/')
        goto fail;
    names = g_strsplit(relative, "/", -1);
    int expected = mount_id(parent);
    struct stat info;
    if (!safe_directory(parent, &info))
        goto fail;
    for (guint i = 0; names[i]; i++) {
        int next = secure_open(parent, names[i], O_PATH | O_DIRECTORY);
        close(parent);
        parent = next;
        if (parent < 0)
            return -1;
        if (mount_id(parent) != expected || !safe_directory(parent, &info))
            goto fail;
    }
    return parent;
fail:
    close(parent);
    return -1;
}

static gboolean attributes(const char *options, struct mount_attr *attr)
{
    g_auto(GStrv) flags = g_strsplit(options, ",", -1);
    attr->attr_clr = MOUNT_ATTR_RDONLY | MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV |
        MOUNT_ATTR_NOEXEC | MOUNT_ATTR_NODIRATIME | MOUNT_ATTR__ATIME;
    for (guint i = 0; flags[i]; i++) {
        const char *flag = flags[i];
        if (!strcmp(flag, "rw") || !strcmp(flag, "relatime"))
            continue;
        if (!strcmp(flag, "ro")) attr->attr_set |= MOUNT_ATTR_RDONLY;
        else if (!strcmp(flag, "nosuid")) attr->attr_set |= MOUNT_ATTR_NOSUID;
        else if (!strcmp(flag, "nodev")) attr->attr_set |= MOUNT_ATTR_NODEV;
        else if (!strcmp(flag, "noexec")) attr->attr_set |= MOUNT_ATTR_NOEXEC;
        else if (!strcmp(flag, "noatime")) attr->attr_set |= MOUNT_ATTR_NOATIME;
        else if (!strcmp(flag, "strictatime")) attr->attr_set |= MOUNT_ATTR_STRICTATIME;
        else if (!strcmp(flag, "nodiratime")) attr->attr_set |= MOUNT_ATTR_NODIRATIME;
        else return FALSE;
    }
    return TRUE;
}

static gboolean super_options(const char *options, int context)
{
    g_auto(GStrv) flags = g_strsplit(options, ",", -1);
    for (guint i = 0; flags[i]; i++) {
        const char *flag = flags[i];
        if (!strcmp(flag, "rw"))
            continue;
        if (!strcmp(flag, "ro")) {
            if (context >= 0 && syscall(SYS_fsconfig, context, FSCONFIG_SET_FLAG, "ro", NULL, 0) < 0)
                return FALSE;
        } else if (!strcmp(flag, "errors=remount-ro") || !strcmp(flag, "errors=continue") ||
                   !strcmp(flag, "errors=panic")) {
            if (context >= 0 && syscall(SYS_fsconfig, context, FSCONFIG_SET_STRING, "errors", flag + 7, 0) < 0)
                return FALSE;
        } else return FALSE;
    }
    return TRUE;
}

static gboolean option_set(const char *expected, const char *actual)
{
    g_auto(GStrv) a = g_strsplit(expected, ",", -1);
    g_auto(GStrv) b = g_strsplit(actual, ",", -1);
    if (g_strv_length(a) != g_strv_length(b))
        return FALSE;
    for (guint i = 0; a[i]; i++)
        if (!g_strv_contains((const char * const *)b, a[i]))
            return FALSE;
    return TRUE;
}

static gboolean matches(const Step *step, struct libmnt_fs *fs, gboolean original)
{
    struct libmnt_fs *parent = at(step->parent_target);
    return fs && parent && (!original || (mnt_fs_get_id(fs) == step->id &&
        mnt_fs_get_parent_id(fs) == step->parent)) &&
        mnt_fs_get_parent_id(fs) == mnt_fs_get_id(parent) &&
        (step->parent_selected ? mnt_fs_get_devno(parent) == device : mnt_fs_get_id(parent) == step->parent) &&
        mnt_fs_get_devno(fs) == device && !strcmp(mnt_fs_get_fstype(fs), "ext4") &&
        !strcmp(mnt_fs_get_root(fs), step->root) && private_mount(fs) &&
        option_set(step->options, mnt_fs_get_vfs_options(fs)) &&
        option_set(step->super, mnt_fs_get_fs_options(fs));
}

static gboolean config_matches(void)
{
    g_autofree char *current = NULL;
    gboolean exists = g_file_get_contents("/etc/fstab", &current, NULL, NULL);
    return exists == fstab_exists && g_strcmp0(current, fstab) == 0;
}

static int verified_device(void)
{
    struct stat info;
    guint64 seq;
    int fd = open(source, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0)
        return -1;
    if (fstat(fd, &info) != 0 || !S_ISBLK(info.st_mode) || info.st_rdev != device ||
        ioctl(fd, BLKGETDISKSEQ, &seq) < 0 || (diskseq && diskseq != seq))
        goto fail;
    blkid_probe probe = blkid_new_probe();
    if (!probe)
        goto fail;
    const char *type = NULL, *found = NULL;
    gboolean valid = blkid_probe_set_device(probe, fd, 0, 0) == 0 &&
        blkid_do_safeprobe(probe) == 0 &&
        blkid_probe_lookup_value(probe, "TYPE", &type, NULL) == 0 && !strcmp(type, "ext4") &&
        blkid_probe_lookup_value(probe, "UUID", &found, NULL) == 0 &&
        (!uuid || !strcmp(uuid, found));
    if (valid && !uuid)
        uuid = g_strdup(found);
    blkid_free_probe(probe);
    if (!valid)
        goto fail;
    diskseq = seq;
    return fd;
fail:
    close(fd);
    return -1;
}

static char *sysfs_value(dev_t number, const char *property)
{
    g_autofree char *path = g_strdup_printf("/sys/dev/block/%u:%u/%s",
        major(number), minor(number), property);
    char *value = NULL;
    if (!g_file_get_contents(path, &value, NULL, NULL))
        return NULL;
    return g_strstrip(value);
}

static char *dm_backing(dev_t number)
{
    g_autofree char *directory = g_strdup_printf("/sys/dev/block/%u:%u/slaves",
        major(number), minor(number));
    g_autoptr(GDir) children = g_dir_open(directory, 0, NULL);
    if (!children)
        return NULL;
    const char *name = g_dir_read_name(children);
    if (!name)
        return NULL;
    g_autofree char *path = g_build_filename(directory, name, "dev", NULL);
    char *value = NULL;
    if (g_dir_read_name(children) || !g_file_get_contents(path, &value, NULL, NULL))
        return NULL;
    return g_strstrip(value);
}

static guint64 backing_sequence(const char *number)
{
    g_autofree char *link = g_build_filename("/dev/block", number, NULL);
    g_autofree char *path = realpath(link, NULL);
    if (!path || !g_str_has_prefix(path, "/dev/"))
        return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    guint64 result = 0;
    struct stat info;
    guint maj, min;
    if (fd >= 0) {
        if (sscanf(number, "%u:%u", &maj, &min) != 2 || fstat(fd, &info) < 0 ||
            !S_ISBLK(info.st_mode) || info.st_rdev != makedev(maj, min) ||
            ioctl(fd, BLKGETDISKSEQ, &result) < 0)
            result = 0;
        close(fd);
    }
    return result;
}

static gboolean rebind_mapper(void)
{
    if (!mapper_name)
        return TRUE;
    g_autofree char *link = g_build_filename("/dev/mapper", mapper_name, NULL);
    g_autofree char *current = realpath(link, NULL);
    struct stat info;
    if (!current || !g_str_has_prefix(current, "/dev/dm-") ||
        lstat(current, &info) < 0 || !S_ISBLK(info.st_mode))
        return FALSE;
    g_autofree char *name = sysfs_value(info.st_rdev, "dm/name");
    g_autofree char *identity = sysfs_value(info.st_rdev, "dm/uuid");
    g_autofree char *underlying = dm_backing(info.st_rdev);
    if (g_strcmp0(name, mapper_name) || g_strcmp0(identity, mapper_uuid) ||
        g_strcmp0(underlying, backing) || backing_sequence(backing) != backing_seq)
        return FALSE;
    device = info.st_rdev;
    g_free(source);
    source = g_steal_pointer(&current);
    /* The backing disk generation and dm UUID are stable across a reopen. */
    diskseq = 0;
    return TRUE;
}

static gboolean no_other_users(void)
{
    g_autofree char *directory = g_strdup_printf("/sys/dev/block/%u:%u/holders",
        major(device), minor(device));
    g_autoptr(GDir) holders = g_dir_open(directory, 0, NULL);
    if (!holders || g_dir_read_name(holders))
        return FALSE;
    struct libmnt_table *swaps = mnt_new_table();
    if (!swaps || mnt_table_parse_swaps(swaps, "/proc/swaps") < 0) {
        if (swaps) mnt_free_table(swaps);
        return FALSE;
    }
    gboolean valid = TRUE;
    struct libmnt_iter *iter = mnt_new_iter(MNT_ITER_FORWARD);
    struct libmnt_fs *swap;
    while (mnt_table_next_fs(swaps, iter, &swap) == 0) {
        struct stat info;
        if (stat(mnt_fs_get_source(swap), &info) < 0 ||
            info.st_dev == device || (S_ISBLK(info.st_mode) && info.st_rdev == device)) {
            valid = FALSE;
            break;
        }
    }
    mnt_free_iter(iter);
    mnt_free_table(swaps);
    return valid;
}

static gboolean no_foreign_mounts(void)
{
    struct stat self;
    g_autoptr(GDir) processes = g_dir_open("/proc", 0, NULL);
    if (!processes || stat("/proc/self/ns/mnt", &self) < 0)
        return FALSE;
    g_autoptr(GHashTable) seen = g_hash_table_new(g_direct_hash, g_direct_equal);
    const char *pid;
    while ((pid = g_dir_read_name(processes))) {
        if (strspn(pid, "0123456789") != strlen(pid))
            continue;
        g_autofree char *ns = g_build_filename("/proc", pid, "ns/mnt", NULL);
        struct stat other;
        if (stat(ns, &other) < 0) {
            if (errno == ENOENT || errno == ESRCH)
                continue;
            return FALSE;
        }
        if (other.st_ino == self.st_ino ||
            !g_hash_table_add(seen, GSIZE_TO_POINTER(other.st_ino)))
            continue;
        g_autofree char *path = g_build_filename("/proc", pid, "mountinfo", NULL);
        struct libmnt_table *foreign = mnt_new_table_from_file(path);
        if (!foreign) {
            if (!g_file_test(ns, G_FILE_TEST_EXISTS))
                continue;
            return FALSE;
        }
        gboolean mounted = mnt_table_find_devno(foreign, device, MNT_ITER_FORWARD) != NULL;
        mnt_free_table(foreign);
        if (mounted)
            return FALSE;
    }
    return TRUE;
}

/* Unmount has no descriptor variant. Verify every pathname component is
 * protected from unprivileged replacement, then use UMOUNT_NOFOLLOW. */
static gboolean protected_path(const char *path, int expected_mount)
{
    g_auto(GStrv) names = g_strsplit(path + 1, "/", -1);
    int fd = fcntl(rootfd, F_DUPFD_CLOEXEC, 3);
    struct stat info;
    if (fd < 0)
        return FALSE;
    for (guint i = 0; names[i]; i++) {
        int next = secure_open(fd, names[i], O_PATH | O_DIRECTORY);
        close(fd);
        fd = next;
        if (fd < 0)
            return FALSE;
        if (!safe_directory(fd, &info)) {
            close(fd);
            return FALSE;
        }
    }
    gboolean result = mount_id(fd) == expected_mount && ordinary_mount(fd);
    close(fd);
    return result;
}

static gboolean same_namespace(void)
{
    struct stat self, system;
    return stat("/proc/self/ns/mnt", &self) == 0 && stat("/proc/1/ns/mnt", &system) == 0 &&
        self.st_dev == system.st_dev && self.st_ino == system.st_ino;
}

static gboolean capture(void)
{
    g_autoptr(GPtrArray) pending = g_ptr_array_new_with_free_func(free_step);
    struct libmnt_iter *iter = mnt_new_iter(MNT_ITER_FORWARD);
    struct libmnt_fs *fs;
    gboolean valid = TRUE;
    while (valid && mnt_table_next_fs(table, iter, &fs) == 0) {
        if (mnt_fs_get_devno(fs) != device)
            continue;
        Step *step = g_new0(Step, 1);
        g_ptr_array_add(pending, step);
        step->id = mnt_fs_get_id(fs);
        step->parent = mnt_fs_get_parent_id(fs);
        step->target = g_strdup(mnt_fs_get_target(fs));
        step->root = g_strdup(mnt_fs_get_root(fs));
        step->options = g_strdup(mnt_fs_get_vfs_options(fs));
        step->super = g_strdup(mnt_fs_get_fs_options(fs));
        struct libmnt_fs *parent = by_id(step->parent);
        step->parent_target = parent ? g_strdup(mnt_fs_get_target(parent)) : NULL;
        step->parent_selected = parent && mnt_fs_get_devno(parent) == device;
        struct mount_attr attr = {0};
        valid = pending->len <= 64 && safe_path(step->target) && safe_path(step->root) &&
            safe_path(step->parent_target) && step->options && step->super &&
            (g_str_has_prefix(step->target, "/mnt/") ||
             (step->id == primary && (g_str_has_prefix(step->target, "/media/") ||
              g_str_has_prefix(step->target, "/run/media/") || g_str_has_prefix(step->target, "/srv/")))) &&
            matches(step, fs, TRUE) && at(step->target) == fs &&
            attributes(step->options, &attr) && super_options(step->super, -1);
        if (valid && step->id == primary) {
            int fd = secure_open(rootfd, step->target + 1, O_PATH | O_DIRECTORY);
            valid = fd >= 0 && ordinary_mount(fd) && mount_id(fd) == step->id;
            if (fd >= 0) close(fd);
        }
        if (valid && step->id != primary) {
            valid = protected_path(step->target, step->id);
            int fd = target_directory(step, TRUE);
            valid = valid && fd >= 0 && safe_directory(fd, &step->directory);
            if (fd >= 0) close(fd);
        }
    }
    mnt_free_iter(iter);
    if (!valid || pending->len < 2)
        return FALSE;

    /* Parents precede children. A verified whole-filesystem mount is the
     * source of subdirectory clones. Reject foreign children and stacking. */
    int anchor = primary;
    for (guint i = 0; i < pending->len; i++) {
        Step *step = g_ptr_array_index(pending, i);
        if (!anchor && !strcmp(step->root, "/") &&
            mnt_fs_get_devno(by_id(step->parent)) != device)
            anchor = step->id;
    }
    if (!anchor)
        return FALSE;
    iter = mnt_new_iter(MNT_ITER_FORWARD);
    while (valid && mnt_table_next_fs(table, iter, &fs) == 0)
        for (guint i = 0; i < pending->len; i++) {
            Step *step = g_ptr_array_index(pending, i);
            if (mnt_fs_get_id(fs) != step->id &&
                (!strcmp(mnt_fs_get_target(fs), step->target) ||
                 (mnt_fs_get_parent_id(fs) == step->id && mnt_fs_get_devno(fs) != device)))
                valid = FALSE;
        }
    mnt_free_iter(iter);
    if (!valid)
        return FALSE;

    for (guint i = 0; i < pending->len; i++) {
        Step *step = g_ptr_array_index(pending, i);
        if (step->id != anchor)
            continue;
        if (strcmp(step->root, "/") || mnt_fs_get_devno(by_id(step->parent)) == device)
            return FALSE;
        g_ptr_array_add(plan, g_ptr_array_steal_index(pending, i));
        break;
    }
    if (!plan->len)
        return FALSE;
    while (pending->len) {
        gboolean added = FALSE;
        for (guint i = 0; i < pending->len; i++) {
            Step *step = g_ptr_array_index(pending, i);
            if (mnt_fs_get_devno(by_id(step->parent)) == device) {
                gboolean parent_added = FALSE;
                for (guint j = 0; j < plan->len; j++)
                    if (((Step *)g_ptr_array_index(plan, j))->id == step->parent)
                        parent_added = TRUE;
                if (!parent_added)
                    continue;
            }
            g_ptr_array_add(plan, g_ptr_array_steal_index(pending, i));
            added = TRUE;
            break;
        }
        if (!added)
            return FALSE;
    }
    Step *base = g_ptr_array_index(plan, 0);
    for (guint i = 1; i < plan->len; i++) {
        Step *step = g_ptr_array_index(plan, i);
        if (!option_set(base->super, step->super))
            return FALSE;
        if (strcmp(step->root, "/")) {
            int fd = secure_open(rootfd, base->target + 1, O_PATH | O_DIRECTORY);
            int sub = fd < 0 ? -1 : secure_open(fd, step->root + 1, O_PATH | O_DIRECTORY);
            valid = sub >= 0 && mount_id(fd) == base->id && mount_id(sub) == base->id &&
                safe_directory(sub, &step->source_directory);
            if (sub >= 0) close(sub);
            if (fd >= 0) close(fd);
            if (!valid)
                return FALSE;
        }
    }
    return TRUE;
}

static gboolean prepare(void)
{
    if (!config_matches() || !same_namespace() || !refresh() || !no_foreign_mounts() || !no_other_users())
        return FALSE;
    int block = verified_device();
    if (block < 0)
        return FALSE;
    close(block);
    guint count = 0;
    struct libmnt_iter *iter = mnt_new_iter(MNT_ITER_FORWARD);
    struct libmnt_fs *fs;
    while (mnt_table_next_fs(table, iter, &fs) == 0)
        if (mnt_fs_get_devno(fs) == device)
            count++;
    mnt_free_iter(iter);
    if (count != plan->len)
        return FALSE;
    for (guint i = 0; i < plan->len; i++) {
        Step *step = g_ptr_array_index(plan, i);
        if (!matches(step, at(step->target), TRUE))
            return FALSE;
    }
    /* Rebuild against fresh kernel state before each ordinary unmount. */
    for (guint i = plan->len; i > 0; i--) {
        Step *step = g_ptr_array_index(plan, i - 1);
        if (step->id == primary)
            continue;
        if (!refresh() || !matches(step, at(step->target), TRUE))
            return FALSE;
        int target = target_directory(step, TRUE);
        struct stat info;
        gboolean valid = target >= 0 && safe_directory(target, &info) &&
            info.st_ino == step->directory.st_ino && info.st_dev == step->directory.st_dev;
        if (target >= 0) close(target);
        if (!valid || !protected_path(step->target, step->id) ||
            umount2(step->target, UMOUNT_NOFOLLOW) < 0)
            return FALSE;
        step->removed = TRUE;
    }
    return TRUE;
}

static gboolean idle(void)
{
    if (!same_namespace() || !config_matches() || !no_foreign_mounts() || !refresh() ||
        mnt_table_find_devno(table, device, MNT_ITER_FORWARD))
        return FALSE;
    int fd = open(source, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | O_EXCL);
    if (fd < 0)
        return FALSE;
    struct stat info;
    guint64 seq;
    gboolean valid = fstat(fd, &info) == 0 && S_ISBLK(info.st_mode) && info.st_rdev == device &&
        ioctl(fd, BLKGETDISKSEQ, &seq) == 0 && seq == diskseq;
    close(fd);
    return valid;
}

static int new_filesystem(const Step *step, int block)
{
    int context = syscall(SYS_fsopen, "ext4", FSOPEN_CLOEXEC);
    if (context < 0)
        return -1;
    g_autofree char *path = g_strdup_printf("/proc/self/fd/%d", block);
    int fd = -1;
    if (syscall(SYS_fsconfig, context, FSCONFIG_SET_STRING, "source", path, 0) == 0 &&
        super_options(step->super, context) &&
        syscall(SYS_fsconfig, context, FSCONFIG_CMD_CREATE, NULL, NULL, 0) == 0)
        fd = syscall(SYS_fsmount, context, FSMOUNT_CLOEXEC, 0);
    close(context);
    return fd;
}

static gboolean restore_step(Step *step, Step *base, int block)
{
    if (!refresh())
        return FALSE;
    struct libmnt_fs *current = at(step->target);
    if (current) {
        if (!matches(step, current, FALSE))
            return FALSE;
        int fd = secure_open(rootfd, step->target + 1, O_PATH | O_DIRECTORY);
        gboolean valid = fd >= 0 && mount_id(fd) == mnt_fs_get_id(current) && ordinary_mount(fd);
        if (fd >= 0) close(fd);
        return valid;
    }
    if (!step->removed || !config_matches())
        return FALSE;
    struct libmnt_fs *parent = at(step->parent_target);
    if (!parent || !protected_path(step->target, mnt_fs_get_id(parent)))
        return FALSE;
    int target = target_directory(step, FALSE);
    struct stat info;
    if (target < 0)
        return FALSE;
    int detached = -1;
    dev_t expected_device = step->directory.st_dev == original_device ? device : step->directory.st_dev;
    if (!safe_directory(target, &info) || info.st_ino != step->directory.st_ino ||
        info.st_dev != expected_device)
        goto done;
    if (step == base) {
        detached = new_filesystem(step, block);
    } else if (matches(base, at(base->target), FALSE)) {
        int root = secure_open(rootfd, base->target + 1, O_PATH | O_DIRECTORY);
        if (root >= 0) {
            int sub = secure_open(root, step->root[1] ? step->root + 1 : ".", O_PATH | O_DIRECTORY);
            if (sub >= 0) {
                if (mount_id(root) == mnt_fs_get_id(at(base->target)) && ordinary_mount(root) &&
                    mount_id(sub) == mount_id(root) && safe_directory(sub, &info) &&
                    (!step->root[1] || info.st_ino == step->source_directory.st_ino))
                    detached = syscall(SYS_open_tree, sub, "", AT_EMPTY_PATH | OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
                close(sub);
            }
            close(root);
        }
    }
    struct mount_attr attr = {0};
    gboolean success = detached >= 0 && attributes(step->options, &attr) &&
        syscall(SYS_mount_setattr, detached, "", AT_EMPTY_PATH, &attr, sizeof attr) == 0 &&
        syscall(SYS_move_mount, detached, "", target, "", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH) == 0;
    if (detached >= 0) close(detached);
    close(target);
    return success && refresh() && matches(step, at(step->target), FALSE);
done:
    close(target);
    return FALSE;
}

static gboolean restore(void)
{
    if (!same_namespace() || !config_matches() || !rebind_mapper() || !no_foreign_mounts())
        return FALSE;
    int block = verified_device();
    if (block < 0)
        return FALSE;
    gboolean success = TRUE;
    Step *base = g_ptr_array_index(plan, 0);
    for (guint i = 0; i < plan->len; i++) {
        Step *step = g_ptr_array_index(plan, i);
        if (step->id != primary && !restore_step(step, base, block))
            success = FALSE;
    }
    close(block);
    return success;
}

int main(int argc, char **argv)
{
    guint major_number, minor_number;
    char tail;
    if (geteuid() != 0 || argc != 3 || !same_namespace() ||
        sscanf(argv[1], "%u:%u%c", &major_number, &minor_number, &tail) != 2 ||
        sscanf(argv[2], "%d%c", &primary, &tail) != 1 || primary < 0)
        return 2;
    original_device = device = makedev(major_number, minor_number);
    rootfd = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
    plan = g_ptr_array_new_with_free_func(free_step);
    if (rootfd < 0 || !refresh())
        return 2;
    g_autofree char *link = g_strdup_printf("/dev/block/%u:%u", major_number, minor_number);
    source = realpath(link, NULL);
    if (!source || !g_str_has_prefix(source, "/dev/"))
        return 2;
    int block = verified_device();
    if (block < 0)
        return 2;
    close(block);
    mapper_name = sysfs_value(device, "dm/name");
    if (mapper_name) {
        mapper_uuid = sysfs_value(device, "dm/uuid");
        backing = dm_backing(device);
        if (!mapper_uuid || (!g_str_has_prefix(mapper_uuid, "CRYPT-LUKS1-") &&
            !g_str_has_prefix(mapper_uuid, "CRYPT-LUKS2-")) || !backing ||
            !*mapper_name || strspn(mapper_name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != strlen(mapper_name))
            return 2;
        backing_seq = backing_sequence(backing);
        if (!backing_seq)
            return 2;
    }
    if (!no_foreign_mounts() || !no_other_users())
        return 2;
    int capability = syscall(SYS_fsopen, "ext4", FSOPEN_CLOEXEC);
    if (capability < 0)
        return 2;
    close(capability);
    g_autofree char *autoclear = sysfs_value(device, "loop/autoclear");
    if (autoclear && strcmp(autoclear, "0"))
        return 2;
    fstab_exists = g_file_get_contents("/etc/fstab", &fstab, NULL, NULL);
    if (!fstab_exists && g_file_test("/etc/fstab", G_FILE_TEST_EXISTS))
        return 2;
    if (!capture())
        return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("ready");
    for (guint i = 0; i < plan->len; i++)
        printf(" %d", ((Step *)g_ptr_array_index(plan, i))->id);
    puts("");
    struct pollfd request = { .fd = STDIN_FILENO, .events = POLLIN };
    char command[32];
    if (poll(&request, 1, 120000) <= 0 || !fgets(command, sizeof command, stdin) ||
        strcmp(command, "prepare\n"))
        return 2;
    puts(prepare() ? "prepared" : "prepare-failed");
    if (poll(&request, 1, 1800000) <= 0 || !fgets(command, sizeof command, stdin))
        return 2;
    if (!strcmp(command, "idle\n")) {
        puts(idle() ? "idle" : "busy");
        if (poll(&request, 1, 1800000) <= 0 || !fgets(command, sizeof command, stdin))
            return 2;
    }
    if (strcmp(command, "restore\n"))
        return 2;
    puts(restore() ? "restored" : "restore-failed");
    return 0;
}
