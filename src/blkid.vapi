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
        [CCode (cname = "blkid_probe_enable_partitions")]
        public int enable_partitions (int enabled);
        [CCode (cname = "blkid_probe_enable_superblocks")]
        public int enable_superblocks (int enabled);
        [CCode (cname = "blkid_do_safeprobe")]
        public int safe_probe ();
        [CCode (cname = "blkid_probe_lookup_value")]
        public int lookup_value (string key, out unowned string value, size_t* length = null);
        [CCode (cname = "blkid_probe_get_partitions")]
        public unowned BlkidPartitionList? get_partitions ();
    }

    [Compact]
    [CCode (cname = "struct blkid_struct_partlist", free_function = "", cheader_filename = "blkid/blkid.h")]
    internal class BlkidPartitionList {
        [CCode (cname = "blkid_partlist_numof_partitions")]
        public int count ();
        [CCode (cname = "blkid_partlist_get_partition")]
        public unowned BlkidPartition? get_partition (int index);
    }

    [Compact]
    [CCode (cname = "struct blkid_struct_partition", free_function = "", cheader_filename = "blkid/blkid.h")]
    internal class BlkidPartition {
        [CCode (cname = "blkid_partition_get_partno")]
        public int number ();
        [CCode (cname = "blkid_partition_get_start")]
        public int64 start ();
        [CCode (cname = "blkid_partition_get_size")]
        public int64 size ();
        [CCode (cname = "blkid_partition_is_extended")]
        public int is_extended ();
    }

    [CCode (cname = "BLKID_SUBLKS_DEFAULT", cheader_filename = "blkid/blkid.h")]
    internal const int BLKID_DEFAULT_FIELDS;
    [CCode (cname = "BLKID_SUBLKS_FSINFO", cheader_filename = "blkid/blkid.h")]
    internal const int BLKID_FILESYSTEM_FIELDS;
}
