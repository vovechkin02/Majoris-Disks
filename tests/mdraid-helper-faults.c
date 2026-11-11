/* SPDX-License-Identifier: GPL-3.0-or-later
 * Test service subprocess outcomes without modifying installed helpers or policy.
 * The after case invokes the real restricted helper as the root fixture process.
 */
#include <gio/gio.h>
#include <dlfcn.h>
#include <string.h>
#include <stdarg.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <linux/major.h>
#include <linux/raid/md_u.h>
static GSubprocess *injected;
static gboolean lost_reply;

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
    lost_reply = strcmp (mode, "after") == 0;
    const char *status = strcmp (mode, "cancel") == 0 ? "exit 126" :
        strcmp (mode, "deny") == 0 ? "exit 127" : strcmp (mode, "before") == 0 ? "exit 2" : "exit 42";
    const char *fake[] = { "/bin/sh", "-c", status, NULL };
    gboolean kill_test = strcmp (mode, "kill-before") == 0 || strcmp (mode, "kill-after") == 0;
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
