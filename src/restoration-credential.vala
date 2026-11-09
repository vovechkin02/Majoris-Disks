/* SPDX-License-Identifier: GPL-3.0-or-later */
namespace MajorisDisks {
    internal class RestorationCredential : Object {
        internal string passphrase;
        internal string keyfile;
        internal bool managed;
        internal RestorationCredential (string passphrase = "", string keyfile = "", bool managed = false) {
            this.passphrase = passphrase;
            this.keyfile = keyfile;
            this.managed = managed;
        }
    }

    internal abstract class RestorationCredentialProvider : Object {
        internal abstract async RestorationCredential request (string volume) throws Error;
    }
}
