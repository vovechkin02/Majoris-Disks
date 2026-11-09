// Exercise the parser without a system crypttab or root privileges.
#define main inspector_main
#include "../src/crypttab-inspector.c"
#undef main

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

int
main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/crypttab/records", test_records);
    g_test_add_func("/crypttab/key-references", test_key_references);
    return g_test_run();
}
