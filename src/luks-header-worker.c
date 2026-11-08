/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <blkid/blkid.h>
#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <libcryptsetup.h>
#include <linux/fs.h>
#include <linux/openat2.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

/* The worker is unprivileged. FD 3 is the UDisks-authorized block descriptor.
 * Cryptsetup operates on private regular files, never on a reopened device path. */
#define DEVICE 3
#define LIMIT (136 * 1024 * 1024)
#define PROOF "user.majoris.luks-source"
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

/* The xattr is a portable-with-xattrs association, not an authentication
 * secret. Match both the device binding and independently sampled ciphertext. */
static char *source_proof(const char *binding, const char *backup_hash,
    const Header *header, guint64 capacity)
{
    const size_t sample_size = 4096;
    guint64 span = capacity - header->offset;
    if (!*binding || span < 16 * sample_size || header->offset % sample_size)
        return NULL;
    g_autoptr(GChecksum) sum = g_checksum_new(G_CHECKSUM_SHA256);
    guint64 sequence;
    g_autofree char *boot = NULL;
    if (g_str_has_prefix(binding, "loop:") &&
        (ioctl(DEVICE, BLKGETDISKSEQ, &sequence) ||
         !g_file_get_contents("/proc/sys/kernel/random/boot_id", &boot, NULL, NULL)))
        return NULL;
    g_autofree char *prefix = g_strdup_printf("majoris-luks-v1:%s:%s:%" G_GUINT64_FORMAT
        ":%s:%" G_GUINT64_FORMAT, binding, backup_hash, capacity, boot ? boot : "", boot ? sequence : 0);
    g_checksum_update(sum, (const guchar *) prefix, strlen(prefix));
    guint8 *sample = NULL;
    if (posix_memalign((void **) &sample, sample_size, sample_size))
        return NULL;
    int flags = fcntl(DEVICE, F_GETFL);
    if (flags < 0 || fcntl(DEVICE, F_SETFL, flags | O_DIRECT)) {
        free(sample);
        return NULL;
    }
    guint varied = 0;
    gboolean readable = TRUE;
    guint64 last_block = (span - sample_size) / sample_size;
    for (guint i = 0; i < 8; i++) {
        guint64 offset = header->offset + (last_block * i / 7) * sample_size;
        if (!read_at(DEVICE, sample, sample_size, offset)) {
            readable = FALSE;
            break;
        }
        for (guint j = 1; j < sample_size; j++) {
            if (sample[j] != sample[0]) {
                varied++;
                break;
            }
        }
        g_checksum_update(sum, sample, sample_size);
    }
    free(sample);
    if (fcntl(DEVICE, F_SETFL, flags))
        return NULL;
    return readable && varied ? g_strdup(g_checksum_get_string(sum)) : NULL;
}

static int create_backup(const char *destination, const char *binding, const Header *source,
    int snapshot, guint64 capacity)
{
    g_autofree char *parent = g_path_get_dirname(destination);
    g_autofree char *name = g_path_get_basename(destination);
    auto_fd directory = open_path(parent, O_DIRECTORY | O_RDONLY);
    struct stat existing, original_directory;
    if (directory < 0 || fstat(directory, &original_directory) || !strcmp(name, ".") || !strcmp(name, ".."))
        return fail(2, "Choose a local backup directory without symbolic links.");
    if (fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
        return fail(2, "The backup destination already exists or cannot be checked.");
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
    g_autofree char *proof = source_proof(binding, actual, source, capacity);
    g_autofree char *size = g_strdup_printf("%" G_GUINT64_FORMAT, capacity);
    gboolean checksummed = fsetxattr(output, CHECKSUM, actual, strlen(actual), XATTR_CREATE) == 0;
    if (checksummed && fsetxattr(output, SOURCE_SIZE, size, strlen(size), XATTR_CREATE))
        return fail(2, "Could not record the original device capacity.");
    gboolean recovery = checksummed && proof && fsetxattr(output, PROOF, proof, strlen(proof), XATTR_CREATE) == 0;
    if (fsync(output))
        return fail(2, "Could not synchronize the verified backup file.");
    auto_fd current_directory = open_path(parent, O_DIRECTORY | O_RDONLY);
    if (current_directory < 0 || fstat(current_directory, &existing) ||
        original_directory.st_dev != existing.st_dev || original_directory.st_ino != existing.st_ino)
        return fail(2, "The backup directory changed before publishing the file.");
    g_autofree char *output_path = fd_path(output);
    if (linkat(AT_FDCWD, output_path, directory, name, AT_SYMLINK_FOLLOW))
        return fail(2, "Could not publish the verified backup without overwriting a file.");
    if (fsync(directory))
        return fail(3, "The verified file was published, but directory durability could not be confirmed.");
    puts(recovery ? "recovery" : checksummed ? "header-only" : "no-xattrs");
    return 0;
}

int main(int argc, char **argv)
{
    umask(077);
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IOLBF, 0);
    crypt_set_log_callback(NULL, quiet, NULL);
    if (argc != 7)
        return fail(2, "Invalid header worker request.");
    const char *operation = argv[1], *path = argv[2], *binding = argv[3];
    const char *expected = argv[4], *expected_uuid = argv[5];
    gboolean advanced = !strcmp(argv[6], "advanced");
    gboolean restore = !strcmp(operation, "restore");
    gboolean inspect = !strcmp(operation, "inspect");
    gboolean backup = !strcmp(operation, "backup");
    gboolean preview = !strcmp(operation, "preview");
    if (!(restore || inspect || backup || preview))
        return fail(2, "Unsupported header worker operation.");
    struct stat device;
    guint64 capacity, sequence;
    unsigned logical_sector;
    if (fstat(DEVICE, &device) || !S_ISBLK(device.st_mode) ||
        ioctl(DEVICE, BLKGETSIZE64, &capacity) || ioctl(DEVICE, BLKGETDISKSEQ, &sequence) ||
        ioctl(DEVICE, BLKSSZGET, &logical_sector) || !logical_sector ||
        !sequence || capacity > G_MAXINT64 || capacity < 4096)
        return fail(2, "The block device size or kernel identity could not be verified.");

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

    guint64 checked = state == 1 ? live.extent : scanned;
    g_autofree char *observed = checksum(snapshot, checked);
    if (!observed)
        return fail(2, "The device metadata fingerprint could not be calculated.");
    g_autofree char *identity = g_strdup_printf("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%s",
        sequence, capacity, observed);
    if (inspect) {
        printf("%s\n%s\n", live.description, identity);
        return 0;
    }
    if (backup) {
        if (strcmp(identity, expected))
            return fail(2, "The selected device or its header changed after confirmation.");
        return create_backup(path, binding, &live, snapshot, capacity);
    }

    auto_fd input = open_path(path, O_RDONLY | O_NONBLOCK);
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
    if (state == 0) {
        char proof[65] = {0};
        g_autofree char *actual = source_proof(binding, backup_hash, &saved, capacity);
        if (!actual || fgetxattr(input, PROOF, proof, sizeof proof) != 64 || strcmp(actual, proof) ||
            has_other_signature(DEVICE, capacity))
            return fail(2, "The unreadable target cannot be linked to this backup, or it contains another storage signature.");
    }
    g_autofree char *ticket = g_strdup_printf("%s:%s:%d:%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%" G_GINT64_FORMAT ":%ld",
        identity, backup_hash, state, (guint64) st.st_dev, (guint64) st.st_ino,
        (gint64) st.st_ctim.tv_sec, st.st_ctim.tv_nsec);
    if (preview) {
        printf("%s\n%s\n%s\n%s\n", saved.description, ticket,
            state ? "readable" : "damaged", hash_size == 64 ? "checksummed" : "structure-only");
        return 0;
    }
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
    puts("phase:write-header");
    if (!transfer(snapshot, DEVICE, saved.extent, NULL) || fsync(DEVICE))
        return fail(3, "A header write was attempted and could not be synchronized. The target may be partially modified.");
    puts("phase:verify-restore");
    g_autofree char *written = checksum(DEVICE, saved.extent);
    if (g_strcmp0(written, staged))
        return fail(3, "The header write was attempted, but the device readback differs from the verified backup.");
    return 0;
}
