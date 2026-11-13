// SPDX-License-Identifier: GPL-3.0-or-later
using GLib;

namespace MajorisDisks {
    internal class HardwareSanitizationReview : Object {
        public StorageSanitizationCapability capability = new StorageSanitizationCapability ();
        public string handle;
        public string scope;
        public string phrase;
    }

    internal class HardwareSanitizationOperation : Object {
        public string id;
        public string drive;
        public string state;
        public string detail;
        public int progress;

        public bool terminal () {
            return state == "backend-completed" || state == "device-success" || state == "device-failure" ||
                state == "not-dispatched";
        }
    }

    internal class SanitizationClient : Object {
        private const string NAME = "com.majoris.disks.Sanitization";
        private const string PATH = "/com/majoris/disks/Sanitization";

        private async Variant call (string member, Variant? parameters, string reply, int timeout,
            Cancellable? token = null) throws Error {
            var bus = yield Bus.get (BusType.SYSTEM, token);
            return yield bus.call (NAME, PATH, NAME, member, parameters, new VariantType (reply),
                DBusCallFlags.NONE, timeout, token);
        }

        internal async HardwareSanitizationReview review (string drive, StorageSanitizationMethod method,
            string command, Cancellable token) throws Error {
            var reply = yield call ("Review", new Variant ("(os)", drive, command), "(usss)", 30000, token);
            uint state;
            string handle, scope, reason;
            reply.get ("(usss)", out state, out handle, out scope, out reason);
            if (state == 3 && (handle.length != 64 || scope == ""))
                throw new IOError.INVALID_DATA ("The broker returned an incomplete hardware review.");
            var review = new HardwareSanitizationReview () {
                handle = handle, scope = scope, phrase = state == 3 ? "ERASE " + handle.substring (0, 8) : ""
            };
            review.capability.method = method;
            review.capability.scope = method <= StorageSanitizationMethod.ATA_ENHANCED_SECURITY_ERASE ?
                StorageSanitizationScope.PHYSICAL_DRIVE : StorageSanitizationScope.NVM_SUBSYSTEM;
            review.capability.availability = state <= 3 ? (StorageSanitizationAvailability) state :
                StorageSanitizationAvailability.UNKNOWN;
            review.capability.reason = reason;
            review.capability.backend = NAME;
            return review;
        }

        internal async string start (HardwareSanitizationReview review) throws Error {
            var reply = yield call ("Start", new Variant ("(s)", review.handle), "(s)", int.MAX);
            return reply.get_child_value (0).get_string ();
        }

        internal async HardwareSanitizationOperation[] list (Cancellable? token = null) throws Error {
            var reply = yield call ("ListOperations", null, "(a(ssssi))", 15000, token);
            var operations = new GenericArray<HardwareSanitizationOperation> ();
            var iter = reply.get_child_value (0).iterator ();
            Variant? value;
            while ((value = iter.next_value ()) != null) {
                var op = new HardwareSanitizationOperation ();
                value.get ("(ssssi)", out op.id, out op.drive, out op.state, out op.detail, out op.progress);
                operations.add (op);
            }
            return operations.data;
        }
    }
}
