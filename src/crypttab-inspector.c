#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <stdint.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KEY_DIRECTORY "/etc/luks-keys/"
#define MAX_CONFIG_SIZE (1024 * 1024)

enum finding {
    INSPECTION_FAILED = 10,
    UNSAFE,
    CONFLICT,
    SHARED,
    STALE,
    IMPLICIT,
    EXTERNAL
};

static int
open_safe(int root, const char *path, unsigned flags)
{
    struct open_how how = {
        .flags = flags | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS
    };
    return syscall(SYS_openat2, root, path, &how, sizeof(how));
}

static gboolean
valid_name(const char *name)
{
    return *name && strlen(name) <= 127 &&
        strspn(name, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+.-") == strlen(name) &&
        strcmp(name, ".") && strcmp(name, "..") && strcmp(name, "control");
}

static gboolean
managed(const char *path)
{
    return !*path || (g_str_has_prefix(path, KEY_DIRECTORY) &&
        valid_name(path + strlen(KEY_DIRECTORY)));
}

static gboolean
protected_directory(int fd)
{
    struct stat st;
    return fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
        st.st_uid == 0 && !(st.st_mode & 0022);
}

static int
inspect_key(int etc, const char *path, gboolean exists, struct stat *st)
{
    if (!*path)
        return 0;
    int dir = open_safe(etc, "luks-keys", O_PATH | O_DIRECTORY);
    if (dir < 0)
        return errno == ENOENT ? (exists ? STALE : 0) :
            (errno == ELOOP || errno == ENOTDIR ? UNSAFE : INSPECTION_FAILED);
    if (!protected_directory(dir)) {
        close(dir);
        return UNSAFE;
    }
    int fd = open_safe(dir, path + strlen(KEY_DIRECTORY), O_PATH);
    int saved_errno = errno;
    close(dir);
    if (fd < 0)
        return saved_errno == ENOENT ? (exists ? STALE : 0) :
            (saved_errno == ELOOP ? UNSAFE : INSPECTION_FAILED);
    int result = 0;
    if (fstat(fd, st) < 0)
        result = INSPECTION_FAILED;
    else if (!exists || !S_ISREG(st->st_mode) || st->st_uid != 0 ||
             st->st_nlink != 1 || (st->st_mode & 0077))
        result = UNSAFE;
    close(fd);
    return result;
}

static int
implicit_key(int root, const char *name)
{
    static const char *dirs[] = {"etc", "run"};
    for (guint i = 0; i < G_N_ELEMENTS(dirs); i++) {
        g_autofree char *path = g_strdup_printf("%s/cryptsetup-keys.d/%s.key", dirs[i], name);
        int fd = open_safe(root, path, O_PATH);
        if (fd >= 0) {
            close(fd);
            return IMPLICIT;
        }
        if (errno != ENOENT)
            return errno == ELOOP ? UNSAFE : INSPECTION_FAILED;
    }
    return 0;
}

static int
check_reference(int root, const char *key, const char *old_path, const char *new_path,
                const struct stat *old_key)
{
    if ((!*old_path && !*new_path) || key[0] != '/')
        return 0;
    g_autofree char *local = g_strdup(key);
    char *separator = strchr(local, ':');
    if (separator)
        *separator = '\0';
    g_autofree char *canonical = g_canonicalize_filename(local, "/");
    if (strcmp(canonical, old_path) == 0 || strcmp(canonical, new_path) == 0)
        return SHARED;
    if (separator)
        return 0;
    // Inspect identity only. An unresolved link could refer to the selected key.
    int fd = open_safe(root, local + 1, O_PATH);
    if (fd < 0)
        return errno == ENOENT ? 0 : UNSAFE;
    struct stat st;
    int result = fstat(fd, &st) < 0 ? INSPECTION_FAILED :
        (*old_path && st.st_dev == old_key->st_dev && st.st_ino == old_key->st_ino ? SHARED : 0);
    close(fd);
    return result;
}

static const char *
key_field(const char *key)
{
    return !key || !strcmp(key, "-") || !strcmp(key, "none") ? "" : key;
}

static char *
decode_field(const char *field)
{
    GString *decoded = g_string_new(NULL);
    for (const char *p = field; *p; p++) {
        if (*p == '\\' && p[1] && p[2] && p[3] &&
            p[1] >= '0' && p[1] <= '3' &&
            p[2] >= '0' && p[2] <= '7' && p[3] >= '0' && p[3] <= '7') {
            unsigned byte = (p[1] - '0') * 64 + (p[2] - '0') * 8 + (p[3] - '0');
            if (!byte) {
                g_string_free(decoded, TRUE);
                return NULL;
            }
            g_string_append_c(decoded, (char) byte);
            p += 3;
        } else if (*p == '\\' && p[1] == '\\') {
            g_string_append_c(decoded, '\\');
            p++;
        } else {
            g_string_append_c(decoded, *p);
        }
    }
    return g_string_free(decoded, FALSE);
}

static int
inspect_config(FILE *file, int root, const char *name, const char *old_name,
               const char *device, const char *options, const char *old_path,
               const char *new_path, const struct stat *old_key)
{
    unsigned matches = 0;
    gboolean old_name_changed = FALSE;
    g_autofree char *line = NULL;
    size_t capacity = 0;
    size_t total = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, file)) >= 0) {
        total += length;
        if (total > MAX_CONFIG_SIZE || memchr(line, '\0', length))
            return INSPECTION_FAILED;
        g_strstrip(line);
        if (!*line || *line == '#')
            continue;

        // Tokenize before interpreting escapes, so escaped whitespace stays in its field.
        char *fields[4] = {0};
        char *cursor = line;
        unsigned count = 0;
        while (*cursor && count < G_N_ELEMENTS(fields)) {
            fields[count++] = cursor;
            cursor += strcspn(cursor, " \t\r\n\f\v");
            if (!*cursor)
                break;
            *cursor++ = '\0';
            cursor += strspn(cursor, " \t\r\n\f\v");
        }
        if (count < 2)
            return INSPECTION_FAILED;
        const char *key = key_field(fields[2]);
        const char *actual_options = fields[3] ? fields[3] : "";
        if (*old_name && !strcmp(fields[0], old_name) && !strcmp(fields[1], device) &&
            !strcmp(key, old_path) && !strcmp(actual_options, options)) {
            matches++;
            continue;
        }

        // Check raw tokens as used by systemd and octal-escaped spellings
        // as used by crypttab writers. Never accept an escaped old record
        // as an exact match for a different raw record.
        g_autofree char *decoded_name = decode_field(fields[0]);
        if (!decoded_name)
            return INSPECTION_FAILED;
        if (*old_name && (!strcmp(fields[0], old_name) || !strcmp(decoded_name, old_name)))
            old_name_changed = TRUE;
        else if (*name && (!strcmp(fields[0], name) || !strcmp(decoded_name, name)))
            return CONFLICT;
        int result = check_reference(root, key, old_path, new_path, old_key);
        if (result)
            return result;
        if (strchr(key, '\\')) {
            g_autofree char *decoded_key = decode_field(key);
            if (!decoded_key)
                return INSPECTION_FAILED;
            result = check_reference(root, decoded_key, old_path, new_path, old_key);
            if (result)
                return result;
        }
    }
    if (ferror(file))
        return INSPECTION_FAILED;
    if (matches != (*old_name ? 1u : 0u))
        return matches > 1 ? CONFLICT : STALE;
    return old_name_changed ? CONFLICT : 0;
}

static int
inspect(int root, const char *name, const char *old_name, const char *device,
        const char *options, const char *old_path, const char *new_path)
{
    int etc = open_safe(root, "etc", O_PATH | O_DIRECTORY);
    if (etc < 0)
        return INSPECTION_FAILED;
    int result = INSPECTION_FAILED;
    struct stat old_key = {0}, scratch;
    if (!protected_directory(etc))
        goto done;
    result = inspect_key(etc, old_path, TRUE, &old_key);
    if (result)
        goto done;
    if (strcmp(old_path, new_path)) {
        result = inspect_key(etc, new_path, FALSE, &scratch);
        if (result)
            goto done;
    }
    if (*old_name && !*old_path && (result = implicit_key(root, old_name)))
        goto done;
    if (*name && !*new_path && (result = implicit_key(root, name)))
        goto done;

    int fd = open_safe(etc, "crypttab", O_PATH);
    if (fd < 0) {
        result = errno == ENOENT ? (*old_name ? STALE : 0) : INSPECTION_FAILED;
    } else {
        struct stat st;
        if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
            (st.st_mode & 0022) || st.st_size > MAX_CONFIG_SIZE) {
            close(fd);
            result = UNSAFE;
            goto done;
        }
        // Reopen the pinned regular file. Do not open a device node, FIFO or
        // replacement path based on a separate pathname check.
        g_autofree char *descriptor = g_strdup_printf("/proc/self/fd/%d", fd);
        int reader = open(descriptor, O_RDONLY | O_CLOEXEC);
        close(fd);
        FILE *file = reader >= 0 ? fdopen(reader, "r") : NULL;
        if (!file) {
            if (reader >= 0)
                close(reader);
            result = INSPECTION_FAILED;
            goto done;
        }
        result = inspect_config(file, root, name, old_name, device, options, old_path, new_path, &old_key);
        struct stat current;
        if (!result && (fstatat(etc, "crypttab", &current, AT_SYMLINK_NOFOLLOW) < 0 ||
            current.st_dev != st.st_dev || current.st_ino != st.st_ino ||
            current.st_ctim.tv_sec != st.st_ctim.tv_sec || current.st_ctim.tv_nsec != st.st_ctim.tv_nsec))
            result = STALE;
        fclose(file);
    }
    if (!result)
        printf("%ju:%ju:%jd:%ld\n", (uintmax_t) old_key.st_dev, (uintmax_t) old_key.st_ino,
               (intmax_t) old_key.st_ctim.tv_sec, old_key.st_ctim.tv_nsec);
done:
    close(etc);
    return result;
}

static int
scan_vg_references(FILE *file, const char *name, const char *mapper)
{
    g_autofree char *device = g_strdup_printf("/dev/%s/", name);
    g_autofree char *mapped = g_strdup_printf("/dev/mapper/%s-", mapper);
    g_autofree char *by_id = g_strdup_printf("/dev/disk/by-id/dm-name-%s-", mapper);
    g_autofree char *boot_lv = g_strdup_printf("rd.lvm.lv=%s/", name);
    g_autofree char *boot_vg = g_strdup_printf("rd.lvm.vg=%s", name);
    g_autofree char *line = NULL;
    size_t capacity = 0, total = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, file)) >= 0) {
        total += length;
        if (total > MAX_CONFIG_SIZE || memchr(line, '\0', length))
            return INSPECTION_FAILED;
        g_strstrip(line);
        if (!*line || *line == '#')
            continue;
        g_autofree char *decoded = decode_field(line);
        if (!decoded)
            return INSPECTION_FAILED;
        if (strstr(decoded, device) || strstr(decoded, mapped) ||
            strstr(decoded, by_id) || strstr(decoded, boot_lv))
            return CONFLICT;
        for (const char *p = decoded; (p = strstr(p, boot_vg)); p++) {
            const char *end = p + strlen(boot_vg);
            if ((p == decoded || g_ascii_isspace(p[-1]) || p[-1] == '"') &&
                (!*end || g_ascii_isspace(*end) || *end == '"'))
                return CONFLICT;
        }
    }
    return ferror(file) ? INSPECTION_FAILED : 0;
}

static gboolean
same_file(const struct stat *original, const struct stat *current)
{
    return original->st_dev == current->st_dev && original->st_ino == current->st_ino &&
        original->st_ctim.tv_sec == current->st_ctim.tv_sec &&
        original->st_ctim.tv_nsec == current->st_ctim.tv_nsec;
}

static int
inspect_vg_file(int root, const char *path, gboolean optional, const char *name, const char *mapper)
{
    int fd = open_safe(root, path, O_PATH);
    if (fd < 0)
        return optional && errno == ENOENT ? 0 : INSPECTION_FAILED;
    struct stat original, current;
    if (fstat(fd, &original) < 0 || !S_ISREG(original.st_mode) ||
        original.st_uid != 0 || (original.st_mode & 0022) || original.st_size > MAX_CONFIG_SIZE) {
        close(fd);
        return UNSAFE;
    }
    g_autofree char *descriptor = g_strdup_printf("/proc/self/fd/%d", fd);
    int reader = open(descriptor, O_RDONLY | O_CLOEXEC);
    close(fd);
    if (reader < 0)
        return INSPECTION_FAILED;
    FILE *file = fdopen(reader, "r");
    if (!file) {
        close(reader);
        return INSPECTION_FAILED;
    }
    int result = scan_vg_references(file, name, mapper);
    fclose(file);
    if (!result && (fstatat(root, path, &current, AT_SYMLINK_NOFOLLOW) < 0 ||
                    !same_file(&original, &current)))
        return STALE;
    return result;
}

static gboolean
verify_vg(GDBusConnection *bus, const char *path, const char *name, const char *uuid)
{
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, "org.freedesktop.UDisks2", path,
        "org.freedesktop.DBus.Properties", "GetAll", g_variant_new("(s)", "org.freedesktop.UDisks2.VolumeGroup"),
        G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL, NULL);
    if (!reply)
        return FALSE;
    g_autoptr(GVariant) properties = g_variant_get_child_value(reply, 0);
    const char *observed_name, *observed_uuid;
    return g_variant_lookup(properties, "Name", "&s", &observed_name) &&
        g_variant_lookup(properties, "UUID", "&s", &observed_uuid) &&
        !strcmp(name, observed_name) && !strcmp(uuid, observed_uuid);
}

static int
inspect_vg(int root, const char *path, const char *name, const char *uuid)
{
    static const char *files[] = {"proc/cmdline", "etc/fstab", "etc/crypttab"};
    if (!g_str_has_prefix(path, "/org/freedesktop/UDisks2/lvm/") || !g_variant_is_object_path(path) ||
        !valid_name(name) || name[0] == '-' || !valid_name(uuid))
        return INSPECTION_FAILED;
    int etc = open_safe(root, "etc", O_PATH | O_DIRECTORY);
    if (etc < 0)
        return INSPECTION_FAILED;
    gboolean safe = protected_directory(etc);
    close(etc);
    if (!safe)
        return UNSAFE;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, NULL);
    if (!bus || !verify_vg(bus, path, name, uuid))
        return STALE;
    g_auto(GStrv) parts = g_strsplit(name, "-", -1);
    g_autofree char *mapper = g_strjoinv("--", parts);
    unsigned findings = 0;
    for (guint i = 0; i < G_N_ELEMENTS(files); i++) {
        int result = inspect_vg_file(root, files[i], i != 0, name, mapper);
        if (result == CONFLICT)
            findings |= 1u << i;
        else if (result)
            return result;
    }
    if (!verify_vg(bus, path, name, uuid))
        return STALE;
    printf("vg-references:%u\n", findings);
    return 0;
}

int
main(int argc, char **argv)
{
    if (geteuid() != 0 || (argc != 7 && argc != 5))
        return INSPECTION_FAILED;
    for (int i = 1; i < argc; i++)
        if (strlen(argv[i]) > 4096)
            return INSPECTION_FAILED;
    gboolean vg_mode = argc == 5 && !strcmp(argv[1], "--vg-references");
    if (!vg_mode) {
        if (argc != 7 || (*argv[1] && !valid_name(argv[1])) || (*argv[2] && !valid_name(argv[2])) ||
            (!*argv[1] && !*argv[2]) || !*argv[3] || (!*argv[2] && *argv[5]))
            return INSPECTION_FAILED;
        if (!managed(argv[5]) || !managed(argv[6]))
            return EXTERNAL;
    }
    // An authorized desktop caller must inspect the system configuration,
    // not a tree substituted in its own private namespace.
    if (g_getenv("PKEXEC_UID")) {
        struct stat caller, system;
        if (stat("/proc/self/ns/mnt", &caller) < 0 || stat("/proc/1/ns/mnt", &system) < 0 ||
            caller.st_dev != system.st_dev || caller.st_ino != system.st_ino)
            return INSPECTION_FAILED;
    }
    int root = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (root < 0)
        return INSPECTION_FAILED;
    int result = vg_mode ? inspect_vg(root, argv[2], argv[3], argv[4]) :
        inspect(root, argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
    close(root);
    return result;
}

