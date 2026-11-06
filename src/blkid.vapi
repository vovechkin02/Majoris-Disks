namespace MajorisDisks {
    [Compact]
    [CCode (cname = "struct blkid_struct_probe", free_function = "blkid_free_probe", cheader_filename = "blkid/blkid.h")]
    internal class BlkidProbe {
        [CCode (cname = "blkid_new_probe")]
        public BlkidProbe ();
        [CCode (cname = "blkid_probe_set_device")]
        public int set_device (int fd, int64 offset, int64 size);
        [CCode (cname = "blkid_probe_set_superblocks_flags")]
        public int set_superblocks_flags (int flags);
        [CCode (cname = "blkid_do_safeprobe")]
        public int safe_probe ();
        [CCode (cname = "blkid_probe_lookup_value")]
        public int lookup_value (string key, out unowned string value, void* length = null);
    }

    [CCode (cname = "BLKID_SUBLKS_DEFAULT", cheader_filename = "blkid/blkid.h")]
    internal const int BLKID_DEFAULT_FIELDS;
    [CCode (cname = "BLKID_SUBLKS_FSINFO", cheader_filename = "blkid/blkid.h")]
    internal const int BLKID_FILESYSTEM_FIELDS;
}
