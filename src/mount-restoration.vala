/* SPDX-License-Identifier: GPL-3.0-or-later */
namespace MajorisDisks {
    internal class MountRestorationSession : Object {
        [CCode (cname = "MAJORIS_MOUNT_RESTORATION_HELPER", cheader_filename = "mount-restoration-config.h")]
        private extern const string HELPER;
        private Subprocess process;
        private DataInputStream replies;
        private OutputStream requests;

        internal MountRestorationSession (string device, uint primary) throws Error {
            bool privileged = Posix.geteuid () == 0;
            if (!FileUtils.test (HELPER, FileTest.IS_EXECUTABLE) ||
                (!privileged && !FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE)))
                throw new IOError.NOT_SUPPORTED ("The authorized multi-mount restoration helper is unavailable.");
            string[] arguments = privileged ? new string[] { HELPER, device, primary.to_string () } :
                new string[] { "/usr/bin/pkexec", "--disable-internal-agent", HELPER, device, primary.to_string () };
            process = new Subprocess.newv (arguments, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            requests = process.get_stdin_pipe ();
            replies = new DataInputStream (process.get_stdout_pipe ());
        }

        internal async string exchange (string? request, Cancellable token, uint seconds = 30) throws Error {
            var bounded = new Cancellable ();
            ulong handler = token.connect (() => bounded.cancel ());
            uint deadline = Timeout.add_seconds (seconds, () => {
                bounded.cancel ();
                return Source.CONTINUE;
            });
            try {
                if (request != null) {
                    size_t written;
                    yield requests.write_all_async (request.data, Priority.DEFAULT, bounded, out written);
                }
                string? reply = yield replies.read_line_async (Priority.DEFAULT, bounded);
                if (reply == null)
                    throw new IOError.NOT_SUPPORTED ("Authorization was denied or the kernel mount plan is unsupported.");
                return reply;
            } finally {
                Source.remove (deadline);
                token.disconnect (handler);
            }
        }
    }
}
