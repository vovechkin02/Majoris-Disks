// Exercise the parser without a system crypttab or root privileges.
#define main inspector_main
#include "../src/crypttab-inspector.c"
#undef main
#include <sys/wait.h>

static int
check(const char *contents, const char *new_name, const char *old_name,
      const char *old_path, const char *new_path)
{
    FILE *file = fmemopen((void *) contents, strlen(contents), "r");
    g_assert_nonnull(file);
    struct stat key = {0};
    int result = inspect_config(file, -1, new_name, old_name, "UUID=test",
                                "nofail,vendor-option", old_path, new_path, &key);
    fclose(file);
    return result;
}

static void
test_records(void)
{
    const char *entry = "  # comment\n\n archive\tUUID=test\tnone nofail,vendor-option\n";
    g_assert_cmpint(check(entry, "archive", "archive", "", ""), ==, 0);
    g_assert_cmpint(check(entry, "archive", "", "", ""), ==, CONFLICT);
    g_assert_cmpint(check(entry, "missing", "missing", "", ""), ==, STALE);
    g_assert_cmpint(check("archive UUID=test none nofail\n", "archive", "archive", "", ""), ==, STALE);
    g_assert_cmpint(check("archive UUID=test - nofail,vendor-option\n"
                         "archive UUID=test none nofail,vendor-option\n",
                         "archive", "archive", "", ""), ==, CONFLICT);
    g_assert_cmpint(check("archiv\\145 UUID=other none\n", "archive", "", "", ""), ==, CONFLICT);
    g_assert_cmpint(check("only-one-field\n", "archive", "", "", ""), ==, INSPECTION_FAILED);
}

static void
test_key_references(void)
{
    const char *key = "/etc/luks-keys/archive";
    g_assert_cmpint(check("foreign UUID=foreign /etc/luks-keys/../luks-keys/archive\n",
                         "archive", "", "", key), ==, SHARED);
    g_assert_cmpint(check("foreign UUID=foreign /etc/luks-keys/archiv\\145:LABEL=keys\n",
                         "archive", "", "", key), ==, SHARED);
    g_assert_cmpint(check("foreign UUID=foreign /etc/luks-keys/archiv\\000e:LABEL=keys\n",
                         "archive", "", "", key), ==, INSPECTION_FAILED);
    g_assert_cmpint(check("archive UUID=test /etc/luks-keys/archive nofail,vendor-option\n",
                         "archive", "archive", key, key), ==, 0);
}

static void
test_vg_references(void)
{
    static const struct {
        const char *contents;
        int result;
    } cases[] = {
        {" # /dev/test-vg/data\n", 0},
        {"rd.lvm.vg=test-vg-extra rd.lvm.lv=test-vg-extra/root", 0},
        {"rd.lvm.vg=test-vg", CONFLICT},
        {"quiet rd.lvm.lv=test-vg/root", CONFLICT},
        {"/dev/test-vg/data /data ext4 defaults 0 2", CONFLICT},
        {"crypt /dev/mapper/test--vg-data none nofail", CONFLICT},
        {"crypt /dev/disk/by-id/dm-name-test--vg-data none nofail", CONFLICT},
        {"crypt /dev/test\\055vg/data none nofail", CONFLICT},
        {"crypt /dev/test\\000vg/data none nofail", INSPECTION_FAILED},
        {"crypt UUID=other /root/private-key none", 0},
    };
    for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
        FILE *file = fmemopen((void *) cases[i].contents, strlen(cases[i].contents), "r");
        g_assert_nonnull(file);
        g_assert_cmpint(scan_vg_references(file, "test-vg", "test--vg"), ==, cases[i].result);
        fclose(file);
    }
    char *malformed[] = {"inspector", "--vg-references", "/etc/crypttab", "test-vg", "example"};
    g_assert_cmpint(inspector_main(G_N_ELEMENTS(malformed), malformed), ==, INSPECTION_FAILED);
}

static void
test_vg_protected_file(void)
{
    if (geteuid() != 0) {
        g_test_skip("Requires root to verify owner-only configuration access");
        return;
    }
    g_autofree char *directory = g_dir_make_tmp("majoris-vg-inspection-XXXXXX", NULL);
    g_assert_nonnull(directory);
    g_assert_cmpint(chmod(directory, 0755), ==, 0);
    int root = open(directory, O_PATH | O_DIRECTORY | O_CLOEXEC);
    g_assert_cmpint(root, >=, 0);
    const char entry[] = "crypt /dev/mapper/test--vg-data /root/private-key none\n";
    int fd = openat(root, "crypttab", O_CREAT | O_WRONLY | O_EXCL, 0600);
    g_assert_cmpint(fd, >=, 0);
    g_assert_cmpint(write(fd, entry, sizeof(entry) - 1), ==, sizeof(entry) - 1);
    close(fd);
    g_assert_cmpint(inspect_vg_file(root, "crypttab", TRUE, "test-vg", "test--vg"), ==, CONFLICT);
    g_assert_cmpint(inspect_vg_file(root, "crypttab", TRUE, "other", "other"), ==, 0);

    pid_t child = fork();
    g_assert_cmpint(child, >=, 0);
    if (child == 0) {
        if (setgid(65534) != 0 || setuid(65534) != 0)
            _exit(1);
        _exit(inspect_vg_file(root, "crypttab", TRUE, "test-vg", "test--vg") == INSPECTION_FAILED ? 0 : 1);
    }
    int status;
    g_assert_cmpint(waitpid(child, &status, 0), ==, child);
    g_assert_true(WIFEXITED(status));
    g_assert_cmpint(WEXITSTATUS(status), ==, 0);
    g_assert_cmpint(unlinkat(root, "crypttab", 0), ==, 0);
    close(root);
    g_assert_cmpint(rmdir(directory), ==, 0);
}

int
main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/crypttab/records", test_records);
    g_test_add_func("/crypttab/key-references", test_key_references);
    g_test_add_func("/crypttab/volume-group-references", test_vg_references);
    g_test_add_func("/crypttab/volume-group-protected-file", test_vg_protected_file);
    return g_test_run();
}
