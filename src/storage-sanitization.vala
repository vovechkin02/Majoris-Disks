using GLib;

namespace MajorisDisks {
    public enum StorageSanitizationMethod {
        QUICK_FORMAT, LOGICAL_ZERO_OVERWRITE, LOGICAL_MULTIPASS_OVERWRITE,
        ATA_SECURITY_ERASE, ATA_ENHANCED_SECURITY_ERASE,
        NVME_SANITIZE_BLOCK, NVME_SANITIZE_CRYPTO, NVME_SANITIZE_OVERWRITE,
        NVME_FORMAT_USER_DATA_ERASE, NVME_FORMAT_CRYPTO_ERASE,
        SCSI_SANITIZE_BLOCK, SCSI_SANITIZE_CRYPTO, SCSI_SANITIZE_OVERWRITE
    }

    public enum StorageSanitizationScope {
        UNKNOWN, LOGICAL_BLOCK, PARTITION, PHYSICAL_DRIVE, NVME_NAMESPACE,
        NVME_CONTROLLER, NVM_SUBSYSTEM, SCSI_LOGICAL_UNIT
    }

    public enum StorageSanitizationAvailability { UNKNOWN, UNSUPPORTED, BLOCKED, AVAILABLE }

    public class StorageSanitizationCapability : Object {
        public StorageSanitizationMethod method;
        public StorageSanitizationScope scope = StorageSanitizationScope.UNKNOWN;
        public StorageSanitizationAvailability availability = StorageSanitizationAvailability.UNKNOWN;
        public string reason = "";
        public string backend = "";
        public int duration_minutes = 0;
        public bool? frozen = null;

        internal static StorageSanitizationCapability ata (StorageSanitizationMethod method,
            Variant? minutes, Variant? frozen, bool direct_ata) {
            var result = new StorageSanitizationCapability ();
            result.method = method;
            result.backend = "UDisks Drive.Ata";
            if (!direct_ata) {
                result.availability = StorageSanitizationAvailability.BLOCKED;
                result.reason = "Direct ATA transport has not been established.";
            } else if (minutes == null || !minutes.is_of_type (VariantType.INT32) ||
                frozen == null || !frozen.is_of_type (VariantType.BOOLEAN) || minutes.get_int32 () < 0) {
                result.reason = "ATA erase capability or security state is unavailable.";
            } else {
                result.duration_minutes = minutes.get_int32 ();
                result.frozen = frozen.get_boolean ();
                if (result.duration_minutes == 0) {
                    result.availability = StorageSanitizationAvailability.UNSUPPORTED;
                    result.reason = "The drive does not report support for this ATA erase command.";
                } else {
                    result.availability = StorageSanitizationAvailability.BLOCKED;
                    result.reason = result.frozen == true ? "The drive is security-frozen." :
                        "Privileged identity and erase-scope revalidation is unavailable.";
                }
            }
            return result;
        }

        public string duration () {
            if (duration_minutes == 510) return "At least 508 minutes";
            return duration_minutes > 0 ? "%d minutes (device estimate)".printf (duration_minutes) : "Unknown";
        }
    }

    internal class StorageSanitizationReview : Object {
        public string identity;
        public uint64 sequence;
        public uint64 capacity;
        public string[] affected;
        public string[] affected_descriptions;
        public string phrase;
        public StorageSanitizationMethod method;
        public uint64 backing_device;
        public uint64 backing_inode;
        public bool loop;
    }

    internal class LogicalOverwrite : Object {
        public int pass;
        public int flushed_passes;
        public uint64 written;
        public uint64 verified;
        public bool write_attempted;

        internal static int pass_count (StorageSanitizationMethod method) throws Error {
            if (method == StorageSanitizationMethod.LOGICAL_ZERO_OVERWRITE) return 1;
            if (method == StorageSanitizationMethod.LOGICAL_MULTIPASS_OVERWRITE) return 3;
            throw new IOError.NOT_SUPPORTED ("This method is unavailable for logical overwrite.");
        }

        public async void run (int fd, uint64 capacity, int passes, StorageJobManager jobs, StorageJob job)
            throws Error {
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            new Thread<void*>.try ("logical-overwrite", () => {
                const int chunk_size = 1024 * 1024;
                uint8* buffer = allocate_aligned_overwrite_buffer (1, chunk_size, chunk_size);
                try {
                    for (pass = 1; pass <= passes; pass++) {
                        written = 0;
                        uint8 pattern = pass == passes ? 0 : pass == 1 ? (uint8) 0x55 : (uint8) 0xaa;
                        Memory.set (buffer, pattern, chunk_size);
                        transfer (fd, capacity, buffer, chunk_size, false, context, jobs, job,
                            "Writing pass %d of %d".printf (pass, passes), ref written);
                        if (Posix.fsync (fd) != 0)
                            throw new IOError.FAILED ("Could not flush the overwrite: " + Posix.strerror (Posix.errno));
                        flushed_passes++;
                    }
                    transfer (fd, capacity, buffer, chunk_size, true, context, jobs, job,
                        "Reading back logical blocks", ref verified);
                } catch (Error error) { failure = error; }
                free_aligned_overwrite_buffer (buffer);
                var resume = new IdleSource ();
                resume.set_callback (run.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
        }

        private void transfer (int fd, uint64 capacity, uint8* buffer, size_t chunk_size, bool verify,
            MainContext context, StorageJobManager jobs, StorageJob job, string phase, ref uint64 offset)
            throws Error {
            int64 last_update = 0;
            while (offset < capacity) {
                job.cancellable.set_error_if_cancelled ();
                size_t length = (size_t) uint64.min (chunk_size, capacity - offset);
                if (!verify) write_attempted = true;
                ssize_t count = verify ? Posix.pread (fd, buffer, length, (Posix.off_t) offset) :
                    Posix.pwrite (fd, buffer, length, (Posix.off_t) offset);
                if (count < 0 && Posix.errno == Posix.EINTR) continue;
                if (count < 0)
                    throw new IOError.FAILED ("%s failed at byte %s: %s".printf (phase, offset.to_string (),
                        Posix.strerror (Posix.errno)));
                if (count == 0)
                    throw new IOError.PARTIAL_INPUT ("%s ended at byte %s.".printf (phase, offset.to_string ()));
                if (verify) {
                    for (ssize_t i = 0; i < count; i++) {
                        if (buffer[i] != 0)
                            throw new IOError.INVALID_DATA ("Readback differs at byte %s.".printf (
                                (offset + (uint64) i).to_string ()));
                    }
                }
                offset += (uint64) count;
                int64 now = get_monotonic_time ();
                if (now - last_update >= 200000 || offset == capacity) {
                    double fraction = (double) offset / capacity;
                    var update = new IdleSource ();
                    update.set_callback (() => {
                        jobs.progress (job, phase, fraction, true);
                        return Source.REMOVE;
                    });
                    update.attach (context);
                    last_update = now;
                }
            }
        }
    }

    [CCode (cname = "BLKGETDISKSEQ", cheader_filename = "linux/fs.h")]
    internal extern const ulong BLOCK_DEVICE_SEQUENCE;

    [CCode (cname = "majoris_overwrite_loop_matches", cheader_filename = "storage-sanitization.h")]
    internal extern bool overwrite_loop_matches (int fd, uint64 backing_device, uint64 backing_inode);

    [CCode (cname = "g_aligned_alloc", cheader_filename = "glib.h")]
    private extern void* allocate_aligned_overwrite_buffer (size_t blocks, size_t size, size_t alignment);

    [CCode (cname = "g_aligned_free", cheader_filename = "glib.h")]
    private extern void free_aligned_overwrite_buffer (void* buffer);
}
