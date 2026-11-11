/* SPDX-License-Identifier: GPL-3.0-or-later
 * Test service subprocess outcomes without modifying installed helpers or policy.
 * The after case invokes the real restricted helper as the root fixture process.
 */
#include <gio/gio.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <stdarg.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <linux/major.h>
#include <linux/raid/md_p.h>
#include <linux/raid/md_u.h>
#include <unistd.h>
static GSubprocess *injected;
static gboolean lost_reply;

static void
churn_target (void)
{
    const char *script = g_getenv ("MAJORIS_MDRAID_CHURN_SCRIPT");
    const char *fixture = g_getenv ("MAJORIS_MDRAID_CHURN_FIXTURE");
    const char *device = g_getenv ("MAJORIS_MDRAID_CHURN_DEVICE");
    const char *action = g_getenv ("MAJORIS_MDRAID_CHURN_ACTION");
    const char *command[] = { "/bin/sh", script, fixture, device, action, NULL };
    gint status;
    if (!script || !fixture || !device || !action ||
        !g_spawn_sync (NULL, (char **) command, NULL, 0, NULL, NULL, NULL, NULL, &status, NULL) ||
        !g_spawn_check_wait_status (status, NULL))
        g_error ("The owned target could not be detached by the test fixture");
}

gboolean
g_spawn_sync (const gchar *directory, gchar **argv, gchar **envp, GSpawnFlags flags,
              GSpawnChildSetupFunc child_setup, gpointer user_data, gchar **stdout_data,
              gchar **stderr_data, gint *status, GError **error)
{
    typedef gboolean (*Spawn) (const gchar *, gchar **, gchar **, GSpawnFlags, GSpawnChildSetupFunc,
        gpointer, gchar **, gchar **, gint *, GError **);
    Spawn original = (Spawn) dlsym (RTLD_NEXT, "g_spawn_sync");
    const char *mode = g_getenv ("MAJORIS_MDRAID_HELPER_FAULT");
    gboolean readd = g_strv_length (argv) >= 5 && g_strcmp0 (argv[0], "/usr/sbin/mdadm") == 0 &&
        g_strcmp0 (argv[1], "--manage") == 0 && g_strcmp0 (argv[3], "--re-add") == 0;
    if (readd && g_strcmp0 (mode, "kill-before") == 0)
        raise (SIGKILL);
    gboolean result = original (directory, argv, envp, flags, child_setup, user_data,
        stdout_data, stderr_data, status, error);
    if (readd && result && *status == 0 && g_strcmp0 (mode, "kill-after") == 0)
        raise (SIGKILL);
    return result;
}

/* Change checksummed native metadata only in the fixture client's read buffer. */
static void
update_native_checksum (struct mdp_superblock_1 *super)
{
    guint length = sizeof (*super) + 2 * GUINT32_FROM_LE (super->max_dev);
    g_assert_cmpuint (length, <=, 4096);
    const guint8 *bytes = (const guint8 *) super;
    super->sb_csum = 0;
    guint64 sum = 0;
    guint i;
    for (i = 0; i + 4 <= length; i += 4) {
        guint32 word;
        memcpy (&word, bytes + i, sizeof (word));
        sum += GUINT32_FROM_LE (word);
    }
    if (i < length) {
        guint16 word;
        memcpy (&word, bytes + i, sizeof (word));
        sum += GUINT16_FROM_LE (word);
    }
    super->sb_csum = GUINT32_TO_LE ((guint32) (sum + (sum >> 32)));
}

ssize_t
pread (int fd, void *buffer, size_t count, off_t offset)
{
    typedef ssize_t (*Read) (int, void *, size_t, off_t);
    Read original = (Read) dlsym (RTLD_NEXT, "pread64");
    ssize_t length = original (fd, buffer, count, offset);
    const char *mode = g_getenv ("MAJORIS_MDRAID_BITMAP_FAULT");
    if (!mode || length < 512)
        return length;
    struct mdp_superblock_1 *super = buffer;
    if (length == 4096 && GUINT32_FROM_LE (super->magic) == MD_SB_MAGIC) {
        if (g_str_equal (mode, "disk-offset")) {
            super->bitmap_offset = GUINT32_TO_LE (G_MAXINT32);
            update_native_checksum (super);
        } else if (g_str_has_prefix (mode, "former-")) {
            g_autofree char *path = g_strdup_printf ("/proc/self/fd/%d", fd);
            g_autofree char *device = g_file_read_link (path, NULL);
            if (g_strcmp0 (device, g_getenv ("MAJORIS_MDRAID_CHURN_DEVICE")) == 0) {
                if (g_str_equal (mode, "former-newer")) super->events = GUINT64_TO_LE (G_MAXUINT64);
                if (g_str_equal (mode, "former-geometry"))
                    super->size = GUINT64_TO_LE (GUINT64_FROM_LE (super->size) - 2);
                if (g_str_equal (mode, "former-array")) super->set_uuid[0] ^= 1;
                if (g_str_equal (mode, "former-version")) super->major_version = GUINT32_TO_LE (2);
                if (g_str_equal (mode, "former-slot")) {
                    guint number = GUINT32_FROM_LE (super->dev_number);
                    g_assert_cmpuint (number, <, GUINT32_FROM_LE (super->max_dev));
                    super->dev_roles[number] = GUINT16_TO_LE (1 - GUINT16_FROM_LE (super->dev_roles[number]));
                }
                update_native_checksum (super);
            }
        }
    }
    for (ssize_t index = 0; index + 512 <= length; index += 512) {
        guint8 *header = (guint8 *) buffer + index;
        guint32 magic;
        memcpy (&magic, header, sizeof (magic));
        if (GUINT32_FROM_LE (magic) != 0x6d746962)
            continue;
        if (g_str_equal (mode, "truncate")) return index + 128;
        if (g_str_equal (mode, "read-error")) {
            errno = EIO;
            return -1;
        }
        if (g_str_equal (mode, "missing")) header[0] ^= 1;
        if (g_str_equal (mode, "format")) header[4] = 5;
        if (g_str_equal (mode, "uuid")) header[8] ^= 1;
        if (g_str_equal (mode, "flags")) header[48] = 1;
        if (g_str_equal (mode, "chunk")) header[52] |= 1;
        if (g_str_equal (mode, "events")) memset (header + 24, 0xff, 8);
        if (g_str_equal (mode, "history")) memset (header + 32, 0xff, 8);
        if (g_str_equal (mode, "stale")) memcpy (header + 32, header + 24, 8);
    }
    return length;
}

gboolean
g_file_get_contents (const gchar *filename, gchar **contents, gsize *length, GError **error)
{
    typedef gboolean (*Read) (const gchar *, gchar **, gsize *, GError **);
    Read original = (Read) dlsym (RTLD_NEXT, "g_file_get_contents");
    gboolean success = original (filename, contents, length, error);
    const char *mode = g_getenv ("MAJORIS_MDRAID_BITMAP_FAULT");
    const char *replacement = NULL;
    const char *helper_mode = g_getenv ("MAJORIS_MDRAID_HELPER_FAULT");
    if ((g_strcmp0 (helper_mode, "helper-churn") == 0 || g_strcmp0 (helper_mode, "bitmap-changed") == 0) &&
        g_str_has_prefix (filename, "/sys/dev/block/")) {
        g_autofree char *executable = g_file_read_link ("/proc/self/exe", NULL);
        if (executable && g_str_has_suffix (executable, "/majoris-disks-mdraid-helper")) {
            static gboolean churned;
            if (!churned && g_str_equal (helper_mode, "helper-churn") && g_str_has_suffix (filename, "/dev")) {
                churned = TRUE;
                churn_target ();
            }
            if (success && g_str_equal (helper_mode, "bitmap-changed") && g_str_has_suffix (filename, "/bitmap/can_clear"))
                replacement = g_str_has_prefix (*contents, "true") ? "false\n" : "true\n";
        }
    }
    if (g_strcmp0 (mode, "offset") == 0 && g_str_has_suffix (filename, "/bitmap/location"))
        replacement = "+2147483647\n";
    if (g_strcmp0 (mode, "reports") == 0 && g_str_has_suffix (filename, "/bitmap/location"))
        replacement = "file\n";
    if (g_strcmp0 (mode, "unknown") == 0 && g_str_has_suffix (filename, "/bitmap/can_clear"))
        replacement = "unknown\n";
    if (success && replacement) {
        g_free (*contents);
        *contents = g_strdup (replacement);
        if (length) *length = strlen (replacement);
    }
    return success;
}

GSubprocess *
g_subprocess_newv (const gchar * const *argv, GSubprocessFlags flags, GError **error)
{
    typedef GSubprocess *(*New) (const gchar * const *, GSubprocessFlags, GError **);
    New original = (New) dlsym (RTLD_NEXT, "g_subprocess_newv");
    const char *mode = g_getenv ("MAJORIS_MDRAID_HELPER_FAULT");
    if (!mode || g_strcmp0 (argv[0], "/usr/bin/pkexec") != 0 ||
        g_strcmp0 (argv[1], "--disable-internal-agent") != 0 ||
        !argv[2] || !g_str_has_suffix (argv[2], "/majoris-disks-mdraid-helper"))
        return original (argv, flags, error);
    if (g_str_equal (mode, "authorization-churn")) {
        const char *prefix[] = { "/bin/sh", "-c",
            "/bin/sh \"$1\" \"$2\" \"$3\" \"$4\" || exit 88; shift 4; exec \"$@\"", "churn",
            g_getenv ("MAJORIS_MDRAID_CHURN_SCRIPT"), g_getenv ("MAJORIS_MDRAID_CHURN_FIXTURE"),
            g_getenv ("MAJORIS_MDRAID_CHURN_DEVICE"), g_getenv ("MAJORIS_MDRAID_CHURN_ACTION") };
        guint count = g_strv_length ((char **) argv);
        g_autofree const char **command = g_new0 (const char *, G_N_ELEMENTS (prefix) + count + 1);
        memcpy (command, prefix, sizeof (prefix));
        memcpy (command + G_N_ELEMENTS (prefix), argv, count * sizeof (*argv));
        return original (command, flags, error);
    }
    if (g_str_equal (mode, "member-uuid") && g_strv_length ((char **) argv) == 13) {
        g_auto (GStrv) command = g_strdupv ((char **) argv);
        g_free (command[9]);
        command[9] = g_strdup ("00000000:00000000:00000000:00000000");
        return original ((const char * const *) command, flags, error);
    }
    lost_reply = strcmp (mode, "after") == 0;
    const char *status = strcmp (mode, "cancel") == 0 ? "exit 126" :
        strcmp (mode, "deny") == 0 ? "exit 127" : strcmp (mode, "before") == 0 ? "exit 2" :
        strcmp (mode, "verification-timeout") == 0 ? "exit 0" : "exit 42";
    const char *fake[] = { "/bin/sh", "-c", status, NULL };
    gboolean kill_test = strcmp (mode, "kill-before") == 0 || strcmp (mode, "kill-after") == 0 ||
        strcmp (mode, "helper-churn") == 0 || strcmp (mode, "bitmap-changed") == 0;
    injected = original (lost_reply || kill_test ? argv + 2 : fake, flags, error);
    return injected;
}

int
ioctl (int fd, unsigned long request, ...)
{
    typedef int (*Ioctl) (int, unsigned long, ...);
    Ioctl original = (Ioctl) dlsym (RTLD_NEXT, "ioctl");
    va_list args;
    va_start (args, request);
    void *argument = va_arg (args, void *);
    va_end (args);
    const char *mode = g_getenv ("MAJORIS_MDRAID_HELPER_FAULT");
    if (request == SET_DISK_FAULTY && g_strcmp0 (mode, "kill-before") == 0)
        raise (SIGKILL);
    int result = original (fd, request, argument);
    if (request == SET_DISK_FAULTY && result == 0 && g_strcmp0 (mode, "kill-after") == 0)
        raise (SIGKILL);
    return result;
}

gboolean
g_subprocess_get_successful (GSubprocess *process)
{
    typedef gboolean (*Successful) (GSubprocess *);
    Successful original = (Successful) dlsym (RTLD_NEXT, "g_subprocess_get_successful");
    if (process == injected && lost_reply) return FALSE;
    return original (process);
}

gint
g_subprocess_get_exit_status (GSubprocess *process)
{
    typedef gint (*Status) (GSubprocess *);
    Status original = (Status) dlsym (RTLD_NEXT, "g_subprocess_get_exit_status");
    if (process == injected && lost_reply) return 42;
    return original (process);
}
