/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Private to the privileged balance helper. */
#define PROFILE_SINGLE (1ULL << 48)
#define ALLOCATION_TYPES (BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA | BTRFS_BLOCK_GROUP_SYSTEM)
#define MIB (1024ULL * 1024)

typedef struct {
    const char *name;
    guint64 flag;
    guint members, copies, tolerated;
} Profile;

static const Profile profiles[] = {
    { "single", PROFILE_SINGLE, 1, 1, 0 },
    { "dup", BTRFS_BLOCK_GROUP_DUP, 1, 2, 0 },
    { "raid0", BTRFS_BLOCK_GROUP_RAID0, 2, 1, 0 },
    { "raid1", BTRFS_BLOCK_GROUP_RAID1, 2, 2, 1 },
    { "raid10", BTRFS_BLOCK_GROUP_RAID10, 4, 2, 1 },
    { "raid1c3", BTRFS_BLOCK_GROUP_RAID1C3, 3, 3, 2 },
    { "raid1c4", BTRFS_BLOCK_GROUP_RAID1C4, 4, 4, 3 },
};

static const Profile *
find_profile (const char *name, guint64 flag)
{
    for (guint i = 0; i < G_N_ELEMENTS (profiles); i++)
        if (name ? g_str_equal (name, profiles[i].name) : flag == profiles[i].flag)
            return &profiles[i];
    return NULL;
}

static gboolean
add_workspace (guint64 *total, guint64 size)
{
    if (size > G_MAXUINT64 - *total)
        return FALSE;
    *total += size;
    return TRUE;
}

static guint64
extent_gap (guint64 start, guint64 end)
{
    const guint64 mirrors[] = { 64 * MIB, 256 * 1024 * MIB };
    guint64 largest = 0;
    start = MAX (start, MIB);
    for (guint i = 0; i < G_N_ELEMENTS (mirrors) && end > mirrors[i]; i++) {
        if (start < mirrors[i])
            largest = MAX (largest, mirrors[i] - start);
        start = MAX (start, mirrors[i] + MIB);
    }
    return MAX (largest, end > start ? end - start : 0);
}

static gboolean
member_workspace (int fd, guint64 id, guint64 size, guint64 allocated, guint64 *largest)
{
    struct btrfs_ioctl_search_args search = { .key = {
        .tree_id = BTRFS_DEV_TREE_OBJECTID, .min_objectid = id, .max_objectid = id,
        .min_type = BTRFS_DEV_EXTENT_KEY, .max_type = BTRFS_DEV_EXTENT_KEY,
        .max_offset = G_MAXUINT64, .max_transid = G_MAXUINT64
    } };
    guint64 end = 0, total = 0;
    *largest = 0;
    do {
        search.key.nr_items = 128;
        if (ioctl (fd, BTRFS_IOC_TREE_SEARCH, &search) != 0)
            return FALSE;
        gsize offset = 0;
        for (guint i = 0; i < search.key.nr_items; i++) {
            struct btrfs_ioctl_search_header header;
            struct btrfs_dev_extent extent;
            if (offset > sizeof search.buf - sizeof header - sizeof extent)
                return FALSE;
            memcpy (&header, search.buf + offset, sizeof header);
            offset += sizeof header;
            if (header.objectid != id || header.type != BTRFS_DEV_EXTENT_KEY ||
                header.len != sizeof extent || header.offset < end || header.offset >= size)
                return FALSE;
            memcpy (&extent, search.buf + offset, sizeof extent);
            offset += sizeof extent;
            guint64 length = GUINT64_FROM_LE (extent.length);
            if (length == 0 || length > size - header.offset || !add_workspace (&total, length))
                return FALSE;
            *largest = MAX (*largest, extent_gap (end, header.offset));
            end = header.offset + length;
            search.key.min_offset = header.offset + 1;
        }
    } while (search.key.nr_items);
    *largest = MAX (*largest, extent_gap (end, size));
    return total == allocated;
}

typedef struct {
    const Profile *data, *metadata;
    gboolean risk, force, changes;
    guint64 workspace;
} Conversion;

static const char *
assess_allocations (GVariant *rows, guint64 reserve, Conversion *plan, GChecksum *review)
{
    guint64 kinds = 0;
    plan->workspace = 256 * MIB;
    if (!add_workspace (&plan->workspace, reserve))
        return "Invalid metadata reserve.";
    for (gsize i = 0; i < g_variant_n_children (rows); i++) {
        guint64 flags, allocated, used;
        const char *label;
        g_variant_get_child (rows, i, "(&sttt)", &label, &allocated, &used, &flags);
        guint64 kind = flags & ALLOCATION_TYPES, layout = flags & ~ALLOCATION_TYPES;
        const Profile *source = layout == PROFILE_SINGLE ? NULL : find_profile (NULL, layout ? layout : PROFILE_SINGLE);
        if (!source || allocated == 0 || used > allocated || !(kind == BTRFS_BLOCK_GROUP_DATA || kind == BTRFS_BLOCK_GROUP_METADATA ||
            kind == BTRFS_BLOCK_GROUP_SYSTEM))
            return "Mixed, parity or unknown allocations prevent safe conversion.";
        kinds |= kind;
        if (review) {
            guint64 row[] = { GUINT64_TO_LE (flags), GUINT64_TO_LE (allocated) };
            g_checksum_update (review, (const guchar *) row, sizeof row);
        }
        const Profile *target = kind == BTRFS_BLOCK_GROUP_DATA ? plan->data : plan->metadata;
        if (!target || target == source)
            continue;
        plan->changes = TRUE;
        plan->risk |= target->copies < source->copies || target->tolerated < source->tolerated;
        plan->force |= kind != BTRFS_BLOCK_GROUP_DATA && source->copies > 1 && target->copies == 1;
        /* Budget the full old logical allocation on each required member,
         * including striped targets, with no credit for space released later. */
        if (!add_workspace (&plan->workspace, allocated) ||
            (target->flag == BTRFS_BLOCK_GROUP_DUP && !add_workspace (&plan->workspace, allocated)))
            return "Relocation workspace exceeds the supported range.";
    }
    return kinds == ALLOCATION_TYPES ? NULL : "Could not verify all three allocation categories.";
}

static const char *
assess_conversion (int fd, const char *uuid, guint64 count, gboolean resume,
                   Conversion *plan, char **token)
{
    struct btrfs_ioctl_feature_flags features = { 0 };
    if (system_filesystem (uuid) || ioctl (fd, BTRFS_IOC_GET_FEATURES, &features) != 0 ||
        (features.incompat_flags & (BTRFS_FEATURE_INCOMPAT_MIXED_GROUPS | BTRFS_FEATURE_INCOMPAT_ZONED)))
        return "Conversion requires an unprotected, non-zoned filesystem with separate allocation categories.";
    g_autoptr(GVariant) report = majoris_btrfs_allocation_fd (fd, uuid);
    if (!report)
        return "Could not verify Btrfs allocation.";
    g_autoptr(GVariant) read_only = g_variant_get_child_value (report, 7);
    g_autoptr(GVariant) exclusive = g_variant_get_child_value (report, 8);
    if (g_variant_get_boolean (read_only) ||
        !g_str_equal (g_variant_get_string (exclusive, NULL), resume ? "balance paused" : "none"))
        return "The filesystem is read-only or has a conflicting or unknown exclusive operation.";
    struct btrfs_ioctl_balance_args progress = { 0 };
    if (!resume && (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &progress) == 0 || errno != ENOTCONN))
        return "A balance exists or kernel balance capability is unavailable.";

    g_autoptr(GVariant) members = g_variant_get_child_value (report, 3);
    g_autoptr(GVariant) details = g_variant_get_child_value (report, 11);
    g_autoptr(GVariant) rows = g_variant_get_child_value (report, 2);
    g_autoptr(GVariant) reserve = g_variant_get_child_value (report, 6);
    g_autoptr(GVariant) member_count = g_variant_get_child_value (report, 1);
    if (!count || count > 64 || g_variant_get_uint64 (member_count) != count ||
        g_variant_n_children (members) != count || g_variant_n_children (details) != count)
        return "The complete Btrfs member set could not be verified.";
    guint required = MAX (plan->data ? plan->data->members : 0, plan->metadata ? plan->metadata->members : 0);
    if (count < required)
        return "The requested profile requires more members.";
    g_autoptr(GChecksum) review = g_checksum_new (G_CHECKSUM_SHA256);
    const char *error = assess_allocations (rows, g_variant_get_uint64 (reserve), plan, review);
    if (error)
        return error;
    if (!resume && !plan->changes)
        return "All selected categories already use their requested profiles.";

    guint64 numbers[64] = { 0 };
    guint eligible = 0;
    for (guint i = 0; i < count; i++) {
        guint64 id, number, size, allocated, detail_id, gap;
        const char *member_uuid, *state, *path;
        gboolean known, errors;
        g_variant_get_child (members, i, "(tttt&s&sbb)", &id, &number, &size, &allocated,
            &member_uuid, &state, &known, &errors);
        g_autoptr(GVariant) counters = NULL;
        g_variant_get_child (details, i, "(t&s@at)", &detail_id, &path, &counters);
        if (!id || id != detail_id || !number || !known || !g_uuid_string_is_valid (member_uuid) ||
            !g_str_equal (state, "Present") || g_variant_n_children (counters) != BTRFS_DEV_STAT_VALUES_MAX)
            return "A member is missing, read-only or unverified.";
        if (errors)
            return "A member reports errors. Review Replace Btrfs Device.";
        for (guint j = 0; j < i; j++)
            if (numbers[j] == number)
                return "Duplicate member identities prevent conversion.";
        numbers[i] = number;
        g_autofree char *sys = g_strdup_printf ("/sys/dev/block/%u:%u", major (number), minor (number));
        g_autofree char *holders = g_build_filename (sys, "holders", NULL);
        g_autofree char *slaves = g_build_filename (sys, "slaves", NULL);
        if (!empty_directory (holders) || !empty_directory (slaves))
            return "A member has active or unresolved kernel storage dependencies.";
        if (!member_workspace (fd, id, size, allocated, &gap))
            return "Contiguous unallocated workspace could not be verified. Refresh and reassess.";
        eligible += gap >= plan->workspace;
    }
    if (plan->changes && eligible < required)
        return "Insufficient verified contiguous workspace on enough members. Add capacity or choose another target.";
    if (token) {
        struct statx mount;
        if (statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID, &mount) != 0 ||
            !(mount.stx_mask & STATX_MNT_ID))
            return "The mounted filesystem identity could not be verified.";
        guint64 mount_id = GUINT64_TO_LE (mount.stx_mnt_id);
        g_checksum_update (review, (const guchar *) &mount_id, sizeof mount_id);
        g_autofree char *identity = g_variant_print (members, TRUE);
        g_autofree char *request = g_strdup_printf ("%s:%d:%s:%s:%s", uuid, resume,
            plan->data ? plan->data->name : "-", plan->metadata ? plan->metadata->name : "-", identity);
        g_checksum_update (review, (const guchar *) request, strlen (request));
        *token = g_strdup (g_checksum_get_string (review));
    }
    return NULL;
}

static void
set_conversion_filter (struct btrfs_balance_args *filter, const Profile *profile)
{
    filter->flags = BTRFS_BALANCE_ARGS_CONVERT | BTRFS_BALANCE_ARGS_SOFT;
    filter->target = profile->flag;
}

static gboolean
verify_conversion (int fd, const char *uuid, const Conversion *plan)
{
    g_autoptr(GVariant) report = majoris_btrfs_allocation_fd (fd, uuid);
    if (!report)
        return FALSE;
    g_autoptr(GVariant) rows = g_variant_get_child_value (report, 2);
    Conversion remaining = { .data = plan->data, .metadata = plan->metadata };
    return assess_allocations (rows, 0, &remaining, NULL) == NULL && !remaining.changes;
}
