namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/benchmark-dialog.ui")]
    internal class BenchmarkDialog : Adw.Dialog {
        [GtkChild] private unowned Gtk.SpinButton samples;
        [GtkChild] private unowned Gtk.SpinButton sample_mib;
        [GtkChild] private unowned Gtk.Button start;
        [GtkChild] private unowned Gtk.Button scratch;
        [GtkChild] private unowned Gtk.Label scratch_result;
        [GtkChild] private unowned Gtk.Label summary;
        [GtkChild] private unowned Gtk.DrawingArea throughput;
        [GtkChild] private unowned Gtk.DrawingArea latency;
        private BenchmarkResult? measurements;

        public BenchmarkDialog (UDisksService backend, StorageDrive drive) {
            var block = drive.medium;
            title = "Benchmark " + drive.name;
            throughput.set_draw_func ((area, cr, width, height) => draw (area, cr, width, height, measurements?.throughput ?? new double[0]));
            latency.set_draw_func ((area, cr, width, height) => draw (area, cr, width, height, measurements?.latency ?? new double[0]));
            start.sensitive = block != null;
            string identity = DriveHealth.identity (drive);
            string? saved = null;
            if (!identity.has_prefix ("session:")) {
                string id = Checksum.compute_for_string (ChecksumType.SHA256, identity);
                saved = Path.build_filename (Environment.get_user_state_dir (), "majoris-disks", "benchmark-" + id + ".ini");
                try {
                    var keyfile = new KeyFile ();
                    keyfile.load_from_file (saved, KeyFileFlags.NONE);
                    var previous = new BenchmarkResult ();
                    previous.throughput = keyfile.get_double_list ("result", "throughput");
                    previous.latency = keyfile.get_double_list ("result", "latency");
                    show_result (previous, "Saved " + keyfile.get_string ("result", "date"));
                } catch (Error error) {}
            }
            scratch.clicked.connect (() => {
                var chooser = new Gtk.FileDialog () { title = "Choose a Folder for a 64 MiB Scratch-File Test" };
                chooser.select_folder.begin (this.get_root () as Gtk.Window, null, (object, result) => {
                    File directory;
                    try { directory = chooser.select_folder.end (result); } catch (Error error) { return; }
                    scratch.sensitive = false;
                    scratch_result.label = "Measuring filesystem write throughput…";
                    DiskBenchmark.scratch_write.begin (directory, 64 * 1024 * 1024, backend.jobs, (object, measured) => {
                        scratch.sensitive = true;
                        try {
                            double rate = DiskBenchmark.scratch_write.end (measured);
                            scratch_result.label = "Filesystem write rate: %s/s".printf (format_size ((uint64) rate));
                        } catch (Error error) { scratch_result.label = error.message; }
                    });
                });
            });
            start.clicked.connect (() => {
                if (block == null) return;
                start.sensitive = false;
                summary.label = "Measurement in progress. Follow progress or cancel in Jobs.";
                backend.benchmark.begin (block, samples.get_value_as_int (),
                    (uint64) sample_mib.get_value_as_int () * 1024 * 1024, (object, result) => {
                        start.sensitive = true;
                        try {
                            var current = backend.benchmark.end (result);
                            show_result (current, "Current measurement");
                            if (saved != null && DirUtils.create_with_parents (Path.get_dirname (saved), 0700) == 0) {
                                var keyfile = new KeyFile ();
                                keyfile.set_double_list ("result", "throughput", current.throughput);
                                keyfile.set_double_list ("result", "latency", current.latency);
                                keyfile.set_string ("result", "date", new DateTime.now_local ().format ("%F %R"));
                                try { keyfile.save_to_file (saved); } catch (Error error) {
                                    summary.label += "\nCould not save results: " + error.message;
                                }
                            }
                        } catch (Error error) { summary.label = error.message; }
                    });
            });
        }

        private void show_result (BenchmarkResult result, string label) {
            measurements = result;
            double low_read, high_read, low_latency, high_latency;
            BenchmarkResult.range (result.throughput, out low_read, out high_read);
            BenchmarkResult.range (result.latency, out low_latency, out high_latency);
            summary.label = "%s\nRead: %s/s mean · %s/s minimum · %s/s maximum\nAccess: %.2f ms mean · %.2f ms minimum · %.2f ms maximum".printf (
                label, format_size ((uint64) BenchmarkResult.average (result.throughput)),
                format_size ((uint64) low_read), format_size ((uint64) high_read),
                BenchmarkResult.average (result.latency), low_latency, high_latency);
            throughput.queue_draw ();
            latency.queue_draw ();
        }

        private static void draw (Gtk.DrawingArea area, Cairo.Context cr, int width, int height, double[] values) {
            if (values.length < 2 || width < 10 || height < 10) return;
            double max = 0;
            foreach (var value in values) max = double.max (max, value);
            if (max <= 0) return;
            var colour = area.get_style_context ().get_color ();
            cr.set_source_rgba (colour.red, colour.green, colour.blue, colour.alpha);
            cr.set_line_width (2);
            for (int i = 0; i < values.length; i++) {
                double x = 4 + (width - 8) * i / (double) (values.length - 1);
                double y = height - 4 - (height - 8) * values[i] / max;
                if (i == 0) cr.move_to (x, y);
                else cr.line_to (x, y);
            }
            cr.stroke ();
        }
    }
}
