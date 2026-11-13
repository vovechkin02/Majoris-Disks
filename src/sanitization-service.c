// SPDX-License-Identifier: GPL-3.0-or-later
#include "sanitization-scope.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef SANITIZATION_TEST
#define SERVICE "com.majoris.disks.Sanitization.Test"
#else
#define SERVICE "com.majoris.disks.Sanitization"
#endif
#define OBJECT "/com/majoris/disks/Sanitization"
#define ACTION "com.majoris.disks.Sanitization.erase"
#define POLKIT "org.freedesktop.PolicyKit1"
#define REVIEW_TTL (5 * G_TIME_SPAN_MINUTE)
#define JOURNAL_RECORD_LIMIT (1024 * 1024)

static const char *methods[] = { "ata-normal", "ata-enhanced", "block-erase", "crypto-erase", "overwrite" };
static const guint nvme_actions[] = { 2, 4, 3 };

typedef struct {
    SanitizeScope scope;
    char *caller;
    char *drive;
    guint32 uid;
    SanitizeMethod method;
    gint64 expiry;
} Review;

typedef struct {
    Review review;
    char *id;
    char *state;
    char *detail;
    gboolean observed_running;
    gboolean waiting_reply;
    gboolean accepted;
    gboolean correlation_lost;
    char *origin_boot;
    char *origin_bus;
    char *origin_owner;
    gint64 created;
    int progress;
    int lock;
} Operation;

static GDBusConnection *bus;
static GHashTable *reviews, *operations;
static const char *directory = "/var/lib/majoris-disks-sanitization";
static gboolean journal_failed;
static GMainLoop *loop;
static char *boot_id;
static char *bus_id;
static char *monitor_identity(const char *identity);

static void review_clear(Review *r)
{
    sanitize_scope_clear(&r->scope);
    g_free(r->caller);
    g_free(r->drive);
}

static void review_free(Review *r)
{
    review_clear(r);
    g_free(r);
}

static void operation_free(Operation *op)
{
    review_clear(&op->review);
    if (op->lock >= 0) close(op->lock);
    g_free(op->id);
    g_free(op->state);
    g_free(op->detail);
    g_free(op->origin_boot);
    g_free(op->origin_bus);
    g_free(op->origin_owner);
    g_free(op);
}

static gboolean terminal(const Operation *op)
{
    return g_str_equal(op->state, "backend-completed") ||
           g_str_equal(op->state, "not-dispatched") ||
           g_str_equal(op->state, "device-success") || g_str_equal(op->state, "device-failure");
}

static gboolean same_review(const SanitizeScope *review, const SanitizeScope *current)
{
    return g_strcmp0(review->identity, current->identity) == 0 &&
        g_strcmp0(review->key, current->key) == 0 &&
        g_strcmp0(review->status, current->status) == 0 &&
        g_strcmp0(review->owner, current->owner) == 0 && review->command == current->command;
}

static gboolean save(const Operation *op)
{
    g_autoptr(GKeyFile) key = g_key_file_new();
    const Review *r = &op->review;
    g_key_file_set_string(key, "Operation", "drive", r->drive);
    if (op->origin_owner) g_key_file_set_string(key, "Operation", "udisks-owner", op->origin_owner);
    if (op->origin_boot) g_key_file_set_string(key, "Operation", "boot-id", op->origin_boot);
    if (op->origin_bus) g_key_file_set_string(key, "Operation", "bus-id", op->origin_bus);
    g_key_file_set_boolean(key, "Operation", "accepted", op->accepted);
    g_key_file_set_boolean(key, "Operation", "correlation-lost", op->correlation_lost);
    g_key_file_set_string(key, "Operation", "scope-key", r->scope.key);
    g_key_file_set_string(key, "Operation", "identity", r->scope.identity);
    g_key_file_set_string(key, "Operation", "scope", r->scope.description);
    g_key_file_set_string(key, "Operation", "pre-status", r->scope.status);
    g_key_file_set_uint64(key, "Operation", "pre-command", r->scope.command);
    g_key_file_set_integer(key, "Operation", "method", r->method);
    g_key_file_set_string(key, "Operation", "action", methods[r->method]);
    g_key_file_set_uint64(key, "Operation", "uid", r->uid);
    g_key_file_set_int64(key, "Operation", "created", op->created);
    g_key_file_set_string(key, "Operation", "state", op->state);
    g_key_file_set_string(key, "Operation", "detail", op->detail);
    g_key_file_set_boolean(key, "Operation", "observed-running", op->observed_running);
    g_key_file_set_int64(key, "Operation", "updated", g_get_real_time ());
    g_autofree char *filename = g_strconcat(op->id, ".ini", NULL);
    g_autofree char *path = g_build_filename(directory, filename, NULL);
    gsize length;
    g_autofree char *contents = g_key_file_to_data(key, &length, NULL);
    g_autoptr(GError) error = NULL;
    if (length <= JOURNAL_RECORD_LIMIT && g_file_set_contents_full(path, contents, length,
        G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, &error)) return TRUE;
    g_warning("Cannot persist sanitization operation %s: %s", op->id,
        error ? error->message : "record exceeds size limit");
    journal_failed = TRUE;
    return FALSE;
}

static void set_state(Operation *op, const char *state, const char *detail, int progress)
{
    if (g_strcmp0(state, op->state) == 0 && g_strcmp0(detail, op->detail) == 0) {
        op->progress = progress;
        return;
    }
    g_free(op->state);
    g_free(op->detail);
    op->state = g_strdup(state);
    op->detail = g_strdup(detail);
    op->progress = progress;
    if (save(op) && terminal(op) && op->lock >= 0) {
        close(op->lock);
        op->lock = -1;
    }
}

static gboolean read_record(const char *path, GKeyFile *key)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return FALSE;
    struct stat st;
    gboolean valid = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
        (st.st_mode & 0777) == 0600 && st.st_nlink == 1 &&
        st.st_size > 0 && st.st_size <= JOURNAL_RECORD_LIMIT;
    g_autofree char *contents = valid ? g_malloc(st.st_size) : NULL;
    gsize offset = 0;
    while (valid && offset < (gsize)st.st_size) {
        ssize_t count = read(fd, contents + offset, st.st_size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) valid = FALSE;
        else offset += count;
    }
    close(fd);
    return valid && g_key_file_load_from_data(key, contents, offset, 0, NULL);
}

static gboolean load_records(void)
{
    g_autoptr(GDir) dir = g_dir_open(directory, 0, NULL);
    if (!dir) return FALSE;
    const char *name;
    while ((name = g_dir_read_name(dir))) {
        if (!g_str_has_suffix(name, ".ini")) continue;
        g_autoptr(GKeyFile) key = g_key_file_new();
        g_autofree char *path = g_build_filename(directory, name, NULL);
        if (!read_record(path, key)) return FALSE;
        Operation *op = g_new0(Operation, 1);
        op->lock = -1;
        op->progress = -1;
        op->id = g_strndup(name, strlen(name) - 4);
        Review *r = &op->review;
        r->drive = g_key_file_get_string(key, "Operation", "drive", NULL);
        op->origin_boot = g_key_file_get_string(key, "Operation", "boot-id", NULL);
        op->origin_bus = g_key_file_get_string(key, "Operation", "bus-id", NULL);
        op->origin_owner = g_key_file_get_string(key, "Operation", "udisks-owner", NULL);
        op->accepted = g_key_file_get_boolean(key, "Operation", "accepted", NULL);
        op->correlation_lost = g_key_file_get_boolean(key, "Operation", "correlation-lost", NULL);
        if (g_strcmp0(op->origin_boot, boot_id) == 0 && g_strcmp0(op->origin_bus, bus_id) == 0) {
            r->scope.owner = g_strdup(op->origin_owner);
        }
        r->scope.key = g_key_file_get_string(key, "Operation", "scope-key", NULL);
        r->scope.identity = g_key_file_get_string(key, "Operation", "identity", NULL);
        r->scope.description = g_key_file_get_string(key, "Operation", "scope", NULL);
        r->scope.status = g_key_file_get_string(key, "Operation", "pre-status", NULL);
        r->scope.command = g_key_file_get_uint64(key, "Operation", "pre-command", NULL);
        r->method = g_key_file_get_integer(key, "Operation", "method", NULL);
        guint64 uid = g_key_file_get_uint64(key, "Operation", "uid", NULL);
        r->uid = uid;
        op->created = g_key_file_get_int64(key, "Operation", "created", NULL);
        op->state = g_key_file_get_string(key, "Operation", "state", NULL);
        op->detail = g_key_file_get_string(key, "Operation", "detail", NULL);
        op->observed_running = r->scope.owner && g_key_file_get_boolean(key, "Operation", "observed-running", NULL);
        if (!g_uuid_string_is_valid(op->id) || !r->drive || !g_variant_is_object_path(r->drive) ||
            !r->scope.key || !r->scope.identity || !r->scope.description || !r->scope.status ||
            (guint)r->method >= METHOD_COUNT || uid > G_MAXUINT32 || op->created <= 0 || !op->state || !op->detail) {
            operation_free(op);
            return FALSE;
        }
        if (g_str_equal(op->state, "dispatch-not-reached")) {
            set_state(op, "not-dispatched", "The broker stopped before reaching the dispatch boundary.", -1);
        } else if (!terminal(op)) {
            /* Resume correlation only with the original boot and UDisks unique owner. */
            set_state(op, "uncertain", "Broker restarted before completion could be verified.", -1);
        }
        g_hash_table_insert(operations, op->id, op);
    }
    return TRUE;
}

static gboolean scope_busy(const char *key)
{
    GHashTableIter iter;
    gpointer value;
    g_hash_table_iter_init(&iter, operations);
    while (g_hash_table_iter_next(&iter, NULL, &value)) {
        Operation *op = value;
        if (!terminal(op) && g_str_equal(op->review.scope.key, key)) return TRUE;
    }
    return FALSE;
}

static int acquire(const char *key)
{
    g_autofree char *hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, key, -1);
    g_autofree char *name = g_strconcat(hash, ".lock", NULL);
    g_autofree char *path = g_build_filename(directory, name, NULL);
    int fd = open(path, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
    close(fd);
    return -1;
}

static char *new_review_handle(void)
{
    guint8 random[32];
    if (getrandom(random, sizeof random, 0) != sizeof random) return NULL;
    char *handle = g_malloc(sizeof random * 2 + 1);
    for (guint i = 0; i < sizeof random; i++)
        g_snprintf(handle + 2 * i, 3, "%02x", random[i]);
    return handle;
}

static gboolean caller_uid(const char *caller, guint32 *uid)
{
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixUser",
        g_variant_new("(s)", caller), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL);
    if (!reply) return FALSE;
    g_variant_get(reply, "(u)", uid);
    return TRUE;
}

static void review_history(const char *id, GDBusMethodInvocation *invocation)
{
    Operation *op = g_hash_table_lookup(operations, id);
    if (!op || journal_failed) {
        g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Journal",
            "The operation or a trustworthy journal is unavailable.");
        return;
    }
    const Review *r = &op->review;
    SanitizeScope now = {};
    g_autoptr(GError) error = NULL;
    g_autofree char *identity = monitor_identity(r->scope.identity);
    gboolean inspected = sanitize_inspect(bus, r->drive, r->method, FALSE, &now, &error);
    gboolean same = inspected && g_strcmp0(identity, now.identity) == 0;
    const char *evidence = terminal(op) ? "closed-with-evidence" :
        same && (now.job_running || g_strcmp0(now.status, "inprogress") == 0) ?
        "hardware-running" : "result-uncertain";
    g_autoptr(GKeyFile) audit = g_key_file_new();
    g_key_file_set_string(audit, "Review", "operation", id);
    g_key_file_set_int64(audit, "Review", "time", g_get_real_time());
    g_key_file_set_string(audit, "Review", "state", op->state);
    g_key_file_set_string(audit, "Review", "detail", op->detail);
    g_key_file_set_string(audit, "Review", "classification", evidence);
    g_key_file_set_boolean(audit, "Review", "original-identity-matches", same);
    g_key_file_set_string(audit, "Review", "original-identity", r->scope.identity);
    g_key_file_set_string(audit, "Review", "pre-command-status", r->scope.status);
    g_key_file_set_uint64(audit, "Review", "pre-command", r->scope.command);
    g_key_file_set_boolean(audit, "Review", "backend-acceptance-recorded", op->accepted);
    g_key_file_set_boolean(audit, "Review", "correlation-lost", op->correlation_lost);
    if (inspected) {
        g_key_file_set_string(audit, "Review", "current-identity", now.identity);
        g_key_file_set_string(audit, "Review", "current-status", now.status);
        g_key_file_set_boolean(audit, "Review", "ata-job-present", now.job_running);
        g_key_file_set_uint64(audit, "Review", "current-command", now.command);
        g_key_file_set_integer(audit, "Review", "current-percent-remaining", now.remaining);
    }
    if (error) g_key_file_set_string(audit, "Review", "inspection-error", error->message);
    if (!terminal(op)) g_key_file_set_string(audit, "Review", "missing-evidence", same ?
        "No attributable terminal result or proof of non-dispatch. The scope remains reserved." :
        "The original scope could not be verified. Disappearance alone cannot establish permanent removal.");
    sanitize_scope_clear(&now);
    g_autofree char *review_id = g_uuid_string_random();
    g_autofree char *name = g_strconcat(id, ".", review_id, ".review", NULL);
    g_autofree char *path = g_build_filename(directory, name, NULL);
    gsize length;
    g_autofree char *data = g_key_file_to_data(audit, &length, NULL);
    g_clear_error(&error);
    if (!g_file_set_contents_full(path, data, length,
        G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, &error)) {
        g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Journal", error->message);
        return;
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(s)", data));
}

static void dispatch_finished(GObject *source, GAsyncResult *result, gpointer data)
{
    Operation *op = data;
    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    op->waiting_reply = FALSE;
    if (!reply) {
        if (!terminal(op))
            set_state(op, "uncertain", "The UDisks call did not return success. The command may have started.", -1);
        g_message("Sanitization operation %s: %s", op->id, error->message);
    } else if (op->review.method <= ATA_ENHANCED) {
        set_state(op, "backend-completed", "UDisks reported successful completion of ATA Secure Erase.", 100);
    } else {
        op->accepted = TRUE;
        if (!terminal(op) && !op->observed_running)
            set_state(op, "accepted", "UDisks accepted the sanitize command. Waiting for attributable device status.", -1);
        else
            save(op);
    }
}

static void dispatch(Operation *op)
{
    const Review *r = &op->review;
    gboolean ata = r->method <= ATA_ENHANCED;
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "auth.no_user_interaction", g_variant_new_boolean(TRUE));
    if (ata) {
        g_variant_builder_add(&options, "{sv}", "enhanced", g_variant_new_boolean(r->method == ATA_ENHANCED));
    } else if (r->method == NVME_OVERWRITE) {
        g_variant_builder_add(&options, "{sv}", "overwrite_pass_count", g_variant_new_byte(1));
        g_variant_builder_add(&options, "{sv}", "overwrite_pattern", g_variant_new_uint32(0));
        g_variant_builder_add(&options, "{sv}", "overwrite_invert_pattern", g_variant_new_boolean(FALSE));
    }
    op->waiting_reply = TRUE;
    g_dbus_connection_call(bus, r->scope.owner, r->drive, ata ? ATA : NVME,
        ata ? "SecurityEraseUnit" : "SanitizeStart",
        ata ? g_variant_new("(a{sv})", &options) : g_variant_new("(sa{sv})", methods[r->method], &options),
        G_VARIANT_TYPE_UNIT, G_DBUS_CALL_FLAGS_NO_AUTO_START, G_MAXINT, NULL, dispatch_finished, op);
    set_state(op, "dispatched", "The allowlisted UDisks call was submitted. Waiting for backend evidence.", -1);
}

static char *monitor_identity(const char *identity)
{
    g_auto(GStrv) lines = g_strsplit(identity, "\n", -1);
    g_autoptr(GString) stable = g_string_new(NULL);
    for (guint i = 0; lines[i]; i++) {
        if (!g_str_has_prefix(lines[i], "partition:") && *lines[i]) {
            g_string_append(stable, lines[i]);
            g_string_append_c(stable, '\n');
        }
    }
    return g_string_free(g_steal_pointer(&stable), FALSE);
}

static gboolean reconcile(gpointer unused)
{
    (void)unused;
    GHashTableIter iter;
    gpointer value;
    g_hash_table_iter_init(&iter, reviews);
    while (g_hash_table_iter_next(&iter, NULL, &value))
        if (((Review *)value)->expiry < g_get_monotonic_time()) g_hash_table_iter_remove(&iter);

    g_hash_table_iter_init(&iter, operations);
    while (g_hash_table_iter_next(&iter, NULL, &value)) {
        Operation *op = value;
        Review *r = &op->review;
        if (terminal(op)) continue;
        SanitizeScope now = {};
        g_autoptr(GError) error = NULL;
        g_autofree char *stable = monitor_identity(r->scope.identity);
        gboolean same = sanitize_inspect(bus, r->drive, r->method, FALSE, &now, &error) &&
            g_strcmp0(stable, now.identity) == 0;
        gboolean continuous = same && r->scope.owner && g_strcmp0(r->scope.owner, now.owner) == 0;
        if (r->method > ATA_ENHANCED && !continuous && !op->correlation_lost) {
            op->correlation_lost = TRUE;
            save(op);
        }
        continuous = continuous && !op->correlation_lost;
        if (r->method <= ATA_ENHANCED) {
            if (continuous && now.job_running)
                set_state(op, "running", "UDisks reports an ATA erase job on this drive.", -1);
            else if (!op->waiting_reply && g_str_equal(op->state, "running"))
                set_state(op, "uncertain", "The ATA job disappeared without a verified completion reply.", -1);
            sanitize_scope_clear(&now);
            continue;
        }
        gboolean action = same && (now.command & 7) == nvme_actions[r->method - NVME_BLOCK];
        if (r->method == NVME_OVERWRITE)
            action = action && ((now.command >> 4) & 15) == 1 && !(now.command & (1u << 8));
        gboolean changed = action && (g_strcmp0(r->scope.status, now.status) != 0 ||
                                     r->scope.command != now.command);
        if (!continuous && op->observed_running) {
            op->observed_running = FALSE;
            save(op);
        }
        if (action && g_str_equal(now.status, "inprogress")) {
            if (continuous && !op->observed_running) {
                op->observed_running = TRUE;
                save(op);
            }
            set_state(op, "running", continuous ? "The controller reports sanitisation in progress." :
                "The controller reports sanitisation in progress. Attribution to this request is uncertain.",
                now.remaining < 0 ? -1 : 100 - now.remaining);
        } else if (action && continuous &&
                   op->accepted && (op->observed_running || changed) &&
                   (g_str_equal(now.status, "success") || g_str_equal(now.status, "failure"))) {
            gboolean success = g_str_equal(now.status, "success");
            set_state(op, success ? "device-success" : "device-failure",
                success ? "The controller reports successful completion of the observed operation." :
                          "The controller reports failure of the observed operation.", success ? 100 : -1);
        } else if (!op->waiting_reply) {
            set_state(op, "uncertain", "A current result attributable to this command could not be verified.", -1);
        }
        sanitize_scope_clear(&now);
    }
    return G_SOURCE_CONTINUE;
}

typedef struct {
    Review *review;
    GDBusMethodInvocation *invocation;
    int lock;
} Start;

static void authorized(GObject *source, GAsyncResult *result, gpointer data)
{
    Start *start = data;
    Review *r = start->review;
    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    gboolean allowed = FALSE;
    gboolean cancelled = FALSE;
    if (reply) {
        g_autoptr(GVariant) details = NULL;
        g_variant_get(reply, "((bb@a{ss}))", &allowed, NULL, &details);
        cancelled = g_variant_lookup(details, "polkit.dismissed", "s", NULL);
    }
    SanitizeScope now = {};
    guint32 uid;
    const char *reason = NULL;
    const char *code = "Rejected";
    if (!allowed) {
        code = cancelled ? "AuthorizationCancelled" : "AuthorizationDenied";
        reason = cancelled ? "Authorization was cancelled." : "Dedicated Polkit authorization was denied or unavailable.";
    } else if (!caller_uid(r->caller, &uid) || uid != r->uid || r->expiry < g_get_monotonic_time()) {
        reason = "The original caller disconnected or the review expired.";
    } else if (!sanitize_inspect(bus, r->drive, r->method, TRUE, &now, &error)) {
        reason = error ? error->message : "Post-authorization safety validation failed.";
    } else if (!same_review(&r->scope, &now)) {
        reason = "Hardware identity, affected scope or hardware state changed during authorization.";
    } else if (journal_failed || scope_busy(now.key)) {
        reason = "An unresolved operation or journal error prevents dispatch.";
    }
    if (reason) {
        g_autofree char *name = g_strconcat(SERVICE ".Error.", code, NULL);
        g_dbus_method_invocation_return_dbus_error(start->invocation, name, reason);
    } else {
        Operation *op = g_new0(Operation, 1);
        op->review = *r;
        g_free(r);
        start->review = NULL;
        op->lock = start->lock;
        start->lock = -1;
        op->id = g_uuid_string_random();
        op->state = g_strdup("dispatch-not-reached");
        op->detail = g_strdup("The broker has not reached the dispatch boundary.");
        op->created = g_get_real_time();
        op->origin_boot = g_strdup(boot_id);
        op->origin_bus = g_strdup(bus_id);
        op->origin_owner = g_strdup(op->review.scope.owner);
        op->progress = -1;
        if (save(op)) {
            g_hash_table_insert(operations, op->id, op);
            set_state(op, "dispatch-pending", "The command may be submitted after this checkpoint.", -1);
            SanitizeScope final = {};
            g_clear_error(&error);
            gboolean ready = !journal_failed &&
                sanitize_inspect(bus, op->review.drive, op->review.method, TRUE, &final, &error) &&
                same_review(&op->review.scope, &final) &&
                caller_uid(op->review.caller, &uid) && uid == op->review.uid &&
                op->review.expiry >= g_get_monotonic_time();
            sanitize_scope_clear(&final);
            if (ready) {
                dispatch(op);
                g_dbus_method_invocation_return_value(start->invocation, g_variant_new("(s)", op->id));
            } else {
                set_state(op, "not-dispatched", "The final validation did not authorize dispatch.", -1);
                g_dbus_method_invocation_return_dbus_error(start->invocation, SERVICE ".Error.Rejected",
                    error ? error->message : "The review, caller or journal changed before dispatch.");
            }
        } else {
            operation_free(op);
            g_dbus_method_invocation_return_dbus_error(start->invocation, SERVICE ".Error.Journal",
                "The operation could not be recorded durably. No hardware command was sent.");
        }
    }
    sanitize_scope_clear(&now);
    if (start->lock >= 0) close(start->lock);
    if (start->review) review_free(start->review);
    g_object_unref(start->invocation);
    g_free(start);
}

static void authorize(Start *start)
{
    GVariantBuilder subject, details;
    g_variant_builder_init(&subject, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&subject, "{sv}", "name", g_variant_new_string(start->review->caller));
    g_variant_builder_init(&details, G_VARIANT_TYPE("a{ss}"));
    g_dbus_connection_call(bus, POLKIT, "/org/freedesktop/PolicyKit1/Authority", POLKIT ".Authority",
        "CheckAuthorization", g_variant_new("((sa{sv})sa{ss}us)", "system-bus-name", &subject, ACTION,
            &details, 1u, ""), G_VARIANT_TYPE("((bba{ss}))"), G_DBUS_CALL_FLAGS_NONE,
        REVIEW_TTL / 1000, NULL, authorized, start);
}

static void method_call(GDBusConnection *connection, const char *caller, const char *object,
                        const char *interface, const char *member, GVariant *args,
                        GDBusMethodInvocation *invocation, gpointer data)
{
    (void)connection; (void)object; (void)interface; (void)data;
    guint32 uid;
    if (!caller_uid(caller, &uid)) {
        g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Caller",
            "The original system-bus caller could not be authenticated.");
        return;
    }
    if (g_str_equal(member, "ReviewHistory")) {
        const char *id;
        g_variant_get(args, "(&s)", &id);
        if (uid != 0) {
            g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.AuthorizationDenied",
                "Administrative journal review requires root.");
        } else {
            review_history(id, invocation);
        }
        return;
    }
    if (g_str_equal(member, "ListOperations")) {
        GVariantBuilder list;
        GHashTableIter iter;
        gpointer value;
        g_variant_builder_init(&list, G_VARIANT_TYPE("a(ssssi)"));
        g_hash_table_iter_init(&iter, operations);
        while (g_hash_table_iter_next(&iter, NULL, &value)) {
            Operation *op = value;
            if (op->review.uid == uid)
                g_variant_builder_add(&list, "(ssssi)", op->id, op->review.drive, op->state, op->detail, op->progress);
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(a(ssssi))", &list));
        return;
    }

    if (g_str_equal(member, "Review")) {
        const char *drive, *name;
        g_variant_get(args, "(&o&s)", &drive, &name);
        SanitizeMethod method = 0;
        while (method < METHOD_COUNT && !g_str_equal(name, methods[method])) method++;
        if (method == METHOD_COUNT || !g_str_has_prefix(drive, "/org/freedesktop/UDisks2/drives/")) {
            g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Request",
                "Select an allowlisted method and a UDisks drive object.");
            return;
        }
        Review *r = g_new0(Review, 1);
        r->drive = g_strdup(drive);
        r->caller = g_strdup(caller);
        r->method = method;
        r->uid = uid;
        r->expiry = g_get_monotonic_time() + REVIEW_TTL;
        g_autoptr(GError) error = NULL;
        gboolean inspected = sanitize_inspect(bus, drive, method, TRUE, &r->scope, &error);
        int probe = inspected && !journal_failed && !scope_busy(r->scope.key) ? acquire(r->scope.key) : -1;
        if (probe >= 0) close(probe);
        if (probe < 0 || g_hash_table_size(reviews) >= 128) {
            guint state = r->scope.unsupported ? 1 : r->scope.unknown ? 0 : 2;
            g_dbus_method_invocation_return_value(invocation, g_variant_new("(usss)", state, "", "",
                error ? error->message : "An unresolved operation, review limit or journal error blocks this scope."));
            review_free(r);
            return;
        }
        g_autofree char *token = new_review_handle();
        if (!token) {
            review_free(r);
            g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Review",
                "A secure review handle could not be generated.");
            return;
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(usss)", 3u, token,
            r->scope.description, ACTION));
        g_hash_table_insert(reviews, g_steal_pointer(&token), r);
        return;
    }

    const char *token;
    g_variant_get(args, "(&s)", &token);
    Review *r = g_hash_table_lookup(reviews, token);
    if (!r || r->uid != uid || !g_str_equal(r->caller, caller) || r->expiry < g_get_monotonic_time()) {
        g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Review",
            "The review is invalid, expired or belongs to another caller.");
        return;
    }
    gpointer stored_key;
    g_hash_table_steal_extended(reviews, token, &stored_key, NULL);
    g_free(stored_key);
    int lock = acquire(r->scope.key);
    if (lock < 0 || journal_failed || scope_busy(r->scope.key)) {
        if (lock >= 0) close(lock);
        review_free(r);
        g_dbus_method_invocation_return_dbus_error(invocation, SERVICE ".Error.Busy",
            "Another operation owns this hardware scope or the journal is unavailable.");
        return;
    }
    Start *start = g_new0(Start, 1);
    start->lock = lock;
    start->review = r;
    start->invocation = g_object_ref(invocation);
    authorize(start);
}

int main(int argc, char **argv)
{
#ifdef SANITIZATION_TEST
    if (argc != 2 || !g_path_is_absolute(argv[1])) return 1;
    directory = argv[1];
    GBusType type = G_BUS_TYPE_SESSION;
#else
    (void)argc; (void)argv;
    if (geteuid() != 0) return 1;
    g_unsetenv("DBUS_SYSTEM_BUS_ADDRESS");
    GBusType type = G_BUS_TYPE_SYSTEM;
#endif
    if (!g_file_get_contents("/proc/sys/kernel/random/boot_id", &boot_id, NULL, NULL)) return 1;
    g_strstrip(boot_id);
    umask(077);
    if (mkdir(directory, 0700) < 0 && errno != EEXIST) return 1;
    struct stat st;
    if (lstat(directory, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 077))
        return 1;
    /* One journal owner even if someone launches a second broker manually. */
    int journal_lock = acquire("journal");
    if (journal_lock < 0) return 1;

    reviews = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)review_free);
    operations = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, (GDestroyNotify)operation_free);
    g_autoptr(GError) error = NULL;
    bus = g_bus_get_sync(type, NULL, &error);
    if (!bus) { g_warning("%s", error->message); return 1; }
    g_autoptr(GVariant) bus_info = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId", NULL, G_VARIANT_TYPE("(s)"),
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &error);
    if (!bus_info) { g_warning("%s", error->message); return 1; }
    g_variant_get(bus_info, "(s)", &bus_id);
    if (!load_records()) {
        g_warning("Sanitization journal contains unreadable records. Dispatch is disabled.");
        journal_failed = TRUE;
    }

    static const char xml[] = "<node><interface name='" SERVICE "'>"
        "<method name='Review'><arg type='o' direction='in'/><arg type='s' direction='in'/>"
        "<arg type='u' direction='out'/><arg type='s' direction='out'/><arg type='s' direction='out'/>"
        "<arg type='s' direction='out'/></method>"
        "<method name='Start'><arg type='s' direction='in'/><arg type='s' direction='out'/></method>"
        "<method name='ListOperations'><arg type='a(ssssi)' direction='out'/></method>"
        "<method name='ReviewHistory'><arg type='s' direction='in'/><arg type='s' direction='out'/></method>"
        "</interface></node>";
    g_autoptr(GDBusNodeInfo) node = g_dbus_node_info_new_for_xml(xml, NULL);
    static const GDBusInterfaceVTable vtable = { .method_call = method_call };
    if (!g_dbus_connection_register_object(bus, OBJECT, node->interfaces[0], &vtable, NULL, NULL, &error)) {
        g_warning("%s", error->message);
        return 1;
    }
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", SERVICE, 4u),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &error);
    guint32 acquired = 0;
    if (reply) g_variant_get(reply, "(u)", &acquired);
    if (acquired != 1) return 1;
    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(3, reconcile, NULL);
    g_main_loop_run(loop);
    close(journal_lock);
    return 0;
}
