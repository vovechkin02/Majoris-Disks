/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Included by the restricted helper after the mount and topology validators. */
#define SCRUB_PROGS "/usr/bin/btrfs"
#define SCRUB_UPSTREAM "/var/lib/btrfs"
#define SCRUB_STORE "/var/lib/majoris-disks-scrub"
#define SCRUB_MAX_MEMBERS 64
#define SCRUB_MAX_FILE (512 * 1024)
#define SCRUB_HISTORY 20

#define SCRUB_FIELDS(X) \
    X(data_extents_scrubbed) X(tree_extents_scrubbed) X(data_bytes_scrubbed) X(tree_bytes_scrubbed) \
    X(read_errors) X(csum_errors) X(verify_errors) X(no_csum) X(csum_discards) X(super_errors) \
    X(malloc_errors) X(uncorrectable_errors) X(corrected_errors)

typedef struct {
    struct btrfs_ioctl_dev_info_args info;
    struct btrfs_scrub_progress live, saved;
    struct btrfs_ioctl_get_dev_stats health;
    guint64 start, resumed, duration, cancelled, finished;
    gboolean running, recorded, unverified_known, health_known;
} ScrubMember;

static int
scrub_member_order (const void *a, const void *b)
{
    guint64 x = ((const ScrubMember *) a)->info.devid, y = ((const ScrubMember *) b)->info.devid;
    return (x > y) - (x < y);
}

static ScrubMember *
scrub_member (ScrubMember *members, guint count, guint64 id)
{
    for (guint i = 0; i < count; i++)
        if (members[i].info.devid == id) return &members[i];
    return NULL;
}

static gboolean
scrub_members (int fd, const char *uuid, ScrubMember *members, guint count)
{
    if (!verify_maintenance_topology (fd, uuid, count, FALSE))
        return FALSE;
    g_autofree char *path = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", uuid);
    g_autoptr(GDir) dir = g_dir_open (path, 0, NULL);
    if (dir == NULL) return FALSE;
    const char *name;
    guint n = 0;
    while ((name = g_dir_read_name (dir)) != NULL) {
        guint64 id;
        if (n == count || !g_ascii_string_to_unsigned (name, 10, 1, G_MAXUINT64, &id, NULL))
            return FALSE;
        ScrubMember *m = &members[n++];
        m->info.devid = id;
        if (ioctl (fd, BTRFS_IOC_DEV_INFO, &m->info) != 0 ||
            !memchr (m->info.path, 0, sizeof m->info.path))
            return FALSE;
        m->health.devid = id;
        m->health.nr_items = BTRFS_DEV_STAT_VALUES_MAX;
        m->health_known = ioctl (fd, BTRFS_IOC_GET_DEV_STATS, &m->health) == 0 &&
            m->health.nr_items == BTRFS_DEV_STAT_VALUES_MAX;
    }
    qsort (members, n, sizeof *members, scrub_member_order);
    return n == count;
}

static int
scrub_probe (int fd, ScrubMember *members, guint count)
{
    int running = 0;
    for (guint i = 0; i < count; i++) {
        struct btrfs_ioctl_scrub_args args = { .devid = members[i].info.devid };
        members[i].running = ioctl (fd, BTRFS_IOC_SCRUB_PROGRESS, &args) == 0;
        if (!members[i].running && errno != ENOTCONN) return -1;
        if (members[i].running) {
            members[i].live = args.progress;
            running++;
        }
    }
    return running;
}

static char *
scrub_fingerprint (const ScrubMember *members, guint count)
{
    g_autoptr(GString) fingerprint = g_string_new (NULL);
    for (guint i = 0; i < count; i++) {
        g_string_append_printf (fingerprint, "%" G_GUINT64_FORMAT ":", (guint64) members[i].info.devid);
        for (guint j = 0; j < sizeof members[i].info.uuid; j++)
            g_string_append_printf (fingerprint, "%02x", members[i].info.uuid[j]);
        g_string_append_c (fingerprint, ';');
    }
    return g_string_free (g_steal_pointer (&fingerprint), FALSE);
}

static char *
scrub_review_token (int fd, guint64 source, const char *uuid, const char *members)
{
    struct statx mount;
    if (statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE, &mount) != 0 ||
        !(mount.stx_mask & STATX_MNT_ID_UNIQUE)) return NULL;
    g_autofree char *identity = g_strdup_printf ("%s:%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%s",
        uuid, source, (guint64) mount.stx_mnt_id, members);
    return g_compute_checksum_for_string (G_CHECKSUM_SHA256, identity, -1);
}

static int
scrub_lock (const char *path, gboolean create)
{
    int fd = open (path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
    struct stat st;
    if (fd >= 0 && (fstat (fd, &st) != 0 || st.st_uid != 0 || !S_ISREG (st.st_mode) ||
                   (st.st_mode & 022) || st.st_nlink != 1)) {
        close (fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

static gboolean
scrub_directory (const char *path, gboolean create)
{
    if (create && mkdir (path, 0700) != 0 && errno != EEXIST) return FALSE;
    int fd __attribute__((cleanup(close_fd))) = open_directory (path);
    struct stat st;
    return fd >= 0 && fstat (fd, &st) == 0 && st.st_uid == 0 && !(st.st_mode & 022);
}

/* Return an empty string only for a missing file. Files must be regular,
 * root-owned, bounded and unmodifiable by unprivileged users. */
static char *
scrub_read_info (const char *directory, const char *name, struct stat *identity)
{
    int dir __attribute__((cleanup(close_fd))) = open_directory (directory);
    if (dir < 0) return errno == ENOENT ? g_strdup ("") : NULL;
    struct stat st;
    if (fstat (dir, &st) != 0 || st.st_uid != 0 || (st.st_mode & 022)) return NULL;
    int fd __attribute__((cleanup(close_fd))) = openat (dir, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? g_strdup ("") : NULL;
    if (fstat (fd, &st) != 0 || !S_ISREG (st.st_mode) || st.st_uid != 0 ||
        (st.st_mode & 022) || st.st_nlink != 1 || st.st_size <= 0 || st.st_size > SCRUB_MAX_FILE)
        return NULL;

    g_autofree char *data = g_malloc (st.st_size + 1);
    gsize size = 0;
    while (size < (gsize) st.st_size) {
        ssize_t n = read (fd, data + size, st.st_size - size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NULL;
        size += n;
    }
    char extra;
    if (read (fd, &extra, 1) != 0 || memchr (data, 0, size) || data[size - 1] != '\n')
        return NULL;
    data[size] = 0;
    if (identity) *identity = st;
    return g_steal_pointer (&data);
}

static char *
scrub_read (const char *directory, const char *name)
{
    return scrub_read_info (directory, name, NULL);
}

static char *
scrub_checkpoint_generation (const char *digest, const struct stat *identity)
{
    return digest ? g_strdup_printf ("%s:%" G_GUINT64_FORMAT ":%" G_GINT64_FORMAT ":%ld", digest,
        (guint64) identity->st_ino, (gint64) identity->st_ctim.tv_sec, identity->st_ctim.tv_nsec) : NULL;
}

static gboolean
scrub_load_state (const char *uuid, GKeyFile *state)
{
    g_autofree char *data = scrub_read (SCRUB_STORE, uuid);
    if (!data) return FALSE;
    if (!*data) return TRUE;
    if (!g_key_file_load_from_data (state, data, -1, G_KEY_FILE_NONE, NULL) ||
        g_key_file_get_integer (state, "format", "version", NULL) != 1) return FALSE;
    g_autofree char *stored_uuid = g_key_file_get_string (state, "format", "uuid", NULL);
    g_autofree char *checksum = g_key_file_get_string (state, "format", "checksum", NULL);
    if (!checksum || !g_str_equal (uuid, stored_uuid ? stored_uuid : "")) return FALSE;
    g_key_file_remove_key (state, "format", "checksum", NULL);
    g_autofree char *body = g_key_file_to_data (state, NULL, NULL);
    g_autofree char *expected = g_compute_checksum_for_string (G_CHECKSUM_SHA256, body, -1);
    return g_str_equal (checksum, expected);
}

static gboolean
scrub_store (const char *uuid, GKeyFile *state)
{
    g_autofree char *path = g_build_filename (SCRUB_STORE, uuid, NULL);
    g_key_file_set_string (state, "format", "uuid", uuid);
    g_key_file_remove_key (state, "format", "checksum", NULL);
    g_autofree char *body = g_key_file_to_data (state, NULL, NULL);
    g_autofree char *checksum = g_compute_checksum_for_string (G_CHECKSUM_SHA256, body, -1);
    g_key_file_set_string (state, "format", "checksum", checksum);
    gsize size;
    g_autofree char *data = g_key_file_to_data (state, &size, NULL);
    return size <= SCRUB_MAX_FILE && g_file_set_contents_full (path, data, size,
        G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, NULL);
}

/* btrfs-progs 6.14 checkpoint format. In particular the file does not carry
 * mode, device UUIDs, or unverified_errors. Never interpret it as live state. */
static gboolean
scrub_checkpoint (const char *data, const char *uuid, ScrubMember *members, guint count,
                  guint64 scope, guint64 start, guint64 attempt, gboolean resume)
{
    if (data == NULL || !g_str_has_prefix (data, "scrub status:1\n")) return FALSE;
    g_auto(GStrv) lines = g_strsplit (data, "\n", -1);
    guint seen = 0;
    guint64 now = g_get_real_time () / G_USEC_PER_SEC;
    for (guint i = 1; lines[i] && *lines[i]; i++) {
        g_auto(GStrv) fields = g_strsplit (lines[i], "|", -1);
        g_auto(GStrv) device = g_strsplit (fields[0], ":", 2);
        guint64 id;
        if (!g_str_equal (device[0], uuid) || !device[1] ||
            !g_ascii_string_to_unsigned (device[1], 10, 1, G_MAXUINT64, &id, NULL) ||
            (scope != 0 && scope != id)) return FALSE;
        ScrubMember *m = scrub_member (members, count, id);
        if (!m || m->recorded) return FALSE;
        guint64 value;
        guint index = 1;
#define FIELD(name, target) do { \
    const char *field = fields[index++]; \
    if (!field || !g_str_has_prefix (field, #name ":") || \
        !g_ascii_string_to_unsigned (field + sizeof (#name), 10, 0, G_MAXUINT64, &value, NULL)) \
        return FALSE; \
    target = value; \
} while (0)
#define PROGRESS(name) FIELD(name, m->saved.name);
        SCRUB_FIELDS (PROGRESS)
        PROGRESS (last_physical)
#undef PROGRESS
        FIELD (t_start, m->start);
        FIELD (t_resumed, m->resumed);
        FIELD (duration, m->duration);
        FIELD (canceled, m->cancelled);
        FIELD (finished, m->finished);
#undef FIELD
        if (fields[index] || m->start < start || m->start - start > 10 || m->start > now ||
            m->cancelled > 1 || m->finished > 1 || m->saved.last_physical > m->info.total_bytes ||
            (m->resumed && (m->resumed < m->start || m->resumed > now)) ||
            (!resume && m->resumed) || (resume && m->resumed >= attempt && m->resumed - attempt > 10))
            return FALSE;
        m->recorded = TRUE;
        seen++;
    }
    return seen == (scope ? 1 : count) && g_strv_length (lines) == seen + 2;
}

static gboolean
scrub_selected_block (int fd, const char *uuid, const ScrubMember *member)
{
    struct stat st;
    if (fstat (fd, &st) != 0 || !S_ISBLK (st.st_mode) || !filesystem_member (uuid, st.st_rdev))
        return FALSE;

    blkid_probe probe = blkid_new_probe ();
    if (!probe) return FALSE;
    const char *fsid = NULL, *sub = NULL;
    char device_uuid[37];
    const guint8 *u = member->info.uuid;
    g_snprintf (device_uuid, sizeof device_uuid,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9],
        u[10], u[11], u[12], u[13], u[14], u[15]);
    gboolean matches = blkid_probe_set_device (probe, fd, 0, 0) == 0 &&
        blkid_probe_enable_superblocks (probe, 1) == 0 &&
        blkid_probe_set_superblocks_flags (probe, BLKID_SUBLKS_UUID) == 0 &&
        blkid_do_safeprobe (probe) == 0 &&
        blkid_probe_lookup_value (probe, "UUID", &fsid, NULL) == 0 &&
        blkid_probe_lookup_value (probe, "UUID_SUB", &sub, NULL) == 0 &&
        g_ascii_strcasecmp (uuid, fsid) == 0 && g_ascii_strcasecmp (device_uuid, sub) == 0;
    blkid_free_probe (probe);
    return matches;
}

static gboolean
scrub_backend_supported (void)
{
    const char *args[] = { SCRUB_PROGS, "version", NULL };
    const char *env[] = { "LC_ALL=C", "PATH=/usr/bin:/usr/sbin", NULL };
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new (
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
    g_subprocess_launcher_set_environ (launcher, (char **) env);
    g_autoptr(GSubprocess) process = g_subprocess_launcher_spawnv (launcher, args, NULL);
    g_autofree char *output = NULL;
    const char prefix[] = "btrfs-progs v6.14";
    return process && g_subprocess_communicate_utf8 (process, NULL, NULL, &output, NULL, NULL) &&
        g_subprocess_get_successful (process) && g_str_has_prefix (output, prefix) &&
        strchr (".-\n", output[sizeof prefix - 1]) != NULL;
}

static gboolean
scrub_repair_safe (int fd, const char *uuid, ScrubMember *members, guint count)
{
    g_autofree char *zoned = g_strdup_printf ("/sys/fs/btrfs/%s/features/zoned", uuid);
    struct statvfs mount;
    if (access (zoned, F_OK) == 0 || errno != ENOENT) return FALSE;
    if (fstatvfs (fd, &mount) != 0 || (mount.f_flag & ST_RDONLY)) return FALSE;
    for (guint i = 0; i < count; i++) {
        int block __attribute__((cleanup(close_fd))) = open ((char *) members[i].info.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        int read_only = 1;
        if (!members[i].health_known || block < 0 || ioctl (block, BLKROGET, &read_only) != 0 || read_only)
            return FALSE;
        /* A persistent write or flush failure calls for device diagnosis. Read
         * and corruption counters can describe the damage scrub is checking. */
        if (members[i].health.values[BTRFS_DEV_STAT_WRITE_ERRS] ||
            members[i].health.values[BTRFS_DEV_STAT_FLUSH_ERRS]) return FALSE;
    }
    g_autofree struct btrfs_ioctl_space_args *space = majoris_btrfs_query_spaces (fd);
    if (!space || !space->total_spaces) return FALSE;
    const guint64 types = BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA | BTRFS_BLOCK_GROUP_SYSTEM;
    const guint64 profiles = BTRFS_BLOCK_GROUP_RAID0 | BTRFS_BLOCK_GROUP_RAID1 | BTRFS_BLOCK_GROUP_DUP |
        BTRFS_BLOCK_GROUP_RAID10 | BTRFS_BLOCK_GROUP_RAID1C3 | BTRFS_BLOCK_GROUP_RAID1C4;
    guint64 seen = 0;
    for (guint64 i = 0; i < space->total_spaces; i++) {
        guint64 flags = space->spaces[i].flags;
        if (!flags && i == space->total_spaces - 1) continue;
        if (flags == BTRFS_SPACE_INFO_GLOBAL_RSV) continue;
        if (!(flags & types) || (flags & ~(types | profiles))) return FALSE;
        seen |= flags & types;
    }
    return seen == types;
}

static void
scrub_final_unverified (const char *output, ScrubMember *members, guint count)
{
    if (!output) return;
    g_auto(GStrv) lines = g_strsplit (output, "\n", -1);
    ScrubMember *m = NULL;
    for (guint i = 0; lines[i]; i++) {
        if (g_str_has_prefix (lines[i], "Scrub device ")) {
            const char *id = g_strrstr (lines[i], " (id ");
            const char *end = id ? strchr (id + 5, ')') : NULL;
            g_autofree char *number = end ? g_strndup (id + 5, end - id - 5) : NULL;
            guint64 parsed;
            m = number && g_ascii_string_to_unsigned (number, 10, 1, G_MAXUINT64, &parsed, NULL) ?
                scrub_member (members, count, parsed) : NULL;
        } else if (m && g_str_has_prefix (lines[i], "\tunverified_errors: ")) {
            guint64 n;
            if (g_ascii_string_to_unsigned (lines[i] + strlen ("\tunverified_errors: "),
                    10, 0, G_MAXUINT64, &n, NULL)) {
                m->saved.unverified_errors = n;
                m->unverified_known = TRUE;
            }
        }
    }
}

static char *
scrub_report (const char *state, const char *mode, guint64 start, guint64 scope,
              gboolean resumable, gboolean repair, gboolean records, ScrubMember *members, guint count)
{
    g_autoptr(GString) report = g_string_new (NULL);
    g_string_append_printf (report, "%s %s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %d %d\n",
        state, mode, start, scope, resumable, repair);
    for (guint i = 0; i < count; i++) {
        ScrubMember *m = &members[i];
        gboolean saved = records && m->recorded;
        const struct btrfs_scrub_progress *p = m->running ? &m->live : saved ? &m->saved : NULL;
        g_autofree char *path = g_uri_escape_string ((char *) m->info.path, NULL, FALSE);
        g_string_append_printf (report, "device %" G_GUINT64_FORMAT " %s %s %" G_GUINT64_FORMAT,
            (guint64) m->info.devid, path, m->running ? "running" :
            !saved ? "unavailable" : m->cancelled ? "interrupted" : m->finished ? "finished" : "interrupted",
            saved ? m->duration : 0);
#define COUNTER(name) \
        if (p) g_string_append_printf (report, " %" G_GUINT64_FORMAT, (guint64) p->name); \
        else g_string_append (report, " -");
        SCRUB_FIELDS (COUNTER)
        if (m->running || (saved && m->unverified_known)) {
            COUNTER (unverified_errors)
        } else g_string_append (report, " -");
#undef COUNTER
        for (guint j = 0; j < BTRFS_DEV_STAT_VALUES_MAX; j++) {
            if (m->health_known) g_string_append_printf (report, " %" G_GUINT64_FORMAT,
                (guint64) m->health.values[j]);
            else g_string_append (report, " -");
        }
        g_string_append_c (report, '\n');
    }
    return g_string_free (g_steal_pointer (&report), FALSE);
}

static gboolean
scrub_history_add (GKeyFile *state, const char *report)
{
    gsize count = 0;
    g_auto(GStrv) history = g_key_file_get_string_list (state, "history", "reports", &count, NULL);
    if (count && g_str_equal (history[0], report)) return FALSE;
    const char *entries[SCRUB_HISTORY] = { report };
    gsize bytes = strlen (report);
    gsize retained = 1;
    for (gsize i = 0; i < count && retained < SCRUB_HISTORY; i++) {
        gsize size = strlen (history[i]);
        if (bytes + size > SCRUB_MAX_FILE / 2) break;
        entries[retained++] = history[i];
        bytes += size;
    }
    g_key_file_set_string_list (state, "history", "reports", entries, retained);
    return TRUE;
}

static void
scrub_print_status (const char *report, const char *token, gboolean supported)
{
    g_print ("%sreview %s %d\n", report, token ? token : "-", supported);
}

static void
scrub_detach (gpointer unused)
{
    (void) unused;
    if (setsid () < 0) _exit (1);
    struct sigaction ignore = { .sa_handler = SIG_IGN };
    sigemptyset (&ignore.sa_mask);
    sigaction (SIGPIPE, &ignore, NULL);
}

/* pkexec can bind the authorized process to its caller's lifetime. The
 * supervisor has its own session and owns result persistence and the lock.
 * The caller's pipe is only a convenience for returning the saved result. */
static int
scrub_supervise (char **argv)
{
    const char *arguments[9] = { "/proc/self/exe" };
    for (guint i = 1; argv[i]; i++) arguments[i] = argv[i];
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new (
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
    g_subprocess_launcher_setenv (launcher, "MAJORIS_SCRUB_SUPERVISOR", "1", TRUE);
    g_subprocess_launcher_set_child_setup (launcher, scrub_detach, NULL, NULL);
    g_autoptr(GError) error = NULL;
    g_autoptr(GSubprocess) supervisor = g_subprocess_launcher_spawnv (launcher, arguments, &error);
    if (!supervisor) return fail (error->message);
    g_autofree char *output = NULL;
    g_autofree char *diagnostic = NULL;
    if (!g_subprocess_communicate_utf8 (supervisor, NULL, NULL, &output, &diagnostic, &error))
        return fail (error->message);
    if (output && *output) g_print ("%s", output);
    if (diagnostic && *diagnostic) g_printerr ("%s", diagnostic);
    return g_subprocess_get_if_exited (supervisor) ? g_subprocess_get_exit_status (supervisor) : 1;
}

static int
run_scrub (int fd, guint64 source, int argc, char **argv)
{
    const char *action = argv[1];
    gboolean status = g_str_equal (action, "scrub-status");
    gboolean history = g_str_equal (action, "scrub-history");
    gboolean cancel = g_str_equal (action, "scrub-cancel");
    gboolean resume = g_str_equal (action, "scrub-resume");
    gboolean repair = g_str_equal (action, "scrub-repair");
    gboolean readonly = g_str_equal (action, "scrub-readonly");
    guint64 size, scope = 0;
    gboolean start_request = repair || readonly;
    int review_arg = start_request ? 7 : 6;
    gboolean reviewed = argc == review_arg + 1;
    if ((!status && !history && !cancel && !resume && !start_request) ||
        ((status || history) && argc != 6) ||
        (start_request && argc >= 7 &&
         !g_ascii_string_to_unsigned (argv[6], 10, 0, G_MAXUINT64, &scope, NULL)) ||
        (!start_request && argc > 7) ||
        (!status && !history && g_getenv ("PKEXEC_UID") && !reviewed) ||
        !g_ascii_string_to_unsigned (argv[5], 10, 1, SCRUB_MAX_MEMBERS, &size, NULL))
        return fail ("Invalid Btrfs scrub request.");
    if ((start_request || resume) && g_strcmp0 (g_getenv ("MAJORIS_SCRUB_SUPERVISOR"), "1") != 0)
        return scrub_supervise (argv);
    guint count = size;
    g_autofree char *uuid = g_ascii_strdown (argv[3], -1);
    g_autofree ScrubMember *members = g_new0 (ScrubMember, count);
    if (!scrub_members (fd, uuid, members, count)) return fail ("Could not verify the Btrfs scrub member set.");
    g_autofree char *identity = scrub_fingerprint (members, count);
    g_autofree char *review = scrub_review_token (fd, source, uuid, identity);
    if (reviewed && g_strcmp0 (review, argv[review_arg]) != 0)
        return fail ("The scrub mount or member set changed after review.");
    g_autofree char *lock_path = g_strdup_printf ("/run/majoris-btrfs-%s.lock", uuid);
    int lock __attribute__((cleanup(close_fd))) = scrub_lock (lock_path, !(status || history));
    if (lock < 0 && (errno != ENOENT || !(status || history)))
        return fail ("Could not verify the Btrfs scrub lock.");
    gboolean locked = lock >= 0 && flock (lock, LOCK_EX | LOCK_NB) == 0;
    if (locked && (status || history)) flock (lock, LOCK_UN);
    if (!locked && !(status || history || cancel)) return fail ("Btrfs maintenance is already active.");

    g_autofree char *cancel_lock_path = g_strdup_printf ("/run/majoris-btrfs-%s.scrub-cancel", uuid);
    int cancel_lock __attribute__((cleanup(close_fd))) = -1;
    if (!status && !history) {
        cancel_lock = scrub_lock (cancel_lock_path, TRUE);
        if (cancel_lock < 0 || flock (cancel_lock, LOCK_EX | LOCK_NB) != 0)
            return fail ("Another scrub control request is in progress.");
    }
    g_autofree char *cancel_name = g_strdup_printf ("%s.cancelled", uuid);

    g_autoptr(GKeyFile) state = g_key_file_new ();
    if (!scrub_load_state (uuid, state))
        return fail ("Could not verify the saved Btrfs scrub history.");
    g_autofree char *stored_identity = g_key_file_get_string (state, "session", "members", NULL);
    gboolean owned = g_strcmp0 (identity, stored_identity) == 0;
    if (stored_identity && !owned) g_key_file_remove_group (state, "history", NULL);

    int running = scrub_probe (fd, members, count);
    if (running < 0) return fail ("Could not verify the kernel scrub state.");
    gboolean protected = system_filesystem (uuid);
    g_autofree char *session_id = g_key_file_get_string (state, "session", "id", NULL);
    if (cancel) {
        if (protected || !running || !quota_mount_current (fd, argv[2], source, uuid) ||
            ioctl (fd, BTRFS_IOC_SCRUB_CANCEL) != 0)
            return fail ("The kernel did not accept scrub cancellation. Refresh to check whether the scrub completed.");
        for (guint i = 0; i < 100; i++) {
            running = scrub_probe (fd, members, count);
            if (running <= 0) break;
            g_usleep (100 * 1000);
        }
        if (running != 0)
            return fail ("Cancellation was accepted but the kernel stop could not be verified.");
        if (owned && !locked && session_id && g_uuid_string_is_valid (session_id)) {
            g_autofree char *path = g_build_filename (SCRUB_STORE, cancel_name, NULL);
            g_autofree char *ack = g_strconcat (session_id, "\n", NULL);
            if (!g_file_set_contents_full (path, ack, -1,
                    G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, NULL))
                return fail ("Scrub stopped, but the cancellation acknowledgement could not be saved.");
        }
        g_print ("cancelled unknown 0 0 0 0\n");
        return 0;
    }

    g_autofree char *name = g_strdup_printf ("scrub.status.%s", uuid);
    struct stat checkpoint_info = { 0 };
    g_autofree char *checkpoint = scrub_read_info (SCRUB_UPSTREAM, name, &checkpoint_info);
    g_autofree char *digest = checkpoint ? g_compute_checksum_for_string (G_CHECKSUM_SHA256, checkpoint, -1) : NULL;
    g_autofree char *generation = scrub_checkpoint_generation (digest, &checkpoint_info);
    g_autofree char *before = g_key_file_get_string (state, "session", "previous-checkpoint", NULL);
    g_autofree char *mode = g_key_file_get_string (state, "session", "mode", NULL);
    g_autofree char *completed_digest = g_key_file_get_string (state, "session", "final-checkpoint", NULL);
    g_autofree char *terminal = g_key_file_get_string (state, "session", "result", NULL);
    guint64 start = g_key_file_get_uint64 (state, "session", "start", NULL);
    guint64 attempt = g_key_file_get_uint64 (state, "session", "attempt", NULL);
    guint64 prior_scope = g_key_file_get_uint64 (state, "session", "scope", NULL);
    gboolean was_resume = g_key_file_get_boolean (state, "session", "resume", NULL);
    owned = owned && start && (g_strcmp0 (mode, "readonly") == 0 || g_strcmp0 (mode, "repair") == 0);
    gboolean records = owned && generation && g_strcmp0 (generation, before) != 0 &&
        (!terminal || g_strcmp0 (digest, completed_digest) == 0) &&
        scrub_checkpoint (checkpoint, uuid, members, count, prior_scope, start, attempt, was_resume);
    gboolean incomplete = FALSE, offset = FALSE;
    for (guint i = 0; records && i < count; i++)
        if (members[i].recorded && (members[i].cancelled || !members[i].finished)) {
            incomplete = TRUE;
            offset |= members[i].saved.last_physical != 0;
        }
    gboolean backend = scrub_backend_supported ();
    gboolean can_repair = backend && !protected && scrub_repair_safe (fd, uuid, members, count);
    gboolean resumable = backend && !protected && !running && records && incomplete && offset &&
        (g_strcmp0 (mode, "readonly") == 0 || can_repair);
    gboolean associated = owned && (!running || (!locked && !terminal));
    if (running && prior_scope)
        for (guint i = 0; i < count; i++)
            if (members[i].running && members[i].info.devid != prior_scope)
                associated = FALSE;
    const char *observed_mode = associated ? mode : "unknown";
    const char *phase = running ? "running" : owned && !terminal && !locked && lock >= 0 ? "starting" :
        resumable ? "resumable" : owned ? "unknown" : "never-run";
    g_autofree char *observed = scrub_report (phase, observed_mode, associated ? start : 0,
        associated ? prior_scope : 0, resumable, can_repair, records && associated, members, count);
    if (status || history) {
        if (history) {
            gsize n = 0;
            g_auto(GStrv) reports = g_key_file_get_string_list (state, "history", "reports", &n, NULL);
            if (n > SCRUB_HISTORY) return fail ("The saved scrub history is invalid.");
            if (!terminal && resumable)
                g_print ("%s\n", observed);
            for (gsize i = 0; i < n; i++) g_print ("%s\n", reports[i]);
            return 0;
        }
        if (terminal && owned && !running) {
            /* Keep verified terminal counters, but compute today's eligibility
             * independently from the saved result and current checkpoint. */
            const char *end = strchr (terminal, '\n');
            g_auto(GStrv) parts = end ? g_strsplit (terminal, " ", 2) : NULL;
            if (!end || !parts[1]) return fail ("The saved scrub result is invalid.");
            g_autofree char *updated = g_strdup_printf ("%s %s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT
                " %d %d%s", parts[0], mode, start, prior_scope, resumable, can_repair, end);
            scrub_print_status (updated, review, backend && !protected);
        } else scrub_print_status (observed, review, backend && !protected);
        return 0;
    }

    if (!backend || protected || running || !digest ||
        (resume && !resumable) || (repair && !can_repair))
        return fail ("Scrub backend, topology, mount access or checkpoint does not permit this request.");
    if (resume) {
        scope = prior_scope;
        readonly = g_str_equal (mode, "readonly");
    }
    g_autofree char *exclusive_path = g_strdup_printf ("/sys/fs/btrfs/%s/exclusive_operation", uuid);
    g_autofree char *exclusive = NULL;
    if (!g_file_get_contents (exclusive_path, &exclusive, NULL, NULL) ||
        !g_str_equal (g_strstrip (exclusive), "none") ||
        !scrub_directory (SCRUB_STORE, TRUE) || !scrub_directory (SCRUB_UPSTREAM, TRUE) ||
        !quota_mount_current (fd, argv[2], source, uuid) ||
        !verify_maintenance_topology (fd, uuid, count, TRUE))
        return fail ("The scrub mount, state directory or exclusive-operation state could not be verified.");
    g_autofree char *temporary = g_strdup_printf ("%s_tmp", name);
    g_autofree char *temp_contents = scrub_read (SCRUB_UPSTREAM, temporary);
    if (!temp_contents) return fail ("The upstream scrub temporary record is unsafe.");

    int target __attribute__((cleanup(close_fd))) = -1;
    if (scope) {
        ScrubMember *m = scrub_member (members, count, scope);
        if (m) target = open ((char *) m->info.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (!m || target < 0 || !scrub_selected_block (target, uuid, m))
            return fail ("The selected Btrfs member is unavailable.");
    } else target = dup (fd);

    attempt = g_get_real_time () / G_USEC_PER_SEC;
    if (!terminal && resumable) scrub_history_add (state, observed);
    if (!resume) start = attempt;
    g_clear_pointer (&session_id, g_free);
    session_id = g_uuid_string_random ();
    g_key_file_set_string (state, "session", "id", session_id);
    const char *run_mode = readonly ? "readonly" : "repair";
    g_key_file_set_integer (state, "format", "version", 1);
    g_key_file_set_string (state, "session", "members", identity);
    g_key_file_set_string (state, "session", "previous-checkpoint", generation);
    g_key_file_set_string (state, "session", "mode", run_mode);
    g_key_file_set_uint64 (state, "session", "start", start);
    g_key_file_set_uint64 (state, "session", "attempt", attempt);
    g_key_file_set_uint64 (state, "session", "scope", scope);
    g_key_file_set_boolean (state, "session", "resume", resume);
    g_key_file_remove_key (state, "session", "result", NULL);
    g_key_file_remove_key (state, "session", "final-checkpoint", NULL);
    if (!resume) g_key_file_remove_group (state, "unverified", NULL);
    if (!scrub_store (uuid, state)) return fail ("Could not durably record the scrub session.");

    const char *arguments[10] = { SCRUB_PROGS, "scrub", resume ? "resume" : "start", "-BdR" };
    guint next = 4;
    if (readonly) arguments[next++] = "-r";
    arguments[next++] = "--";
    arguments[next++] = "/proc/self/fd/3";
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new (
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
    const char *env[] = { "LC_ALL=C", "PATH=/usr/bin:/usr/sbin", NULL };
    g_subprocess_launcher_set_environ (launcher, (char **) env);
    if (target < 0) return fail ("Could not pin the scrub target.");
    g_subprocess_launcher_take_fd (launcher, target, 3);
    target = -1;
    int inherited = fcntl (lock, F_DUPFD_CLOEXEC, 5);
    if (inherited < 0) return fail ("Could not preserve the Btrfs maintenance lock.");
    g_subprocess_launcher_take_fd (launcher, inherited, 4);
    g_autoptr(GError) error = NULL;
    g_autoptr(GSubprocess) worker = g_subprocess_launcher_spawnv (launcher, arguments, &error);
    g_subprocess_launcher_close (launcher);
    if (!worker) return fail (error->message);
    flock (cancel_lock, LOCK_UN);
    g_autofree char *output = NULL;
    g_autofree char *diagnostic = NULL;
    gboolean waited = g_subprocess_communicate_utf8 (worker, NULL, NULL, &output, &diagnostic, &error);
    int code = waited && g_subprocess_get_if_exited (worker) ? g_subprocess_get_exit_status (worker) : -1;

    if (flock (cancel_lock, LOCK_EX) != 0)
        return fail ("Could not lock scrub result reconciliation.");
    g_autofree char *ack = scrub_read (SCRUB_STORE, cancel_name);
    g_autofree char *expected_ack = g_strconcat (session_id, "\n", NULL);
    gboolean cancelled = g_strcmp0 (ack, expected_ack) == 0;

    g_autofree ScrubMember *after = g_new0 (ScrubMember, count);
    gboolean verified = scrub_members (fd, uuid, after, count);
    g_autofree char *current = verified ? scrub_fingerprint (after, count) : NULL;
    struct stat final_info = { 0 };
    g_autofree char *final = scrub_read_info (SCRUB_UPSTREAM, name, &final_info);
    g_autofree char *final_digest = final ? g_compute_checksum_for_string (G_CHECKSUM_SHA256, final, -1) : NULL;
    g_autofree char *final_generation = scrub_checkpoint_generation (final_digest, &final_info);
    records = verified && g_strcmp0 (current, identity) == 0 &&
        quota_mount_current (fd, argv[2], source, uuid) && scrub_probe (fd, after, count) == 0 &&
        final_generation && g_strcmp0 (generation, final_generation) != 0 &&
        scrub_checkpoint (final, uuid, after, count, scope, start, attempt, resume);
    incomplete = offset = FALSE;
    gboolean corrected = FALSE, uncorrectable = FALSE, other = FALSE, write_issue = FALSE;
    if (records) scrub_final_unverified (output, after, count);
    for (guint i = 0; records && i < count; i++) {
        ScrubMember *m = &after[i];
        if (!m->recorded) continue;
        if (!readonly) {
            ScrubMember *initial = scrub_member (members, count, m->info.devid);
            write_issue |= !initial || !m->health_known ||
                m->health.values[BTRFS_DEV_STAT_WRITE_ERRS] != initial->health.values[BTRFS_DEV_STAT_WRITE_ERRS] ||
                m->health.values[BTRFS_DEV_STAT_FLUSH_ERRS] != initial->health.values[BTRFS_DEV_STAT_FLUSH_ERRS];
        }
        g_autofree char *id = g_strdup_printf ("%" G_GUINT64_FORMAT, (guint64) m->info.devid);
        if (resume) {
            g_autoptr(GError) counter_error = NULL;
            guint64 previous = g_key_file_get_uint64 (state, "unverified", id, &counter_error);
            ScrubMember *prior = scrub_member (members, count, m->info.devid);
            if (prior && prior->finished && !prior->cancelled) {
                m->saved.unverified_errors = previous;
                m->unverified_known = !counter_error;
            } else if (counter_error || previous > G_MAXUINT64 - m->saved.unverified_errors) {
                m->unverified_known = FALSE;
            } else {
                m->saved.unverified_errors += previous;
            }
        }
        if (m->unverified_known)
            g_key_file_set_uint64 (state, "unverified", id, m->saved.unverified_errors);
        else
            g_key_file_remove_key (state, "unverified", id, NULL);
        incomplete |= m->cancelled || !m->finished;
        offset |= (m->cancelled || !m->finished) && m->saved.last_physical != 0;
        corrected |= m->saved.corrected_errors != 0;
        uncorrectable |= m->saved.uncorrectable_errors != 0;
        other |= m->saved.read_errors || m->saved.csum_errors || m->saved.verify_errors ||
            m->saved.super_errors || m->saved.malloc_errors || !m->unverified_known || m->saved.unverified_errors;
    }
    const char *result = !records ? "unknown" : incomplete ? (cancelled ? "cancelled" : "interrupted") :
        code != 0 && code != 3 ? "failed" : uncorrectable ? "uncorrectable" :
        write_issue ? "unverified" : corrected ? (readonly ? "recoverable" : "corrected") :
        other ? "unverified" : "clean";
    g_autofree char *report = scrub_report (result, run_mode, start, scope, records && incomplete && offset,
        can_repair, records, verified ? after : members, count);
    guint64 ended = g_get_real_time () / G_USEC_PER_SEC;
    g_autofree char *entry = g_strdup_printf ("%srecord %s %s %" G_GUINT64_FORMAT "\n",
        report, uuid, session_id, ended);
    g_key_file_set_string (state, "session", "result", entry);
    if (records) g_key_file_set_string (state, "session", "final-checkpoint", final_digest);
    scrub_history_add (state, entry);
    if (!scrub_store (uuid, state)) return fail ("The scrub stopped but the result could not be saved.");
    if (diagnostic && code != 0) g_printerr ("%s", diagnostic);
    g_print ("%s", entry);
    return 0;
}
