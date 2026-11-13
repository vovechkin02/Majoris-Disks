// SPDX-License-Identifier: GPL-3.0-or-later
#include "sanitization-scope.h"
#include <blkid/blkid.h>
#include <fcntl.h>
#include <libudev.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#ifdef HAVE_LIBNVME
#include <libnvme.h>
#include <endian.h>
#endif

void sanitize_scope_clear(SanitizeScope *s)
{
    g_free(s->owner);
    g_free(s->key);
    g_free(s->identity);
    g_free(s->description);
    g_free(s->status);
}

typedef struct udev Udev;
typedef struct udev_device UdevDevice;
G_DEFINE_AUTOPTR_CLEANUP_FUNC(Udev, udev_unref)
G_DEFINE_AUTOPTR_CLEANUP_FUNC(UdevDevice, udev_device_unref)

static gboolean refuse(GError **error, const char *reason)
{
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, reason);
    return FALSE;
}

static char *read_attribute(const char *parent, const char *attribute)
{
    g_autofree char *path = g_build_filename(parent, attribute, NULL);
    char *value = NULL;
    return g_file_get_contents(path, &value, NULL, NULL) ? g_strstrip(value) : NULL;
}

static gboolean equal(const char *a, const char *b)
{
    return a && b && g_str_equal(a, b);
}

static gboolean valid_id(const char *value)
{
    return value && *value && strlen(value) <= 256 && g_utf8_validate(value, -1, NULL) &&
        !strpbrk(value, "\r\n\t");
}

static const char *string_property(GVariant *props, const char *key)
{
    const char *value = NULL;
    if (props) g_variant_lookup(props, key, "&s", &value);
    return value;
}

static const char *path_property(GVariant *props, const char *key)
{
    const char *value = NULL;
    if (props) g_variant_lookup(props, key, "&o", &value);
    return value;
}

static gboolean false_property(GVariant *props, const char *key)
{
    gboolean value;
    return g_variant_lookup(props, key, "b", &value) && !value;
}

static GVariant *interface(GVariant *objects, const char *path, const char *name)
{
    g_autoptr(GVariant) entry = g_variant_lookup_value(objects, path, G_VARIANT_TYPE("a{sa{sv}}"));
    return entry ? g_variant_lookup_value(entry, name, G_VARIANT_TYPE_VARDICT) : NULL;
}

static gboolean empty_dir(const char *parent, const char *name)
{
    g_autofree char *path = g_build_filename(parent, name, NULL);
    g_autoptr(GDir) dir = g_dir_open(path, 0, NULL);
    return dir && !g_dir_read_name(dir);
}

static gboolean udisks_idle(GVariant *objects, const char *path)
{
    g_autoptr(GVariant) fs = interface(objects, path, UDISKS ".Filesystem");
    g_autoptr(GVariant) swap = interface(objects, path, UDISKS ".Swapspace");
    g_autoptr(GVariant) encrypted = interface(objects, path, UDISKS ".Encrypted");
    g_autoptr(GVariant) pv = interface(objects, path, UDISKS ".PhysicalVolume");
    g_autoptr(GVariant) mounts = fs ? g_variant_lookup_value(fs, "MountPoints", G_VARIANT_TYPE("aay")) : NULL;
    return (!fs || (mounts && g_variant_n_children(mounts) == 0)) &&
        (!swap || false_property(swap, "Active")) && !encrypted && !pv;
}

static gboolean safe_signature(int fd)
{
    blkid_probe probe = blkid_new_probe();
    if (!probe) return FALSE;
    gboolean safe = FALSE;
    if (blkid_probe_set_device(probe, fd, 0, 0) == 0 &&
        blkid_probe_enable_superblocks(probe, 1) == 0 &&
        blkid_probe_set_superblocks_flags(probe, BLKID_SUBLKS_TYPE | BLKID_SUBLKS_USAGE) == 0) {
        int result = blkid_do_safeprobe(probe);
        const char *type = NULL, *usage = NULL;
        safe = result == 1 || (result == 0 &&
            blkid_probe_lookup_value(probe, "TYPE", &type, NULL) == 0 &&
            blkid_probe_lookup_value(probe, "USAGE", &usage, NULL) == 0 &&
            equal(usage, "filesystem") && !equal(type, "btrfs") && !equal(type, "swap"));
    }
    blkid_free_probe(probe);
    return safe;
}

static gboolean inspect_block(GVariant *props, const char *sys, gboolean partition,
                              guint64 expected_sequence, gboolean check_use, guint64 *sequence,
                              GString *identity, GString *description, GError **error)
{
    g_autoptr(GVariant) device_value = g_variant_lookup_value(props, "Device", G_VARIANT_TYPE_BYTESTRING);
    const char *device = device_value ? g_variant_get_bytestring(device_value) : "";
    guint64 number, capacity, actual_capacity;
    struct stat node;
    g_autofree char *dev = read_attribute(sys, "dev");
    if (!g_str_has_prefix(device, "/dev/") || !valid_id(device) ||
        !g_variant_lookup(props, "DeviceNumber", "t", &number) ||
        !g_variant_lookup(props, "Size", "t", &capacity) || !capacity ||
        lstat(device, &node) || !S_ISBLK(node.st_mode) || node.st_rdev != number)
        return refuse(error, "The UDisks block device does not match a live kernel device.");
    g_autofree char *expected_dev = g_strdup_printf("%u:%u", major(node.st_rdev), minor(node.st_rdev));
    g_autofree char *link = g_build_filename("/sys/dev/block", expected_dev, NULL);
    g_autofree char *actual_sys = realpath(link, NULL);
    if (!equal(dev, expected_dev) || !equal(sys, actual_sys))
        return refuse(error, "The kernel block topology changed.");

    /* Whole-disk exclusive opens detect kernel claims, including mounts in other namespaces.
     * UDisks needs to obtain its own claim at dispatch, so these are validation probes. */
    int fd = open(device, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
                          (check_use ? O_EXCL : 0));
    if (fd < 0) return refuse(error, "An affected device is busy or inaccessible.");
    gboolean valid = fstat(fd, &node) == 0 && S_ISBLK(node.st_mode) && node.st_rdev == number &&
        ioctl(fd, BLKGETSIZE64, &actual_capacity) == 0 && actual_capacity == capacity &&
        ioctl(fd, BLKGETDISKSEQ, sequence) == 0 && *sequence &&
        (!partition || *sequence == expected_sequence);
    int read_only = 1;
    g_autoptr(GVariant) configuration = g_variant_lookup_value(props, "Configuration", G_VARIANT_TYPE("a(sa{sv})"));
    gboolean safe = !check_use || (ioctl(fd, BLKROGET, &read_only) == 0 && !read_only &&
        configuration && g_variant_n_children(configuration) == 0 && safe_signature(fd) && empty_dir(sys, "holders") &&
        empty_dir(sys, "slaves") && false_property(props, "ReadOnly") &&
        false_property(props, "HintSystem") && false_property(props, "HintIgnore") &&
        equal(path_property(props, "CryptoBackingDevice"), "/") &&
        equal(path_property(props, "MDRaid"), "/") && equal(path_property(props, "MDRaidMember"), "/"));
    close(fd);
    if (!valid) return refuse(error, "Kernel disk sequence or capacity could not be verified.");
    if (!safe) return refuse(error, "The scope includes protected storage, a holder or an ambiguous signature.");

    g_autofree char *start = partition ? read_attribute(sys, "start") : g_strdup("0");
    g_autofree char *index = partition ? read_attribute(sys, "partition") : g_strdup("0");
    if (!start || !index) return refuse(error, "Partition geometry is unavailable.");
    g_string_append_printf(identity, "%s%s\t%s\t%s\t%" G_GUINT64_FORMAT "\t%" G_GUINT64_FORMAT "\t%s\t%s\n",
                           partition ? "partition:" : "", sys, device, dev, *sequence, capacity, start, index);
    g_string_append_printf(description, "%s (%" G_GUINT64_FORMAT " bytes)\n", device, capacity);
    return TRUE;
}

static gint compare_names(gconstpointer a, gconstpointer b)
{
    return g_strcmp0(*(char * const *)a, *(char * const *)b);
}

static gboolean inspect_disk(GVariant *objects, const char *drive, const char *block_path,
                             const char *sys, gboolean check_use, GHashTable *seen,
                             GString *identity, GString *description, GError **error)
{
    g_autoptr(GVariant) block = interface(objects, block_path, BLOCK);
    guint64 sequence;
    if (!block || !inspect_block(block, sys, FALSE, 0, check_use, &sequence, identity, description, error))
        return FALSE;
    g_hash_table_add(seen, g_strdup(block_path));
    if (!check_use) return TRUE;

    g_autoptr(GDir) dir = g_dir_open(sys, 0, error);
    if (!dir) return FALSE;
    g_autoptr(GPtrArray) partitions = g_ptr_array_new_with_free_func(g_free);
    const char *name;
    while ((name = g_dir_read_name(dir))) {
        g_autofree char *partition = g_build_filename(sys, name, "partition", NULL);
        if (g_file_test(partition, G_FILE_TEST_EXISTS))
            g_ptr_array_add(partitions, g_build_filename(sys, name, NULL));
    }
    g_ptr_array_sort(partitions, compare_names);
    for (guint i = 0; i < partitions->len; i++) {
        const char *child = partitions->pdata[i];
        g_autofree char *dev = read_attribute(child, "dev");
        GVariantIter iter;
        const char *path;
        g_variant_iter_init(&iter, objects);
        gboolean found = FALSE;
        while (g_variant_iter_loop(&iter, "{&o*}", &path, NULL)) {
            g_autoptr(GVariant) candidate = interface(objects, path, BLOCK);
            guint64 number;
            if (!candidate || !g_variant_lookup(candidate, "DeviceNumber", "t", &number)) continue;
            g_autofree char *number_text = g_strdup_printf("%u:%u", major(number), minor(number));
            if (!equal(dev, number_text)) continue;
            g_autoptr(GVariant) part = interface(objects, path, PARTITION);
            g_autofree char *start = read_attribute(child, "start");
            g_autofree char *index = read_attribute(child, "partition");
            guint64 offset, part_sequence;
            guint32 partition_number;
            if (found || !equal(path_property(candidate, "Drive"), drive) ||
                !equal(path_property(part, "Table"), block_path) || !start || !index ||
                !g_variant_lookup(part, "Offset", "t", &offset) || offset % 512 ||
                offset / 512 != g_ascii_strtoull(start, NULL, 10) ||
                !g_variant_lookup(part, "Number", "u", &partition_number) ||
                partition_number != g_ascii_strtoull(index, NULL, 10))
                return refuse(error, "UDisks and the kernel disagree about partition ownership.");
            if (!inspect_block(candidate, child, TRUE, sequence, check_use, &part_sequence,
                               identity, description, error)) return FALSE;
            g_hash_table_add(seen, g_strdup(path));
            found = TRUE;
        }
        if (!found) return refuse(error, "A kernel partition is absent from UDisks.");
    }
    return TRUE;
}

static char *block_sysfs(GVariant *block)
{
    guint64 number;
    if (!block || !g_variant_lookup(block, "DeviceNumber", "t", &number) || !number)
        return NULL;
    g_autofree char *path = g_strdup_printf("/sys/dev/block/%u:%u", major(number), minor(number));
    return realpath(path, NULL);
}

static gboolean direct_ata(GVariant *block, const char *sys, const char *serial, const char *wwn)
{
    guint64 number;
    if (!sys || !g_variant_lookup(block, "DeviceNumber", "t", &number) ||
        !g_regex_match_simple("^/sys/devices/pci[^/]+/(?:[0-9a-f:.]+/)+ata[0-9]+/"
                             "host[0-9]+/target[0-9:]+/[0-9:]+/block/sd[a-z]+$", sys, 0, 0))
        return FALSE;
    g_autoptr(Udev) udev = udev_new();
    if (!udev) return FALSE;
    g_autoptr(UdevDevice) disk = udev_device_new_from_devnum(udev, 'b', number);
    if (!disk || !equal(udev_device_get_syspath(disk), sys) ||
        !equal(udev_device_get_property_value(disk, "ID_BUS"), "ata") ||
        !equal(udev_device_get_property_value(disk, "ID_ATA"), "1") ||
        !equal(udev_device_get_property_value(disk, "ID_SERIAL_SHORT"), serial) ||
        !equal(udev_device_get_property_value(disk, "ID_WWN"), wwn)) return FALSE;
    g_autofree char *parent = g_strndup(sys, strstr(sys, "/host") - sys);
    g_autofree char *name = g_path_get_basename(parent);
    g_autofree char *port = g_build_filename("/sys/class/ata_port", name, NULL);
    g_autofree char *target = realpath(port, NULL);
    g_autofree char *expected = g_build_filename(parent, "ata_port", name, NULL);
    return equal(target, expected);
}

#ifdef HAVE_LIBNVME
static const char *bytes_property(GVariant *props, const char *key, GVariant **value)
{
    *value = g_variant_lookup_value(props, key, G_VARIANT_TYPE_BYTESTRING);
    return *value ? g_variant_get_bytestring(*value) : NULL;
}

static char *identify_text(const char *data, size_t size)
{
    return g_strstrip(g_strndup(data, size));
}

static gboolean inspect_nvme(GVariant *objects, GVariant *controller, const char *drive,
                             const char *serial, const char *first_sys, SanitizeMethod method,
                             gboolean check_use, GPtrArray *disks, GHashTable *seen,
                             SanitizeScope *s, GString *identity, GString *description, GError **error)
{
    if (!equal(string_property(controller, "State"), "live"))
        return refuse(error, "The NVMe controller is unavailable.");
    g_autofree char *controller_sys = g_path_get_dirname(first_sys);
    g_autofree char *name = g_path_get_basename(controller_sys);
    g_autofree char *transport = read_attribute(controller_sys, "transport");
    g_autofree char *class_path = g_build_filename("/sys/class/nvme", name, NULL);
    g_autofree char *resolved = realpath(class_path, NULL);
    if (!equal(transport, "pcie") || !equal(resolved, controller_sys) ||
        !g_str_has_prefix(controller_sys, "/sys/devices/pci") ||
        !g_regex_match_simple("^nvme[0-9]+$", name, 0, 0))
        return refuse(error, "Only directly attached PCIe NVMe controllers with unambiguous paths are supported.");

    g_autofree char *nqn = read_attribute(controller_sys, "subsysnqn");
    g_autoptr(GVariant) bus_nqn = NULL;
    if (!valid_id(nqn) || !equal(nqn, bytes_property(controller, "SubsystemNQN", &bus_nqn)))
        return refuse(error, "The subsystem identifier could not be verified.");
    g_autoptr(GDir) subsystems = g_dir_open("/sys/class/nvme-subsystem", 0, error);
    if (!subsystems) return FALSE;
    const char *entry;
    guint matches = 0;
    while ((entry = g_dir_read_name(subsystems))) {
        g_autofree char *path = g_build_filename("/sys/class/nvme-subsystem", entry, NULL);
        g_autofree char *subsysnqn = read_attribute(path, "subsysnqn");
        if (!subsysnqn) return refuse(error, "Kernel subsystem enumeration is incomplete.");
        if (!equal(subsysnqn, nqn)) continue;
        matches++;
        g_autoptr(GDir) members = g_dir_open(path, 0, error);
        if (!members) return FALSE;
        const char *member;
        guint controllers = 0;
        while ((member = g_dir_read_name(members))) {
            if (!g_regex_match_simple("^nvme[0-9]+$", member, 0, 0)) continue;
            controllers++;
            g_autofree char *link = g_build_filename(path, member, NULL);
            g_autofree char *target = realpath(link, NULL);
            if (!equal(target, controller_sys))
                return refuse(error, "The NVM subsystem has multiple or ambiguous controllers.");
        }
        if (controllers != 1) return refuse(error, "Kernel controller membership is incomplete.");
    }
    if (matches != 1) return refuse(error, "The kernel subsystem is missing or ambiguous.");

    g_autofree char *device = g_build_filename("/dev", name, NULL);
    g_autofree char *devnum = read_attribute(controller_sys, "dev");
    struct stat st;
    struct nvme_id_ctrl id = {};
    struct nvme_ns_list active = {}, allocated = {};
    struct nvme_sanitize_log_page log = {};
    guint16 controller_id;
    int fd = open(device, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return refuse(error, "The NVMe controller is inaccessible.");
    g_autofree char *actual_dev = NULL;
    if (fstat(fd, &st) == 0 && S_ISCHR(st.st_mode))
        actual_dev = g_strdup_printf("%u:%u", major(st.st_rdev), minor(st.st_rdev));
    gboolean verified = equal(devnum, actual_dev) && nvme_identify_ctrl(fd, &id) == 0;
    gboolean has_management = verified && (le16toh(id.oacs) & NVME_CTRL_OACS_NS_MGMT);
    gboolean log_ok = verified && nvme_get_log_sanitize(fd, true, &log) == 0;
    gboolean lists_ok = verified && nvme_identify_active_ns_list(fd, 0, &active) == 0 &&
        (!has_management || (nvme_identify_allocated_ns_list(fd, 0, &allocated) == 0 &&
                             memcmp(&active, &allocated, sizeof active) == 0));
    for (guint i = 0; lists_ok && i < 1024 && active.ns[i]; i++) {
        struct nvme_id_ns ns = {};
        lists_ok = nvme_identify_ns(fd, le32toh(active.ns[i]), &ns) == 0 &&
            !(ns.nmic & NVME_NS_NMIC_SHARED);
    }
    close(fd);
    g_autofree char *hardware_serial = identify_text(id.sn, sizeof id.sn);
    g_autofree char *hardware_nqn = identify_text(id.subnqn, sizeof id.subnqn);
    if (!verified || !equal(hardware_serial, serial) || !equal(hardware_nqn, nqn) ||
        !g_variant_lookup(controller, "ControllerID", "q", &controller_id) ||
        controller_id != le16toh(id.cntlid))
        return refuse(error, "NVMe Identify did not confirm the controller identity.");
    if (id.cmic & (NVME_CTRL_CMIC_MULTI_PORT | NVME_CTRL_CMIC_MULTI_CTRL | NVME_CTRL_CMIC_MULTI_SRIOV))
        return refuse(error, "The controller advertises shared or multi-controller hardware.");
    guint32 sanicap = le32toh(id.sanicap);
    guint32 required = method == NVME_BLOCK ? NVME_CTRL_SANICAP_BES :
        method == NVME_CRYPTO ? NVME_CTRL_SANICAP_CES : NVME_CTRL_SANICAP_OWS;
    if (!(sanicap & required)) {
        s->unsupported = TRUE;
        return refuse(error, "Identify Controller SANICAP does not support this action.");
    }
    if (check_use && (sanicap & NVME_CTRL_SANICAP_NDI))
        return refuse(error, "This controller cannot accept the no-deallocate option used by UDisks.");
    if (!log_ok) {
        s->unknown = TRUE;
        return refuse(error, "The controller sanitize log is unavailable.");
    }
    const char *statuses[] = { "never_sanitized", "success", "inprogress", "failure", "success" };
    guint state = le16toh(log.sstat) & NVME_SANITIZE_SSTAT_STATUS_MASK;
    if (state >= G_N_ELEMENTS(statuses)) return refuse(error, "Unknown NVMe sanitize state.");
    s->status = g_strdup(statuses[state]);
    s->command = le32toh(log.scdw10);
    if (state == 2)
        s->remaining = 100 - ((guint)le16toh(log.sprog) * 100 / 65536);
    if (check_use && (state == 2 || state == 3))
        return refuse(error, "The subsystem is sanitising or reports sanitize failure mode.");
    if (!lists_ok || active.ns[1023] != 0)
        return refuse(error, "Allocated and accessible namespace coverage could not be established.");

    guint namespace_count = 0;
    while (namespace_count < 1024 && active.ns[namespace_count]) namespace_count++;
    if (!namespace_count || namespace_count != disks->len || namespace_count > le32toh(id.nn))
        return refuse(error, "Identify and UDisks disagree about the complete namespace scope.");
    if (!has_management && namespace_count != le32toh(id.nn))
        return refuse(error, "Inactive namespaces cannot be excluded.");
    s->key = g_strdup_printf("nvme:%s", nqn);
    g_string_append_printf(identity, "%s\t%s\t%s\t%u\t%u\n",
                           s->key, controller_sys, actual_dev, controller_id, sanicap);
    g_string_append_printf(description, "NVM subsystem %s\nController %s\n", nqn, device);
    g_autoptr(GHashTable) nsids = g_hash_table_new(g_direct_hash, g_direct_equal);
    g_autoptr(GHashTable) wwids = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (guint i = 0; i < disks->len; i++) {
        const char *path = disks->pdata[i];
        g_autoptr(GVariant) ns = interface(objects, path, NAMESPACE);
        g_autoptr(GVariant) block = interface(objects, path, BLOCK);
        g_autofree char *sys = block_sysfs(block);
        g_autofree char *parent = sys ? g_path_get_dirname(sys) : NULL;
        g_autofree char *nsid_text = sys ? read_attribute(sys, "nsid") : NULL;
        g_autofree char *wwid = sys ? read_attribute(sys, "wwid") : NULL;
        guint32 nsid;
        if (!ns || !equal(parent, controller_sys) ||
            !g_variant_lookup(ns, "NSID", "u", &nsid) || !nsid ||
            !nsid_text || g_ascii_strtoull(nsid_text, NULL, 10) != nsid || !valid_id(wwid) ||
            g_str_has_prefix(wwid, "nvme.") || !equal(wwid, string_property(ns, "WWN")) ||
            !g_hash_table_add(nsids, GUINT_TO_POINTER(nsid)) ||
            g_hash_table_contains(wwids, wwid))
            return refuse(error, "Namespace identity or exclusive kernel attachment is ambiguous.");
        g_hash_table_add(wwids, g_strdup(wwid));
        gboolean found = FALSE;
        for (guint j = 0; j < namespace_count; j++)
            if (le32toh(active.ns[j]) == nsid) found = TRUE;
        if (!found) return refuse(error, "A namespace is missing from hardware Identify.");
        g_string_append_printf(identity, "ns:%u\t%s\n", nsid, wwid);
        g_string_append_printf(description, "Namespace %u (%s)\n", nsid, wwid);
        if (!inspect_disk(objects, drive, path, sys, check_use, seen, identity, description, error))
            return FALSE;
    }

    /* Detect a kernel namespace that UDisks has assigned to a different drive or omitted. */
    g_autoptr(GDir) dir = g_dir_open(controller_sys, 0, error);
    if (!dir) return FALSE;
    guint kernel_namespaces = 0;
    while ((entry = g_dir_read_name(dir))) {
        g_autofree char *path = g_build_filename(controller_sys, entry, NULL);
        g_autofree char *nsid = read_attribute(path, "nsid");
        if (nsid) kernel_namespaces++;
    }
    return kernel_namespaces == namespace_count ||
        refuse(error, "The kernel exposes unreviewed namespaces on the controller.");
}
#endif

gboolean sanitize_inspect(GDBusConnection *bus, const char *drive, SanitizeMethod method,
                          gboolean check_use, SanitizeScope *s, GError **error)
{
    s->remaining = -1;
    s->unknown = TRUE;
    g_autoptr(GVariant) owner = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", g_variant_new("(s)", UDISKS),
        G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, error);
    if (!owner) return FALSE;
    g_variant_get(owner, "(s)", &s->owner);
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, s->owner, "/org/freedesktop/UDisks2",
        "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", NULL,
        G_VARIANT_TYPE("(a{oa{sa{sv}}})"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, error);
    if (!reply) return FALSE;
    g_autoptr(GVariant) objects = g_variant_get_child_value(reply, 0);
    gboolean ata = method <= ATA_ENHANCED;
    g_autoptr(GVariant) hardware = interface(objects, drive, ata ? ATA : NVME);
    g_autoptr(GVariant) props = interface(objects, drive, DRIVE);
    if (!hardware || !props) {
        s->unsupported = TRUE;
        return refuse(error, "The UDisks hardware interface is absent.");
    }
    const char *serial = string_property(props, "Serial");
    const char *wwn = string_property(props, "WWN");
    if (!valid_id(serial) || (ata && !valid_id(wwn)))
        return refuse(error, "Stable hardware identifiers are unavailable.");

    g_autoptr(GPtrArray) disks = g_ptr_array_new_with_free_func(g_free);
    guint affected = 0;
    g_autoptr(GHashTable) seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    GVariantIter iter;
    const char *path;
    g_variant_iter_init(&iter, objects);
    while (g_variant_iter_loop(&iter, "{&o*}", &path, NULL)) {
        g_autoptr(GVariant) other = interface(objects, path, DRIVE);
        if (other && !equal(path, drive) && (equal(string_property(other, "Serial"), serial) ||
            (ata && equal(string_property(other, "WWN"), wwn))))
            return refuse(error, "Another drive reports the same hardware identifiers.");
        g_autoptr(GVariant) block = interface(objects, path, BLOCK);
        if (block && equal(path_property(block, "Drive"), drive)) {
            g_autoptr(GVariant) part = interface(objects, path, PARTITION);
            if (check_use && !udisks_idle(objects, path))
                return refuse(error, "UDisks reports a mount or a protected storage stack in the scope.");
            affected++;
            if (!part) g_ptr_array_add(disks, g_strdup(path));
        }
        {
            g_autoptr(GVariant) job = interface(objects, path, UDISKS ".Job");
            g_autoptr(GVariant) targets = job ? g_variant_lookup_value(job, "Objects", G_VARIANT_TYPE("ao")) : NULL;
            if (targets) {
                GVariantIter job_iter;
                const char *target;
                g_variant_iter_init(&job_iter, targets);
                while (g_variant_iter_next(&job_iter, "&o", &target)) {
                    g_autoptr(GVariant) target_block = interface(objects, target, BLOCK);
                    if (!equal(target, drive) && !equal(path_property(target_block, "Drive"), drive)) continue;
                    if (check_use)
                        return refuse(error, "UDisks reports an active operation on the affected hardware.");
                    if (ata && equal(target, drive) && equal(string_property(job, "Operation"),
                        method == ATA_ENHANCED ? "ata-enhanced-secure-erase" : "ata-secure-erase"))
                        s->job_running = TRUE;
                }
            }
        }
    }
    s->unknown = FALSE;
    if (disks->len == 0 || (ata && disks->len != 1))
        return refuse(error, "The physical block-device scope is missing or ambiguous.");
    g_ptr_array_sort(disks, compare_names);
    g_autoptr(GVariant) first = interface(objects, disks->pdata[0], BLOCK);
    g_autofree char *sys = block_sysfs(first);
    if (!sys) return refuse(error, "The physical kernel path is unavailable.");
    g_autoptr(GString) identity = g_string_new(NULL);
    g_autoptr(GString) description = g_string_new(NULL);
    g_string_append_printf(identity, "%s\t%s\n", drive, serial);
    const char *model = string_property(props, "Model");
    if (valid_id(model)) g_string_append_printf(description, "Model %s\n", model);
    g_string_append_printf(description, "Serial %s\n", serial);
    if (ata) {
        int minutes;
        gboolean frozen;
        guint64 size, drive_size;
        if (!g_variant_lookup(hardware, method == ATA_ENHANCED ?
            "SecurityEnhancedEraseUnitMinutes" : "SecurityEraseUnitMinutes", "i", &minutes) ||
            minutes < 0 || !g_variant_lookup(hardware, "SecurityFrozen", "b", &frozen))
            return refuse(error, "ATA erase capability or frozen state is unknown.");
        if (!minutes) {
            s->unsupported = TRUE;
            return refuse(error, "The drive does not report support for this ATA command.");
        }
        if (check_use && frozen) return refuse(error, "The ATA drive is security-frozen.");
        const char *connection = string_property(props, "ConnectionBus");
        if ((!equal(connection, "ata") && !equal(connection, "")) ||
            !false_property(props, "Optical") || !false_property(props, "Removable") ||
            !g_variant_lookup(first, "Size", "t", &size) ||
            !g_variant_lookup(props, "Size", "t", &drive_size) || size != drive_size ||
            !direct_ata(first, sys, serial, wwn))
            return refuse(error, "Direct PCI/libata identity could not be verified.");
        s->key = g_strdup_printf("ata:%s", wwn);
        s->status = g_strdup(frozen ? "frozen" : "unfrozen");
        g_string_append_printf(identity, "%s\t%d\n", s->key, minutes);
        g_string_append_printf(description, "Physical ATA drive %s\n", wwn);
        if (minutes == 510) g_string_append(description, "Device estimate at least 508 minutes\n");
        else g_string_append_printf(description, "Device estimate %d minutes\n", minutes);
        if (!inspect_disk(objects, drive, disks->pdata[0], sys, check_use, seen, identity, description, error))
            return FALSE;
    } else {
#ifdef HAVE_LIBNVME
        if (!inspect_nvme(objects, hardware, drive, serial, sys, method, check_use, disks, seen,
                          s, identity, description, error))
            return FALSE;
#else
        s->unknown = TRUE;
        return refuse(error, "This broker was built without libnvme.");
#endif
    }
    if (check_use && g_hash_table_size(seen) != affected)
        return refuse(error, "UDisks exposes additional storage outside the verified kernel scope.");

    s->identity = g_string_free(g_steal_pointer(&identity), FALSE);
    s->description = g_string_free(g_steal_pointer(&description), FALSE);
    return TRUE;
}
