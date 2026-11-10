/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "btrfs-quota.h"
#include <errno.h>
#include <gio/gio.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <string.h>
#include <sys/ioctl.h>

/* Linux 6.8 UAPI, also usable when building with older headers. */
#ifndef BTRFS_QUOTA_CTL_ENABLE_SIMPLE_QUOTA
#define BTRFS_QUOTA_CTL_ENABLE_SIMPLE_QUOTA 4
#endif
#ifndef BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE
#define BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE (1ULL << 3)
#endif

#define ID_MASK ((1ULL << 48) - 1)
#define SEARCH_SIZE (64 * 1024)
#define MAX_RECORDS 65536
#define LIMIT_MASK (BTRFS_QGROUP_LIMIT_MAX_RFER | BTRFS_QGROUP_LIMIT_MAX_EXCL)

typedef struct {
    guint64 id, referenced, exclusive, flags, max_ref, max_excl;
    gboolean info, limit;
} Group;

typedef struct { guint64 from, to; } Relation;
typedef struct { guint64 objectid; guint32 type; guint64 offset; } Key;

static int
key_compare (Key left, Key right)
{
    if (left.objectid != right.objectid) return left.objectid < right.objectid ? -1 : 1;
    if (left.type != right.type) return left.type < right.type ? -1 : 1;
    if (left.offset != right.offset) return left.offset < right.offset ? -1 : 1;
    return 0;
}

static gboolean
valid_id (guint64 id)
{
    return id == BTRFS_FS_TREE_OBJECTID || (id >> 48) != 0 ||
        ((id & ID_MASK) >= BTRFS_FIRST_FREE_OBJECTID &&
         (id & ID_MASK) <= (BTRFS_LAST_FREE_OBJECTID & ID_MASK));
}

gboolean
majoris_btrfs_quota_id (const char *text, guint64 *id)
{
    g_auto(GStrv) fields = g_strsplit (text, "/", 3);
    guint64 level, number;
    if (g_strv_length (fields) != 2 ||
        !g_ascii_string_to_unsigned (fields[0], 10, 0, G_MAXUINT16, &level, NULL) ||
        !g_ascii_string_to_unsigned (fields[1], 10, 0, ID_MASK, &number, NULL))
        return FALSE;
    *id = (level << 48) | number;
    return valid_id (*id);
}

static guint64
read_le64 (const guint8 *data, gsize index)
{
    guint64 value;
    memcpy (&value, data + index * sizeof value, sizeof value);
    return GUINT64_FROM_LE (value);
}

static gboolean
invalid (GError **error, const char *message)
{
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, message);
    return FALSE;
}

static gboolean
kernel_error (GError **error, const char *message)
{
    int saved = errno;
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved), "%s: %s", message, g_strerror (saved));
    return FALSE;
}

static guint
relation_hash (gconstpointer data)
{
    const Relation *key = data;
    return g_int64_hash (&key->from) * 31 + g_int64_hash (&key->to);
}

static gboolean
relation_equal (gconstpointer a, gconstpointer b)
{
    const Relation *left = a, *right = b;
    return left->from == right->from && left->to == right->to;
}

static int
quota_ioctl (int fd, unsigned long command, void *args)
{
    return ioctl (fd, command, args);
}

static int
subvolume_exists (int fd, guint64 id, int (*request) (int, unsigned long, void *))
{
    if (id == BTRFS_FS_TREE_OBJECTID) return 1;
    struct btrfs_ioctl_search_args search = { .key = {
        .tree_id = BTRFS_ROOT_TREE_OBJECTID, .min_objectid = id, .max_objectid = id,
        .min_type = BTRFS_ROOT_ITEM_KEY, .max_type = BTRFS_ROOT_ITEM_KEY,
        .max_offset = G_MAXUINT64, .max_transid = G_MAXUINT64, .nr_items = 1
    } };
    if (request (fd, BTRFS_IOC_TREE_SEARCH, &search) != 0) return -1;
    if (search.key.nr_items == 0) return 0;
    struct btrfs_ioctl_search_header item;
    memcpy (&item, search.buf, sizeof item);
    if (search.key.nr_items != 1 || item.objectid != id || item.type != BTRFS_ROOT_ITEM_KEY ||
        item.len == 0 || item.len > sizeof search.buf - sizeof item) {
        errno = EIO;
        return -1;
    }
    return 1;
}

GVariant *
majoris_btrfs_quota_read_with_ioctl (int fd, const char *uuid,
    int (*request) (int, unsigned long, void *), GError **error)
{
    g_autofree struct btrfs_ioctl_search_args_v2 *search =
        g_malloc0 (sizeof *search + SEARCH_SIZE);
    g_autoptr(GHashTable) groups = g_hash_table_new_full (g_int64_hash, g_int64_equal, NULL, g_free);
    g_autoptr(GPtrArray) ordered = g_ptr_array_new ();
    g_autoptr(GHashTable) relations = g_hash_table_new_full (relation_hash, relation_equal, g_free, NULL);
    g_autoptr(GArray) edges = g_array_new (FALSE, FALSE, sizeof (Relation));
    guint64 flags = 0, progress = 0;
    guint records = 0;
    gboolean status = FALSE;
    g_autofree char *enabled_path = NULL, *enabled = NULL, *token = NULL;
    g_autoptr(GVariant) reviewed = NULL;
    g_auto(GVariantBuilder) rows = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(ttttttb)"));
    g_auto(GVariantBuilder) hierarchy = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(tt)"));
    g_auto(GVariantBuilder) configuration = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(ttttb)"));
    Key next = { 0, 0, 0 };
    for (;;) {
        search->key = (struct btrfs_ioctl_search_key) {
            .tree_id = BTRFS_QUOTA_TREE_OBJECTID, .min_objectid = next.objectid,
            .min_type = next.type, .min_offset = next.offset, .max_objectid = G_MAXUINT64,
            .max_type = 255, .max_offset = G_MAXUINT64, .max_transid = G_MAXUINT64,
            .nr_items = 512
        };
        search->buf_size = SEARCH_SIZE;
        if (request (fd, BTRFS_IOC_TREE_SEARCH_V2, search) != 0) {
            if (records == 0 && errno == ENOENT) break;
            kernel_error (error, "Could not read the Btrfs quota tree");
            return NULL;
        }
        if (search->key.nr_items == 0) {
            if (records == 0) goto malformed;
            break;
        }
        if (search->key.nr_items > 512 || records + search->key.nr_items > MAX_RECORDS)
            goto malformed;
        records += search->key.nr_items;
        gsize used = 0;
        const guint8 *buf = (const guint8 *) search->buf;
        for (guint i = 0; i < search->key.nr_items; i++) {
            struct btrfs_ioctl_search_header item;
            if (SEARCH_SIZE - used < sizeof item) goto malformed;
            memcpy (&item, buf + used, sizeof item);
            used += sizeof item;
            Key key = { item.objectid, item.type, item.offset };
            if (item.len > SEARCH_SIZE - used || item.type > 255 || key_compare (key, next) < 0)
                goto malformed;
            const guint8 *data = buf + used;
            used += item.len;

            switch (item.type) {
            case BTRFS_QGROUP_STATUS_KEY:
                if (status || item.objectid != 0 || item.offset != 0 ||
                    (item.len != 32 && item.len != 40) || read_le64 (data, 0) != BTRFS_QGROUP_STATUS_VERSION)
                    goto malformed;
                flags = read_le64 (data, 2);
                progress = read_le64 (data, 3);
                status = TRUE;
                break;
            case BTRFS_QGROUP_INFO_KEY:
            case BTRFS_QGROUP_LIMIT_KEY: {
                if (item.objectid != 0 || item.len != 40 || !valid_id (item.offset))
                    goto malformed;
                guint64 id = item.offset;
                Group *group = g_hash_table_lookup (groups, &id);
                if (!group) {
                    group = g_new0 (Group, 1);
                    group->id = id;
                    g_hash_table_insert (groups, &group->id, group);
                }
                if (item.type == BTRFS_QGROUP_INFO_KEY) {
                    if (group->info) goto malformed;
                    group->info = TRUE;
                    group->referenced = read_le64 (data, 1);
                    group->exclusive = read_le64 (data, 3);
                    g_ptr_array_add (ordered, group);
                } else {
                    if (group->limit) goto malformed;
                    group->limit = TRUE;
                    group->flags = read_le64 (data, 0);
                    group->max_ref = read_le64 (data, 1);
                    group->max_excl = read_le64 (data, 2);
                }
                break;
            }
            case BTRFS_QGROUP_RELATION_KEY: {
                if (item.len != 0 || !valid_id (item.objectid) || !valid_id (item.offset) ||
                    (item.objectid >> 48) == (item.offset >> 48))
                    goto malformed;
                Relation relation = { item.objectid, item.offset };
                if (g_hash_table_contains (relations, &relation)) goto malformed;
                Relation *stored = g_new (Relation, 1);
                *stored = relation;
                g_hash_table_add (relations, stored);
                if ((relation.from >> 48) < (relation.to >> 48))
                    g_array_append_val (edges, relation);
                break;
            }
            default:
                goto malformed;
            }
            next = key;
            if (++next.offset == 0 && ++next.type > 255) {
                next.type = 0;
                if (++next.objectid == 0) goto malformed;
            }
        }
    }

    guint64 allowed = BTRFS_QGROUP_STATUS_FLAG_ON | BTRFS_QGROUP_STATUS_FLAG_RESCAN |
        BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT | BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE;
    if ((records && (!status || !(flags & BTRFS_QGROUP_STATUS_FLAG_ON))) || (flags & ~allowed) ||
        ((flags & BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE) && (flags & BTRFS_QGROUP_STATUS_FLAG_RESCAN)) ||
        g_hash_table_size (groups) != ordered->len || g_hash_table_size (relations) != edges->len * 2)
        goto malformed;

    const char *mode = !status ? "disabled" :
        (flags & BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE) ? "simple" : "qgroup";
    if (g_str_equal (mode, "qgroup")) {
        struct btrfs_ioctl_quota_rescan_args scan = { 0 };
        if (request (fd, BTRFS_IOC_QUOTA_RESCAN_STATUS, &scan) != 0) {
            kernel_error (error, "Could not verify quota rescan status");
            return NULL;
        }
        if (scan.flags > 1) goto malformed;
        if (scan.flags) {
            flags |= BTRFS_QGROUP_STATUS_FLAG_RESCAN;
            progress = scan.progress;
        } else {
            flags &= ~BTRFS_QGROUP_STATUS_FLAG_RESCAN;
        }
    }
    enabled_path = g_strdup_printf ("/sys/fs/btrfs/%s/qgroups/enabled", uuid);
    if (g_file_get_contents (enabled_path, &enabled, NULL, NULL) &&
        !g_str_equal (g_strstrip (enabled), status ? "1" : "0"))
        goto malformed;
    if (status) {
        g_autofree char *path = g_strdup_printf ("/sys/fs/btrfs/%s/qgroups/inconsistent", uuid);
        g_autofree char *inconsistent = NULL;
        if (g_file_get_contents (path, &inconsistent, NULL, NULL)) {
            g_strstrip (inconsistent);
            if (g_str_equal (inconsistent, "1")) flags |= BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT;
            else if (g_str_equal (inconsistent, "0")) flags &= ~BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT;
            else goto malformed;
        }
    }

    for (guint i = 0; i < ordered->len; i++) {
        const Group *group = g_ptr_array_index (ordered, i);
        if (!group->limit) goto malformed;
        int exists = (group->id >> 48) == 0 ? subvolume_exists (fd, group->id, request) : 1;
        if (exists < 0) {
            kernel_error (error, "Could not verify a qgroup’s subvolume");
            return NULL;
        }
        g_variant_builder_add (&rows, "(ttttttb)", group->id, group->referenced,
            group->exclusive, group->flags, group->max_ref, group->max_excl, !exists);
        g_variant_builder_add (&configuration, "(ttttb)", group->id, group->flags,
            group->max_ref, group->max_excl, !exists);
    }
    for (guint i = 0; i < edges->len; i++) {
        Relation edge = g_array_index (edges, Relation, i);
        Relation reverse = { edge.to, edge.from };
        if (!g_hash_table_contains (relations, &reverse) ||
            !g_hash_table_contains (groups, &edge.from) || !g_hash_table_contains (groups, &edge.to))
            goto malformed;
        g_variant_builder_add (&hierarchy, "(tt)", edge.from, edge.to);
    }
    reviewed = g_variant_ref_sink (g_variant_new ("(st@a(ttttb)@a(tt))",
        mode, flags, g_variant_builder_end (&configuration), g_variant_builder_end (&hierarchy)));
    token = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
        g_variant_get_data (reviewed), g_variant_get_size (reviewed));
    return g_variant_ref_sink (g_variant_new ("(sttbs@a(ttttttb)@a(tt)b)", mode, flags, progress,
        g_file_test ("/sys/fs/btrfs/features/simple_quota", G_FILE_TEST_EXISTS),
        token, g_variant_builder_end (&rows), g_variant_get_child_value (reviewed, 3), FALSE));

malformed:
    invalid (error, "The quota tree is inconsistent, changed during inspection, or has unsupported records.");
    return NULL;
}

GVariant *
majoris_btrfs_quota_read (int fd, const char *uuid, GError **error)
{
    return majoris_btrfs_quota_read_with_ioctl (fd, uuid, quota_ioctl, error);
}

static gboolean
find_group (GVariant *report, guint64 id, Group *group, gboolean *stale)
{
    g_autoptr(GVariant) rows = g_variant_get_child_value (report, 5);
    GVariantIter iter;
    g_variant_iter_init (&iter, rows);
    while (g_variant_iter_next (&iter, "(ttttttb)", &group->id, &group->referenced,
        &group->exclusive, &group->flags, &group->max_ref, &group->max_excl, stale))
        if (group->id == id) return TRUE;
    return FALSE;
}

static gboolean
has_edge (GVariant *report, guint64 id, guint64 parent)
{
    g_autoptr(GVariant) edges = g_variant_get_child_value (report, 6);
    GVariantIter iter;
    guint64 child, ancestor;
    g_variant_iter_init (&iter, edges);
    while (g_variant_iter_next (&iter, "(tt)", &child, &ancestor))
        if (parent ? child == id && ancestor == parent : child == id || ancestor == id)
            return TRUE;
    return FALSE;
}

static gboolean
limits_unchanged (GVariant *before, GVariant *after, guint64 target, guint64 changed_flags)
{
    g_autoptr(GVariant) old_rows = g_variant_get_child_value (before, 5);
    g_autoptr(GVariant) new_rows = g_variant_get_child_value (after, 5);
    if (g_variant_n_children (old_rows) != g_variant_n_children (new_rows)) return FALSE;
    for (gsize i = 0; i < g_variant_n_children (old_rows); i++) {
        g_autoptr(GVariant) old_row = g_variant_get_child_value (old_rows, i);
        g_autoptr(GVariant) new_row = g_variant_get_child_value (new_rows, i);
        guint64 old_id, new_id, old_flags, new_flags, old_ref, new_ref, old_excl, new_excl;
        g_variant_get_child (old_row, 0, "t", &old_id);
        g_variant_get_child (new_row, 0, "t", &new_id);
        if (old_id != new_id) return FALSE;
        g_variant_get_child (old_row, 3, "t", &old_flags);
        g_variant_get_child (new_row, 3, "t", &new_flags);
        g_variant_get_child (old_row, 4, "t", &old_ref);
        g_variant_get_child (new_row, 4, "t", &new_ref);
        g_variant_get_child (old_row, 5, "t", &old_excl);
        g_variant_get_child (new_row, 5, "t", &new_excl);
        guint64 mask = old_id == target ? changed_flags : 0;
        if (((old_flags ^ new_flags) & ~mask) ||
            (!(mask & BTRFS_QGROUP_LIMIT_MAX_RFER) && old_ref != new_ref) ||
            (!(mask & BTRFS_QGROUP_LIMIT_MAX_EXCL) && old_excl != new_excl))
            return FALSE;
    }
    return TRUE;
}

gboolean
majoris_btrfs_quota_apply (int fd, MajorisQuotaAction action, GVariant *before,
                           guint64 id, guint64 value, GError **error)
{
    const char *mode;
    guint64 flags;
    gboolean supports_simple;
    g_variant_get_child (before, 0, "&s", &mode);
    g_variant_get_child (before, 1, "t", &flags);
    g_variant_get_child (before, 3, "b", &supports_simple);
    gboolean disabled = g_str_equal (mode, "disabled");
    gboolean simple = g_str_equal (mode, "simple");
    if (flags & BTRFS_QGROUP_STATUS_FLAG_RESCAN)
        return invalid (error, "A quota rescan is already active or pending.");
    int result;
    switch (action) {
    case QUOTA_ENABLE:
    case QUOTA_ENABLE_SIMPLE:
    case QUOTA_DISABLE: {
        if (disabled != (action != QUOTA_DISABLE) || (action == QUOTA_ENABLE_SIMPLE && !supports_simple))
            return invalid (error, "This quota transition is unavailable. Mode changes require a separate disable operation.");
        struct btrfs_ioctl_quota_ctl_args args = { .cmd = action == QUOTA_DISABLE ? BTRFS_QUOTA_CTL_DISABLE :
            action == QUOTA_ENABLE_SIMPLE ? BTRFS_QUOTA_CTL_ENABLE_SIMPLE_QUOTA : BTRFS_QUOTA_CTL_ENABLE };
        result = ioctl (fd, BTRFS_IOC_QUOTA_CTL, &args);
        break;
    }
    case QUOTA_RESCAN: {
        if (!g_str_equal (mode, "qgroup")) return invalid (error, "Only traditional qgroups support rescans.");
        struct btrfs_ioctl_quota_rescan_args args = { 0 };
        result = ioctl (fd, BTRFS_IOC_QUOTA_RESCAN, &args);
        break;
    }
    default: {
        if (disabled || !valid_id (id) ||
            (simple && (action != QGROUP_REFERENCED || (id >> 48) != 0)))
            return invalid (error, "The qgroup operation is unavailable in this accounting mode.");
        Group group;
        gboolean stale;
        gboolean found = find_group (before, id, &group, &stale);
        if (found == (action == QGROUP_CREATE))
            return invalid (error, "The qgroup is missing or its ID is already allocated.");
        switch (action) {
        case QGROUP_CREATE:
        case QGROUP_DELETE: {
            if (action == QGROUP_CREATE ? (id >> 48) == 0 :
                (((id >> 48) == 0 && (!stale || group.referenced || group.exclusive ||
                    subvolume_exists (fd, id, quota_ioctl) != 0)) || has_edge (before, id, 0) ||
                 (group.flags & LIMIT_MASK) || (flags & BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT)))
                return invalid (error, "Only eligible higher-level groups or isolated, empty stale groups can be changed.");
            struct btrfs_ioctl_qgroup_create_args args = { .create = action == QGROUP_CREATE, .qgroupid = id };
            result = ioctl (fd, BTRFS_IOC_QGROUP_CREATE, &args);
            break;
        }
        case QGROUP_ASSIGN:
        case QGROUP_UNASSIGN: {
            Group parent;
            gboolean parent_stale;
            /* Strictly increasing levels make cycles impossible. */
            if (!valid_id (value) || (value >> 48) <= (id >> 48) ||
                !find_group (before, value, &parent, &parent_stale) ||
                (action == QGROUP_ASSIGN && stale) ||
                has_edge (before, id, value) == (action == QGROUP_ASSIGN))
                return invalid (error, "The requested relationship is missing, already present, or has invalid levels.");
            struct btrfs_ioctl_qgroup_assign_args args = { .assign = action == QGROUP_ASSIGN, .src = id, .dst = value };
            result = ioctl (fd, BTRFS_IOC_QGROUP_ASSIGN, &args);
            break;
        }
        case QGROUP_REFERENCED:
        case QGROUP_EXCLUSIVE: {
            if (value != G_MAXUINT64 && (stale || (flags & BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT)))
                return invalid (error, "Setting a limit requires a live qgroup and consistent accounting.");
            struct btrfs_ioctl_qgroup_limit_args args = { .qgroupid = id };
            if (action == QGROUP_REFERENCED) {
                args.lim.flags = BTRFS_QGROUP_LIMIT_MAX_RFER | BTRFS_QGROUP_LIMIT_RFER_CMPR;
                args.lim.max_rfer = value;
            } else {
                args.lim.flags = BTRFS_QGROUP_LIMIT_MAX_EXCL | BTRFS_QGROUP_LIMIT_EXCL_CMPR;
                args.lim.max_excl = value;
            }
            result = ioctl (fd, BTRFS_IOC_QGROUP_LIMIT, &args);
            break;
        }
        default:
            return invalid (error, "Invalid quota operation.");
        }
    }
    }
    return result >= 0 || kernel_error (error, "The kernel rejected the quota operation");
}

gboolean
majoris_btrfs_quota_verified (MajorisQuotaAction action, GVariant *before, GVariant *after,
                              guint64 id, guint64 value)
{
    const char *mode, *old_mode;
    g_variant_get_child (after, 0, "&s", &mode);
    g_variant_get_child (before, 0, "&s", &old_mode);
    if (action == QUOTA_ENABLE) return g_str_equal (mode, "qgroup");
    if (action == QUOTA_ENABLE_SIMPLE) return g_str_equal (mode, "simple");
    if (action == QUOTA_DISABLE) return g_str_equal (mode, "disabled");
    if (!g_str_equal (old_mode, mode)) return FALSE;
    if (action == QUOTA_RESCAN) {
        guint64 flags;
        g_variant_get_child (after, 1, "t", &flags);
        return (flags & BTRFS_QGROUP_STATUS_FLAG_RESCAN) || !(flags & BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT);
    }
    if (action == QGROUP_ASSIGN || action == QGROUP_UNASSIGN)
        return has_edge (after, id, value) == (action == QGROUP_ASSIGN);
    Group group = { 0 };
    gboolean stale;
    gboolean found = find_group (after, id, &group, &stale);
    if (action == QGROUP_CREATE || action == QGROUP_DELETE)
        return found == (action == QGROUP_CREATE);
    guint64 flag = action == QGROUP_REFERENCED ? BTRFS_QGROUP_LIMIT_MAX_RFER : BTRFS_QGROUP_LIMIT_MAX_EXCL;
    guint64 compression = action == QGROUP_REFERENCED ?
        BTRFS_QGROUP_LIMIT_RFER_CMPR : BTRFS_QGROUP_LIMIT_EXCL_CMPR;
    guint64 limit = action == QGROUP_REFERENCED ? group.max_ref : group.max_excl;
    return found && (value == G_MAXUINT64 ? !(group.flags & flag) : (group.flags & flag) && limit == value) &&
        limits_unchanged (before, after, id, flag | compression);
}
