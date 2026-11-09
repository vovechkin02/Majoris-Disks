/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <blkid/blkid.h>
#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <libcryptsetup.h>
#include <linux/fs.h>
#include <linux/loop.h>
#include <linux/openat2.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

/* The worker is unprivileged. FD 3 is the UDisks-authorized block descriptor.
 * Cryptsetup operates on private regular files, never on a reopened device path. */
#define DEVICE 3
#define LIMIT (136 * 1024 * 1024)
#define CHECKSUM "user.majoris.luks-sha256"
#define SOURCE_SIZE "user.majoris.luks-source-size"

typedef struct {
    struct crypt_device *cd;
    guint64 offset, extent;
    unsigned sector;
    char *description;
} Header;

static void header_clear(Header *h)
{
    crypt_free(h->cd);
    g_free(h->description);
}

G_DEFINE_AUTO_CLEANUP_CLEAR_FUNC(Header, header_clear)

static void close_fd(int *fd)
{
    if (*fd >= 0)
        close(*fd);
}

#define auto_fd __attribute__((cleanup(close_fd))) int

static int fail(int status, const char *message)
{
    fprintf(stderr, "%s\n", message);
    return status;
}

static void quiet(int level, const char *message, void *data)
{
    (void) level;
    (void) message;
    (void) data;
}

static gboolean read_at(int fd, void *buffer, size_t bytes, guint64 offset)
{
    return TEMP_FAILURE_RETRY(pread(fd, buffer, bytes, offset)) == (ssize_t) bytes;
}

static gboolean transfer(int from, int to, guint64 bytes, GChecksum *sum)
{
    guint8 buffer[65536];
    for (guint64 offset = 0; offset < bytes;) {
        size_t count = MIN(sizeof buffer, bytes - offset);
        if (!read_at(from, buffer, count, offset))
            return FALSE;
        if (sum)
            g_checksum_update(sum, buffer, count);
        if (to >= 0 && TEMP_FAILURE_RETRY(pwrite(to, buffer, count, offset)) != (ssize_t) count)
            return FALSE;
        offset += count;
    }
    return TRUE;
}

static char *checksum(int fd, guint64 bytes)
{
    g_autoptr(GChecksum) sum = g_checksum_new(G_CHECKSUM_SHA256);
    return transfer(fd, -1, bytes, sum) ? g_strdup(g_checksum_get_string(sum)) : NULL;
}

static char *fd_path(int fd)
{
    return g_strdup_printf("/proc/self/fd/%d", fd);
}

static JsonObject *object_member(JsonObject *parent, const char *name)
{
    JsonNode *node = parent ? json_object_get_member(parent, name) : NULL;
    return node && JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
}

static const char *string_member(JsonObject *parent, const char *name)
{
    JsonNode *node = parent ? json_object_get_member(parent, name) : NULL;
    return node && JSON_NODE_HOLDS_VALUE(node) && json_node_get_value_type(node) == G_TYPE_STRING
        ? json_node_get_string(node) : NULL;
}

/* Retain the volume-key digest parameters, excluding the list of keyslots
 * that reference the digest. Passphrase edits may change that list. */
static char *luks2_key_digest(struct crypt_device *cd)
{
    const char *json = NULL;
    g_autoptr(JsonParser) parser = json_parser_new();
    if (crypt_dump_json(cd, &json, 0) < 0 || !json ||
        !json_parser_load_from_data(parser, json, -1, NULL))
        return NULL;
    JsonNode *root = json_parser_get_root(parser);
    if (!JSON_NODE_HOLDS_OBJECT(root))
        return NULL;
    JsonObject *metadata = json_node_get_object(root);
    JsonObject *segments = object_member(metadata, "segments");
    JsonObject *segment = object_member(segments, "0");
    JsonObject *config = object_member(metadata, "config");
    JsonObject *digests = object_member(metadata, "digests");
    if (!segments || json_object_get_size(segments) != 1 || !segment || !config ||
        g_strcmp0(string_member(segment, "type"), "crypt") ||
        g_strcmp0(string_member(segment, "size"), "dynamic") ||
        g_strcmp0(string_member(segment, "iv_tweak"), "0") ||
        json_object_has_member(segment, "integrity") || json_object_has_member(segment, "flags") ||
        json_object_has_member(config, "requirements") || json_object_has_member(config, "flags") ||
        !digests || json_object_get_size(digests) != 1)
        return NULL;
    g_autoptr(GList) names = json_object_get_members(digests);
    JsonObject *digest = object_member(digests, names->data);
    const char *hash = string_member(digest, "hash");
    const char *salt = string_member(digest, "salt");
    const char *key = string_member(digest, "digest");
    JsonNode *iterations = digest ? json_object_get_member(digest, "iterations") : NULL;
    JsonNode *binding = digest ? json_object_get_member(digest, "segments") : NULL;
    JsonArray *bound = binding && JSON_NODE_HOLDS_ARRAY(binding) ? json_node_get_array(binding) : NULL;
    if (!hash || !salt || !key || g_strcmp0(string_member(digest, "type"), "pbkdf2") ||
        !iterations || !JSON_NODE_HOLDS_VALUE(iterations) ||
        json_node_get_value_type(iterations) != G_TYPE_INT64 ||
        !bound || json_array_get_length(bound) != 1)
        return NULL;
    JsonNode *bound_segment = json_array_get_element(bound, 0);
    if (!JSON_NODE_HOLDS_VALUE(bound_segment) || json_node_get_value_type(bound_segment) != G_TYPE_STRING ||
        g_strcmp0(json_node_get_string(bound_segment), "0"))
        return NULL;
    g_autofree char *parameters = g_strdup_printf("%s:%s:%s:%" G_GINT64_FORMAT,
        hash, salt, key, json_node_get_int(iterations));
    return g_compute_checksum_for_string(G_CHECKSUM_SHA256, parameters, -1);
}

/* 0 means unreadable, -1 means recognized but outside the supported layouts. */
static int load_header(int fd, Header *h)
{
    g_autofree char *path = fd_path(fd);
    if (crypt_init(&h->cd, path) < 0 || crypt_load(h->cd, CRYPT_LUKS, NULL) < 0)
        return 0;
    const char *type = crypt_get_type(h->cd);
    const char *uuid = crypt_get_uuid(h->cd);
    const char *cipher = crypt_get_cipher(h->cd);
    const char *mode = crypt_get_cipher_mode(h->cd);
    int key_bytes = crypt_get_volume_key_size(h->cd);
    int sector = crypt_get_sector_size(h->cd);
    guint64 sectors = crypt_get_data_offset(h->cd);
    if (!uuid || !g_uuid_string_is_valid(uuid) || !cipher || !mode ||
        key_bytes <= 0 || sector <= 0 || !sectors || sectors > G_MAXINT64 / 512)
        return -1;
    h->offset = sectors * 512;
    h->sector = sector;
    if (h->offset % h->sector)
        return -1;
    g_autofree char *digest = NULL;
    if (!strcmp(type, CRYPT_LUKS1)) {
        guint8 verifier[56];
        if (!read_at(fd, verifier, sizeof verifier, 112))
            return -1;
        digest = g_compute_checksum_for_data(G_CHECKSUM_SHA256, verifier, sizeof verifier);
        for (int slot = 0; slot < crypt_keyslot_max(type); slot++) {
            guint64 start, size;
            if (crypt_keyslot_area(h->cd, slot, &start, &size) < 0 || start > LIMIT || size > LIMIT - start)
                return -1;
            h->extent = MAX(h->extent, start + size);
        }
    } else if (!strcmp(type, CRYPT_LUKS2)) {
        guint64 metadata, keyslots;
        digest = luks2_key_digest(h->cd);
        if (crypt_get_metadata_size(h->cd, &metadata, &keyslots) < 0 ||
            metadata > LIMIT / 2 || keyslots > LIMIT - 2 * metadata)
            return -1;
        h->extent = 2 * metadata + keyslots;
    }
    if (!digest || !h->extent || h->extent > h->offset || h->extent % 512)
        return -1;
    h->description = g_strdup_printf("%s %s %" G_GUINT64_FORMAT " %d %d %s %s %s",
        type, uuid, h->offset, key_bytes, sector, cipher, mode, digest);
    return 1;
}

static gboolean backup_size(const Header *h, guint64 bytes)
{
    return bytes == h->extent ||
        (g_str_has_prefix(h->description, "LUKS1 ") && bytes > h->extent &&
         bytes % 4096 == 0 && bytes - h->extent < 4096);
}

static int open_path(const char *path, int flags)
{
    struct open_how how = {
        .flags = flags | O_CLOEXEC,
        .resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    if (!g_path_is_absolute(path))
        return -1;
    return syscall(SYS_openat2, AT_FDCWD, path, &how, sizeof how);
}

static gboolean has_other_signature(int fd, guint64 capacity)
{
    blkid_probe probe = blkid_new_probe();
    if (!probe)
        return TRUE;
    int result = -1;
    if (!blkid_probe_set_device(probe, fd, 0, capacity) &&
        !blkid_probe_enable_partitions(probe, 1) &&
        !blkid_probe_enable_superblocks(probe, 1))
        result = blkid_do_safeprobe(probe);
    blkid_free_probe(probe);
    return result != 1;
}

/* This binding is evidence of device identity only. Never read ciphertext
 * for provenance. Loop identity includes the backing inode and byte range. */
static char *portable_binding(const char *binding)
{
    if (!g_str_has_prefix(binding, "loop:"))
        return g_strdup(binding);
    struct loop_info64 loop;
    if (ioctl(DEVICE, LOOP_GET_STATUS64, &loop) || !loop.lo_inode)
        return g_strdup("");
    g_autofree char *identity = g_strdup_printf("%s:%llu:%llu:%llu:%llu", binding,
        (unsigned long long) loop.lo_device, (unsigned long long) loop.lo_inode,
        (unsigned long long) loop.lo_offset, (unsigned long long) loop.lo_sizelimit);
    return g_compute_checksum_for_string(G_CHECKSUM_SHA256, identity, -1);
}

#define MANIFEST_SUFFIX ".majoris.json"
#define MANIFEST_LIMIT 8192
#define MANIFEST_FORMAT "majoris-luks-header-manifest"

static char *manifest_data(const Header *header, const char *hash, const char *binding,
    guint64 capacity, unsigned logical_sector)
{
    /* All strings are fixed identifiers, hexadecimal hashes or validated UUIDs. */
    return g_strdup_printf(
        "{\n  \"format\": \"%s\",\n  \"version\": 1,\n"
        "  \"header_sha256\": \"%s\",\n  \"luks_type\": \"%s\",\n"
        "  \"luks_uuid\": \"%s\",\n  \"source_capacity_bytes\": %" G_GUINT64_FORMAT ",\n"
        "  \"data_offset_bytes\": %" G_GUINT64_FORMAT ",\n  \"logical_sector_bytes\": %u,\n"
        "  \"device_binding\": \"%s\"\n}\n",
        MANIFEST_FORMAT, hash, crypt_get_type(header->cd), crypt_get_uuid(header->cd),
        capacity, header->offset, logical_sector, binding);
}

static gboolean integer_matches(JsonObject *object, const char *name, guint64 expected)
{
    JsonNode *node = json_object_get_member(object, name);
    return node && JSON_NODE_HOLDS_VALUE(node) && json_node_get_value_type(node) == G_TYPE_INT64 &&
        json_node_get_int(node) >= 0 && (guint64) json_node_get_int(node) == expected;
}

static gboolean valid_binding(const char *binding)
{
    return binding && (!*binding ||
        (strlen(binding) == 64 && strspn(binding, "0123456789abcdef") == 64));
}

static void count_manifest_member(JsonParser *parser, JsonObject *object, const char *name, unsigned *count)
{
    (void) parser;
    (void) object;
    (void) name;
    (*count)++;
}

/* 0: absent, -1: invalid/incompatible, 1: structurally valid, 2: identity match. */
static int read_manifest(int directory, const char *name, const Header *header,
    const char *hash, const char *binding, guint64 capacity, unsigned logical_sector,
    char **manifest_hash)
{
    auto_fd fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return errno == ENOENT ? 0 : -1;
    struct stat st;
    char buffer[MANIFEST_LIMIT];
    unsigned members = 0;
    g_autoptr(JsonParser) parser = json_parser_new ();
    g_signal_connect(parser, "object-member", G_CALLBACK(count_manifest_member), &members);
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        st.st_size > sizeof buffer || !read_at(fd, buffer, st.st_size, 0) ||
        memchr(buffer, 0, st.st_size) || !json_parser_load_from_data(parser, buffer, st.st_size, NULL))
        return -1;
    JsonNode *root = json_parser_get_root(parser);
    JsonObject *object = root && JSON_NODE_HOLDS_OBJECT(root) ? json_node_get_object(root) : NULL;
    if (!object || members != 9 || json_object_get_size(object) != 9 ||
        g_strcmp0(string_member(object, "format"), MANIFEST_FORMAT) ||
        !integer_matches(object, "version", 1) ||
        g_strcmp0(string_member(object, "header_sha256"), hash) ||
        g_strcmp0(string_member(object, "luks_type"), crypt_get_type(header->cd)) ||
        g_strcmp0(string_member(object, "luks_uuid"), crypt_get_uuid(header->cd)) ||
        !integer_matches(object, "source_capacity_bytes", capacity) ||
        !integer_matches(object, "data_offset_bytes", header->offset) ||
        !integer_matches(object, "logical_sector_bytes", logical_sector))
        return -1;
    const char *saved = string_member(object, "device_binding");
    if (!valid_binding(saved))
        return -1;
    *manifest_hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *) buffer, st.st_size);
    return *saved && !strcmp(saved, binding) ? 2 : 1;
}

static int create_backup(const char *destination, const char *binding, const Header *source,
    int snapshot, guint64 capacity, unsigned logical_sector)
{
    g_autofree char *parent = g_path_get_dirname(destination);
    g_autofree char *name = g_path_get_basename(destination);
    g_autofree char *manifest_name = g_strconcat(name, MANIFEST_SUFFIX, NULL);
    auto_fd directory = open_path(parent, O_DIRECTORY | O_RDONLY);
    struct stat existing, original_directory;
    if (directory < 0 || fstat(directory, &original_directory) || !strcmp(name, ".") || !strcmp(name, ".."))
        return fail(2, "Choose a local backup directory without symbolic links.");
    if (fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
        return fail(2, "The backup destination already exists or cannot be checked.");
    if (fstatat(directory, manifest_name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
        return fail(2, "The companion manifest already exists or cannot be checked.");
    struct statvfs space;
    if (fstatvfs(directory, &space) || space.f_bavail < (source->extent + 4095 + MAX(space.f_frsize, 1) - 1) / MAX(space.f_frsize, 1))
        return fail(2, "The destination has insufficient or unknown free space.");
    auto_fd output = openat(directory, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
    if (output < 0 || fchmod(output, 0600))
        return fail(2, "This destination cannot create a private backup safely.");

    /* crypt_header_backup requires a new pathname. Only the unprivileged
     * worker writes this 0700 staging directory. */
    struct stat scratch;
    if (lstat("/tmp", &scratch) || !S_ISDIR(scratch.st_mode) || scratch.st_uid != 0 ||
        ((scratch.st_mode & 0022) && !(scratch.st_mode & S_ISVTX)))
        return fail(2, "The system staging directory is not safe for header backups.");
    char stage[] = "/tmp/majoris-luks-XXXXXX";
    if (!g_mkdtemp(stage))
        return fail(2, "Could not create a private backup staging directory.");
    g_autofree char *path = g_build_filename(stage, "header", NULL);
    int generated = crypt_header_backup(source->cd, crypt_get_type(source->cd), path);
    auto_fd input = generated == 0 ? open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
    g_unlink(path);
    g_rmdir(stage);
    puts("phase:verify-backup");
    struct stat st;
    g_auto(Header) verified = {0};
    if (input < 0 || fstat(input, &st) || !backup_size(source, st.st_size) ||
        load_header(input, &verified) != 1 || strcmp(source->description, verified.description) ||
        source->extent != verified.extent || !transfer(input, output, st.st_size, NULL))
        return fail(2, "The generated backup could not be created or verified.");
    g_autofree char *expected = checksum(input, st.st_size);
    g_autofree char *actual = checksum(output, st.st_size);
    g_autofree char *before = checksum(snapshot, source->extent);
    g_autofree char *after = checksum(DEVICE, source->extent);
    if (!expected || g_strcmp0(expected, actual) || !before || g_strcmp0(before, after))
        return fail(2, "The source or backup changed during verification.");
    g_autofree char *manifest = manifest_data(source, actual, binding, capacity, logical_sector);
    auto_fd metadata = openat(directory, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
    size_t manifest_size = strlen(manifest);
    g_autofree char *verified_manifest = g_malloc(manifest_size);
    if (metadata < 0 || fchmod(metadata, 0600) ||
        TEMP_FAILURE_RETRY(write(metadata, manifest, manifest_size)) != (ssize_t) manifest_size ||
        !read_at(metadata, verified_manifest, manifest_size, 0) ||
        memcmp(manifest, verified_manifest, manifest_size) || fsync(metadata) || fsync(output))
        return fail(2, "Could not write, verify and synchronize both backup files.");
    auto_fd current_directory = open_path(parent, O_DIRECTORY | O_RDONLY);
    if (current_directory < 0 || fstat(current_directory, &existing) ||
        original_directory.st_dev != existing.st_dev || original_directory.st_ino != existing.st_ino)
        return fail(2, "The backup directory changed before publishing the file.");
    g_autofree char *output_path = fd_path(output);
    if (linkat(AT_FDCWD, output_path, directory, name, AT_SYMLINK_FOLLOW))
        return fail(2, "Could not publish the verified backup without overwriting a file.");
    if (fsync(directory))
        return fail(3, "The verified file was published, but directory durability could not be confirmed.");
    g_autofree char *metadata_path = fd_path(metadata);
    if (linkat(AT_FDCWD, metadata_path, directory, manifest_name, AT_SYMLINK_FOLLOW))
        return fail(3, "The raw header is durable, but the companion manifest could not be published.");
    if (fsync(directory))
        return fail(3, "The raw header is durable, but manifest durability could not be confirmed.");
    puts(*binding ? "device-identity" : "header-only");
    return 0;
}

#define KEYFILE_LIMIT (1024 * 1024)
#define PASSPHRASE_LIMIT 4096

typedef struct {
    char *data;
    size_t size;
    size_t allocated;
} Secret;

static void secret_clear(Secret *secret)
{
    if (secret->data)
        explicit_bzero(secret->data, secret->allocated);
    g_free(secret->data);
}

G_DEFINE_AUTO_CLEANUP_CLEAR_FUNC(Secret, secret_clear)

/* Passphrase pipes have exactly one writer and close at the end of the
 * credential. Keyfiles are read as binary, including embedded NUL bytes. */
static gboolean read_secret(Secret *secret, int pipe_fd, const char *path)
{
    auto_fd file = -1;
    size_t limit = PASSPHRASE_LIMIT;
    if (*path) {
        file = open_path(path, O_RDONLY | O_NONBLOCK);
        struct stat st;
        if (file < 0 || fstat(file, &st) || !S_ISREG(st.st_mode) ||
            st.st_size <= 0 || st.st_size > KEYFILE_LIMIT)
            return FALSE;
        limit = st.st_size;
        pipe_fd = file;
    }
    secret->allocated = limit + 1;
    secret->data = g_malloc(secret->allocated);
    while (secret->size <= limit) {
        ssize_t count = TEMP_FAILURE_RETRY(read(pipe_fd, secret->data + secret->size,
            secret->allocated - secret->size));
        if (count < 0)
            return FALSE;
        if (!count)
            return secret->size && (file < 0 || secret->size == limit);
        secret->size += count;
    }
    return FALSE;
}

static gboolean usable_slot(struct crypt_device *cd, int slot)
{
    crypt_keyslot_info state = crypt_keyslot_status(cd, slot);
    return state == CRYPT_SLOT_ACTIVE || state == CRYPT_SLOT_ACTIVE_LAST;
}

static gboolean token_bound(struct crypt_device *cd, int slot)
{
    for (int token = 0; token < crypt_token_max(crypt_get_type(cd)); token++) {
        if (crypt_token_is_assigned(cd, token, slot) != -ENOENT)
            return TRUE;
    }
    return FALSE;
}

static void list_slots(const Header *header, const char *identity)
{
    struct crypt_device *cd = header->cd;
    const char *type = crypt_get_type(cd);
    int slots = crypt_keyslot_max(type);
    printf("%s\n%s\n", header->description, identity);
    for (int slot = 0; slot < slots; slot++) {
        crypt_keyslot_info status = crypt_keyslot_status(cd, slot);
        const char *state = usable_slot(cd, slot) ? "active" :
            status == CRYPT_SLOT_INACTIVE ? "inactive" :
            status == CRYPT_SLOT_UNBOUND ? "unbound" : "unsupported";
        const char *priority = "unavailable";
        if (!strcmp(type, CRYPT_LUKS2) && usable_slot(cd, slot)) {
            switch (crypt_keyslot_get_priority(cd, slot)) {
                case CRYPT_SLOT_PRIORITY_IGNORE: priority = "ignore"; break;
                case CRYPT_SLOT_PRIORITY_NORMAL: priority = "normal"; break;
                case CRYPT_SLOT_PRIORITY_PREFER: priority = "prefer"; break;
                default: break;
            }
        }
        printf("slot %d %s %s %d\n", slot, state, priority, token_bound(cd, slot));
    }
    for (int token = 0; token < crypt_token_max(type); token++) {
        const char *name = NULL;
        crypt_token_info status = crypt_token_status(cd, token, &name);
        if (status == CRYPT_TOKEN_INVALID || status == CRYPT_TOKEN_INACTIVE)
            continue;
        /* Treat token types as untrusted metadata and never emit token JSON. */
        g_autofree char *label = g_strndup(name ? name : "", 128);
        g_strcanon(label, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-", '?');
        gboolean known = status == CRYPT_TOKEN_INTERNAL || !strcmp(label, "systemd-tpm2") ||
            !strcmp(label, "systemd-fido2") || !strcmp(label, "systemd-pkcs11") || !strcmp(label, "clevis");
        printf("token %d %s %s", token, *label ? label : "unknown", known ? "recognised" : "unsupported");
        for (int slot = 0; slot < slots; slot++) {
            if (!crypt_token_is_assigned(cd, token, slot))
                printf(" %d", slot);
        }
        putchar('\n');
    }
}

static int verify_secret(struct crypt_device *cd, int slot, const Secret *secret)
{
    return crypt_activate_by_passphrase(cd, NULL, slot, secret->data, secret->size, 0);
}

static int commit_slots(int snapshot, const Header *live, const char *before,
    int removed, int remaining, const Secret *secret, const gboolean *slots)
{
    g_autofree char *staged = checksum(snapshot, live->extent);
    g_autofree char *current = checksum(DEVICE, live->extent);
    if (!staged || g_strcmp0(current, before))
        return 2;
    puts("phase:staged");
    if (puts("phase:write-keyslots") == EOF || fflush(stdout))
        return 2;
    if (!transfer(snapshot, DEVICE, live->extent, NULL) || fsync(DEVICE))
        return 3;
    puts("phase:verify-keyslots");
    auto_fd readback = memfd_create("majoris-luks-readback", MFD_CLOEXEC);
    g_auto(Header) verified = {0};
    struct stat st;
    if (readback < 0 || fstat(snapshot, &st) || ftruncate(readback, st.st_size) ||
        !transfer(DEVICE, readback, live->extent, NULL))
        return 3;
    g_autofree char *written = checksum(readback, live->extent);
    if (g_strcmp0(written, staged) || load_header(readback, &verified) != 1 ||
        strcmp(verified.description, live->description) || verified.extent != live->extent ||
        verify_secret(verified.cd, remaining, secret) != remaining)
        return 3;
    if (removed >= 0 && crypt_keyslot_status(verified.cd, removed) != CRYPT_SLOT_INACTIVE)
        return 3;
    for (int slot = 0; slot < crypt_keyslot_max(crypt_get_type(verified.cd)); slot++) {
        if (slot != removed && slots[slot] && !usable_slot(verified.cd, slot))
            return 3;
    }
    return 0;
}

static int modify_slots(int snapshot, Header *live, const char *operation, const char *selection,
    const char *before, const char *first_file, const char *second_file)
{
    struct crypt_device *cd = live->cd;
    const char *type = crypt_get_type(cd);
    int count = crypt_keyslot_max(type);
    gboolean replace = !strcmp(operation, "change-keyslot");
    gboolean remove = !strcmp(operation, "remove-keyslot");
    gboolean add = !replace && !remove;
    int selected, retained;
    char suffix;
    if (sscanf(selection, "%d:%d%c", &selected, &retained, &suffix) != 2 ||
        selected < CRYPT_ANY_SLOT || selected >= count || retained < CRYPT_ANY_SLOT || retained >= count ||
        (!add && (selected < 0 || !usable_slot(cd, selected) || token_bound(cd, selected))) ||
        (remove && (retained < 0 || retained == selected || !usable_slot(cd, retained) ||
         (!strcmp(type, CRYPT_LUKS2) && crypt_keyslot_get_priority(cd, retained) == CRYPT_SLOT_PRIORITY_IGNORE))))
        return fail(2, "Choose eligible keyslots. Token-associated slots require their own management tools.");

    g_autofree gboolean *active = g_new(gboolean, count);
    int free_slot = -1;
    for (int slot = 0; slot < count; slot++) {
        active[slot] = usable_slot(cd, slot);
        if (free_slot < 0 && crypt_keyslot_status(cd, slot) == CRYPT_SLOT_INACTIVE)
            free_slot = slot;
    }
    if (!remove && free_slot < 0)
        return fail(2, "A free keyslot is required to verify a new credential before replacing an existing one.");
    g_auto(Secret) current = {0}, other = {0};
    if (!read_secret(&current, 4, first_file) || !read_secret(&other, 5, second_file))
        return fail(2, "A credential was missing, unreadable or exceeded the supported size.");
    if (!remove && current.size == other.size && !memcmp(current.data, other.data, current.size))
        return fail(2, "Choose a new credential different from the current credential.");
    int authorizing = verify_secret(cd, selected, &current);
    if (authorizing < 0 || !usable_slot(cd, authorizing))
        return fail(2, "The current credential did not unlock the requested keyslot.");

    g_autofree char *after_add = NULL;
    if (!remove) {
        int new_slot = crypt_keyslot_add_by_passphrase(cd, free_slot, current.data, current.size,
            other.data, other.size);
        if (new_slot != free_slot || verify_secret(cd, new_slot, &other) != new_slot)
            return fail(2, "The new credential could not be staged and verified. The device was not written.");
        if (replace && !strcmp(type, CRYPT_LUKS2)) {
            crypt_keyslot_priority priority = crypt_keyslot_get_priority(cd, selected);
            if (priority == CRYPT_SLOT_PRIORITY_INVALID || crypt_keyslot_set_priority(cd, new_slot, priority) < 0)
                return fail(2, "The replacement keyslot priority could not be preserved.");
        }
        after_add = checksum(snapshot, live->extent);
        int result = after_add ? commit_slots(snapshot, live, before, -1, new_slot, &other, active) : 2;
        if (result)
            return fail(result, result == 2 ? "The live header changed before writing." :
                "The new credential write was attempted but could not be verified. Refresh the keyslots.");
        if (!replace) {
            printf("Added and verified keyslot %d.\n", new_slot);
            return 0;
        }
        active[new_slot] = TRUE;
        retained = new_slot;
    } else if (verify_secret(cd, retained, &other) != retained) {
        return fail(2, "The remaining credential must unlock a different active keyslot.");
    }

    if (crypt_keyslot_destroy(cd, selected) < 0 || verify_secret(cd, retained, &other) != retained)
        return fail(replace ? 3 : 2, replace ?
            "The new credential was verified on disk. Removing the original could not be staged." :
            "Removal could not be staged while preserving the remaining credential.");
    int result = commit_slots(snapshot, live, replace ? after_add : before, selected, retained, &other, active);
    if (result)
        return fail(replace ? 3 : result, result == 2 ?
            "The live header changed before removal. Refresh the keyslots." :
            "A removal write was attempted but could not be verified. Refresh the keyslots.");
    printf("Removed keyslot %d and verified remaining keyslot %d.\n", selected, retained);
    return 0;
}

int main(int argc, char **argv)
{
    umask(077);
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IOLBF, 0);
    crypt_set_log_callback(NULL, quiet, NULL);
    crypt_token_external_disable();
    if (argc != 7 && argc != 9)
        return fail(2, "Invalid header worker request.");
    const char *operation = argv[1], *path = argv[2];
    const char *expected = argv[4], *expected_uuid = argv[5];
    gboolean advanced = !strcmp(argv[6], "advanced");
    gboolean restore = !strcmp(operation, "restore");
    gboolean inspect = !strcmp(operation, "inspect");
    gboolean backup = !strcmp(operation, "backup");
    gboolean preview = !strcmp(operation, "preview");
    gboolean slots = !strcmp(operation, "list-keyslots");
    gboolean mutation = !strcmp(operation, "add-keyslot") || !strcmp(operation, "change-keyslot") ||
        !strcmp(operation, "remove-keyslot");
    gboolean identify = !strcmp(operation, "identify-keyslot");
    if (!(restore || inspect || backup || preview || slots || mutation || identify) ||
        ((mutation || identify) ? argc != 9 : argc != 7) || ((slots || mutation || identify) && advanced))
        return fail(2, "Unsupported header worker operation.");
    struct stat device;
    guint64 capacity, sequence;
    unsigned logical_sector;
    if (fstat(DEVICE, &device) || !S_ISBLK(device.st_mode) ||
        ioctl(DEVICE, BLKGETSIZE64, &capacity) || ioctl(DEVICE, BLKGETDISKSEQ, &sequence) ||
        ioctl(DEVICE, BLKSSZGET, &logical_sector) || !logical_sector ||
        !sequence || capacity > G_MAXINT64 || capacity < 4096)
        return fail(2, "The block device size or kernel identity could not be verified.");

    g_autofree char *binding = portable_binding(argv[3]);
    if (!valid_binding(binding))
        return fail(2, "Invalid device binding.");
    guint64 scanned = MIN(capacity, LIMIT);
    auto_fd snapshot = memfd_create("majoris-luks-device", MFD_CLOEXEC);
    if (snapshot < 0 || ftruncate(snapshot, capacity) || !transfer(DEVICE, snapshot, scanned, NULL))
        return fail(2, "The device metadata could not be read.");
    g_auto(Header) live = {0};
    int state = load_header(snapshot, &live);
    if (state < 0 || ((backup || inspect || !advanced) && state != 1) ||
        (state == 1 && live.offset >= capacity))
        return fail(2, "The device does not have a supported attached LUKS1 or LUKS2 layout.");
    if (*expected_uuid && state == 1) {
        g_auto(GStrv) fields = g_strsplit(live.description, " ", 3);
        if (g_ascii_strcasecmp(fields[1], expected_uuid))
            return fail(2, "The live LUKS UUID does not match the selected volume.");
    }

    guint64 checked = state == 1 ? live.extent : 0;
    g_autofree char *observed = checksum(snapshot, checked);
    if (!observed)
        return fail(2, "The device metadata fingerprint could not be calculated.");
    g_autofree char *identity = g_strdup_printf("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%s",
        sequence, capacity, observed);
    if (slots) {
        list_slots(&live, identity);
        return 0;
    }
    if (identify || mutation) {
        if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0))
            return fail(2, "Could not protect the credential worker from process dumps.");
        int flags = fcntl(DEVICE, F_GETFL);
        if (flags < 0 || (mutation && (flags & O_ACCMODE) != O_RDWR) || strcmp(identity, expected))
            return fail(2, "The selected device or keyslots changed after confirmation.");
        if (identify) {
            g_auto(Secret) credential = {0};
            if (!read_secret(&credential, 4, argv[7]))
                return fail(2, "The credential was missing, unreadable or exceeded the supported size.");
            int slot = verify_secret(live.cd, CRYPT_ANY_SLOT, &credential);
            if (slot < 0 || !usable_slot(live.cd, slot))
                return fail(2, "The credential did not unlock an active keyslot with normal unlocking priority.");
            printf("The credential unlocked keyslot %d.\n", slot);
            return 0;
        }
        return modify_slots(snapshot, &live, operation, path, observed, argv[7], argv[8]);
    }
    if (inspect) {
        printf("%s\n%s\n", live.description, identity);
        return 0;
    }
    if (backup) {
        if (strcmp(identity, expected))
            return fail(2, "The selected device or its header changed after confirmation.");
        return create_backup(path, binding, &live, snapshot, capacity, logical_sector);
    }

    g_autofree char *parent = g_path_get_dirname(path);
    g_autofree char *name = g_path_get_basename(path);
    g_autofree char *manifest_name = g_strconcat(name, MANIFEST_SUFFIX, NULL);
    auto_fd directory = open_path(parent, O_DIRECTORY | O_RDONLY);
    auto_fd input = directory < 0 ? -1 :
        openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (input < 0 || fstat(input, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > LIMIT)
        return fail(2, "Select a complete local LUKS backup file without symbolic links.");
    auto_fd sealed = memfd_create("majoris-luks-backup", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (sealed < 0 || !transfer(input, sealed, st.st_size, NULL) ||
        fcntl(sealed, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL))
        return fail(2, "The backup file could not be safely read.");
    g_auto(Header) saved = {0};
    if (load_header(sealed, &saved) != 1 || !backup_size(&saved, st.st_size) ||
        saved.offset >= capacity || saved.sector < logical_sector ||
        capacity - saved.offset < saved.sector || saved.extent > scanned)
        return fail(2, "The backup is invalid, incomplete, unsupported or too large for the target.");
    if (state == 1 && (strcmp(live.description, saved.description) || live.extent != saved.extent))
        return fail(2, "The backup does not match the live LUKS UUID, layout or volume-key digest.");
    g_autofree char *backup_hash = checksum(sealed, st.st_size);
    if (!backup_hash)
        return fail(2, "The backup could not be checksummed.");
    char saved_hash[65] = {0};
    ssize_t hash_size = fgetxattr(input, CHECKSUM, saved_hash, sizeof saved_hash);
    if ((hash_size >= 0 && (hash_size != 64 || strcmp(saved_hash, backup_hash))) ||
        (hash_size < 0 && errno != ENODATA && errno != ENOTSUP))
        return fail(2, "The backup does not match its saved integrity checksum.");
    char saved_size[32] = {0};
    ssize_t size_length = fgetxattr(input, SOURCE_SIZE, saved_size, sizeof saved_size);
    g_autofree char *actual_size = g_strdup_printf("%" G_GUINT64_FORMAT, capacity);
    if ((size_length >= 0 && (size_length != (ssize_t) strlen(actual_size) ||
            memcmp(saved_size, actual_size, size_length))) ||
        (size_length < 0 && errno != ENODATA && errno != ENOTSUP))
        return fail(2, "The target capacity does not match the original device size.");
    g_autofree char *manifest_hash = NULL;
    int provenance = read_manifest(directory, manifest_name, &saved, backup_hash,
        binding, capacity, logical_sector, &manifest_hash);
    if (provenance < 0)
        return fail(2, "The companion manifest is invalid or incompatible with the backup and target.");
    if (!state && has_other_signature(DEVICE, capacity))
        return fail(2, "The unreadable target contains a conflicting storage signature or could not be probed.");
    if (!state) {
        checked = saved.extent;
        g_free(observed);
        observed = checksum(snapshot, checked);
        if (!observed)
            return fail(2, "The damaged metadata could not be checksummed.");
        g_free(identity);
        identity = g_strdup_printf("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%s",
            sequence, capacity, observed);
    }
    const char *confidence = state ? "readable" : provenance == 2 ? "device-identity" : "unestablished";
    g_autofree char *ticket = g_strdup_printf("%s:%s:%s:%s", identity, backup_hash,
        manifest_hash ? manifest_hash : "-", confidence);
    if (preview) {
        printf("%s\n%s\n%s\n%s\n%" G_GINT64_FORMAT "\n", saved.description, ticket,
            confidence, provenance || hash_size == 64 ? "checksummed" : "structure-only",
            (gint64) st.st_size);
        return 0;
    }
    if (!state && provenance != 2)
        return fail(2, "The backup cannot be linked to this unreadable target. Use offline expert recovery.");
    if (strcmp(ticket, expected))
        return fail(2, "The target or backup changed after confirmation.");

    /* Stage the libcryptsetup restore first. Only its verified metadata range
     * is committed through the original exclusive descriptor. */
    g_autofree char *backup_path = fd_path(sealed);
    g_autofree char *snapshot_path = fd_path(snapshot);
    g_auto(Header) restored = {0};
    if (crypt_init(&restored.cd, snapshot_path) < 0 ||
        crypt_header_restore(restored.cd, crypt_get_type(saved.cd), backup_path) < 0)
        return fail(2, "Libcryptsetup rejected the restore before any device write.");
    g_autofree char *staged = checksum(snapshot, saved.extent);
    g_autofree char *original_backup = checksum(sealed, saved.extent);
    g_autofree char *current = checksum(DEVICE, checked);
    if (!staged || g_strcmp0(staged, original_backup) || !current ||
        strcmp(current, observed))
        return fail(2, "The staged header or the current target failed verification before writing.");
    puts("phase:staged");
    if (puts("phase:write-header") == EOF || fflush(stdout))
        return fail(2, "Could not report write initiation. The target was not modified.");
    if (!transfer(snapshot, DEVICE, saved.extent, NULL) || fsync(DEVICE))
        return fail(3, "A header write was attempted and could not be synchronized. The target may be partially modified.");
    puts("phase:verify-restore");
    g_autofree char *written = checksum(DEVICE, saved.extent);
    if (g_strcmp0(written, staged))
        return fail(3, "The header write was attempted, but the device readback differs from the verified backup.");
    printf("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%s\n", sequence, capacity, written);
    return 0;
}
