namespace MajorisDisks {
    internal class BenchmarkResult : Object {
        public double[] throughput = {};
        public double[] latency = {};
        public uint64 sample_bytes;
        public static double average (double[] values) {
            double total = 0;
            foreach (double value in values) total += value;
            return values.length == 0 ? 0 : total / values.length;
        }

        public static void range (double[] values, out double minimum, out double maximum) {
            minimum = values.length == 0 ? 0 : values[0];
            maximum = minimum;
            foreach (var value in values) {
                minimum = double.min (minimum, value);
                maximum = double.max (maximum, value);
            }
        }
    }

    [CCode (cname = "posix_memalign", cheader_filename = "stdlib.h")]
    private extern int allocate_aligned (out void* buffer, size_t alignment, size_t bytes);
    [CCode (cname = "pread", cheader_filename = "unistd.h")]
    private extern ssize_t read_at (int fd, void* buffer, size_t count, Posix.off_t offset);

    [CCode (cname = "O_DIRECT", cheader_filename = "fcntl.h")]
    internal extern const int DIRECT_IO;

    internal class DiskBenchmark {
        public static uint64 position (uint64 capacity, uint64 bytes, uint64 alignment, int index, int count) {
            uint64 last = (capacity - bytes) / alignment;
            return ((last / (count - 1)) * index + (last % (count - 1)) * index / (count - 1)) * alignment;
        }

        public static async BenchmarkResult measure (int fd, uint64 capacity, uint64 sector, int count,
            uint64 bytes, StorageJobManager jobs, StorageJob job) throws Error {
            var context = MainContext.ref_thread_default ();
            BenchmarkResult? result = null;
            Error? failure = null;
            var token = job.cancellable;
            new Thread<void*>.try ("disk-benchmark", () => {
                try { result = measure_sync (fd, capacity, sector, count, bytes, token, context, jobs, job); }
                catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (measure.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }

        public static async double scratch_write (File directory, uint64 bytes, StorageJobManager jobs) throws Error {
            string? folder = directory.get_path ();
            if (folder == null || bytes == 0 || bytes > 256 * 1024 * 1024)
                throw new IOError.INVALID_ARGUMENT ("Choose a local folder and a scratch size up to 256 MiB.");
            string scratch = Path.build_filename (folder, ".majoris-benchmark-" + Uuid.string_random ());
            var job = jobs.begin_named ("Scratch-file write benchmark", folder, {});
            job.cancelable = true;
            jobs.phase (job, StorageJobState.RUNNING, "Measuring filesystem writes");
            var context = MainContext.ref_thread_default ();
            var outcome = new StorageOperationResult ();
            double rate = 0;
            Error? failure = null;
            try {
                new Thread<void*>.try ("scratch-benchmark", () => {
                    try { rate = write_scratch_sync (scratch, bytes, job.cancellable); }
                    catch (Error error) { failure = error; }
                    var resume = new IdleSource ();
                    resume.set_callback (scratch_write.callback);
                    resume.attach (context);
                    return null;
                });
                yield;
                if (failure != null) throw failure;
                outcome.successful = true;
                outcome.summary = "Scratch-file benchmark complete";
                return rate;
            } catch (Error error) {
                outcome.fail ("Scratch-file benchmark stopped", error);
                throw error;
            } finally { jobs.finish (job, outcome); }
        }

        private static double write_scratch_sync (string path, uint64 bytes, Cancellable token) throws Error {
            var buffer = new uint8[1024 * 1024];
            var random = new Rand ();
            for (int i = 0; i < buffer.length; i += 4) {
                uint32 value = random.next_int ();
                for (int j = 0; j < 4; j++) buffer[i + j] = (uint8) (value >> (j * 8));
            }
            token.set_error_if_cancelled ();
            int fd = Posix.open (path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
            if (fd < 0) throw new IOError.FAILED ("Could not create the scratch file: " + Posix.strerror (Posix.errno));
            double rate = 0;
            try {
                uint64 remaining = bytes;
                int64 started = get_monotonic_time ();
                while (remaining != 0) {
                    token.set_error_if_cancelled ();
                    size_t size = (size_t) uint64.min (remaining, buffer.length);
                    ssize_t written = Posix.write (fd, buffer, size);
                    if (written < 0 && Posix.errno == Posix.EINTR) continue;
                    if (written <= 0) throw new IOError.FAILED ("Scratch write failed: " + Posix.strerror (Posix.errno));
                    remaining -= written;
                }
                if (Posix.fsync (fd) != 0)
                    throw new IOError.FAILED ("Could not flush the scratch file: " + Posix.strerror (Posix.errno));
                token.set_error_if_cancelled ();
                rate = bytes * 1000000.0 / int64.max (1, get_monotonic_time () - started);
            } finally {
                Posix.close (fd);
                if (FileUtils.unlink (path) != 0) warning ("Could not delete benchmark scratch file %s", path);
            }
            return rate;
        }

        private static BenchmarkResult measure_sync (int fd, uint64 capacity, uint64 sector, int count, uint64 bytes,
            Cancellable token, MainContext context, StorageJobManager jobs, StorageJob job) throws Error {
            if (sector < 512 || sector > 65536 || (sector & (sector - 1)) != 0 || capacity > int64.MAX ||
                count < 2 || count > 128 || bytes < sector || bytes > 16 * 1024 * 1024 || bytes > capacity ||
                bytes % sector != 0 || (capacity - bytes) / sector < count - 1)
                throw new IOError.INVALID_ARGUMENT ("The requested sample size or count does not fit this device.");
            void* buffer;
            if (allocate_aligned (out buffer, (size_t) uint64.max (sector, 4096), (size_t) bytes) != 0)
                throw new IOError.NO_SPACE ("Could not allocate the benchmark buffer.");
            var result = new BenchmarkResult ();
            result.sample_bytes = bytes;
            var random = new Rand ();
            try {
                for (int stage = 0; stage < 2; stage++) {
                    for (int i = 0; i < count; i++) {
                        token.set_error_if_cancelled ();
                        uint64 length = stage == 0 ? bytes : sector;
                        uint64 offset = stage == 0 ? position (capacity, bytes, sector, i, count) :
                            (uint64) (random.next_double () * ((capacity - sector) / sector)) * sector;
                        int64 start = get_monotonic_time ();
                        ssize_t got = -1;
                        do { got = read_at (fd, buffer, (size_t) length, (Posix.off_t) offset); }
                        while (got < 0 && Posix.errno == Posix.EINTR);
                        int64 elapsed = int64.max (1, get_monotonic_time () - start);
                        if (got != length) throw new IOError.FAILED ("The device returned an incomplete benchmark read.");
                        if (stage == 0) result.throughput += bytes * 1000000.0 / elapsed;
                        else result.latency += elapsed / 1000.0;
                        string phase = "%s · %d of %d samples".printf (stage == 0 ? "Read throughput" : "Access time", i + 1, count);
                        double fraction = (stage * count + i + 1) / (2.0 * count);
                        var progress = new IdleSource ();
                        progress.set_callback (() => {
                            jobs.progress (job, phase, fraction, true);
                            return Source.REMOVE;
                        });
                        progress.attach (context);
                    }
                }
                token.set_error_if_cancelled ();
                return result;
            } finally { GLib.free (buffer); }
        }
    }
}
