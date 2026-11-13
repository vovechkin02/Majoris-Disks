#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
import fcntl
import hashlib
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import threading
import time
import uuid

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS = os.environ["DBUS_SESSION_BUS_ADDRESS"]
SERVICE = "com.majoris.disks.Sanitization.Test"
OBJECT = "/com/majoris/disks/Sanitization"
DRIVE = "/org/freedesktop/UDisks2/drives/Fixture"
ATA = "org.freedesktop.UDisks2.Drive.Ata"
NVME = "org.freedesktop.UDisks2.NVMe.Controller"
POLKIT = "org.freedesktop.PolicyKit1"
DBUS = "org.freedesktop.DBus"
AUTHORITY = "/org/freedesktop/PolicyKit1/Authority"

XML = f"""<node>
<interface name="com.majoris.disks.Fixture"><method name="Inspect">
<arg type="u" direction="in"/><arg type="b" direction="in"/>
<arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/>
<arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="u" direction="out"/>
<arg type="i" direction="out"/></method></interface>
<interface name="{ATA}"><method name="SecurityEraseUnit"><arg type="a{{sv}}" direction="in"/></method></interface>
<interface name="{NVME}"><method name="SanitizeStart"><arg type="s" direction="in"/>
<arg type="a{{sv}}" direction="in"/></method></interface>
<interface name="{POLKIT}.Authority"><method name="CheckAuthorization">
<arg type="(sa{{sv}})" direction="in"/><arg type="s" direction="in"/>
<arg type="a{{ss}}" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
<arg type="(bba{{ss}})" direction="out"/></method></interface></node>"""


def connection():
    return Gio.DBusConnection.new_for_address_sync(
        BUS, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
        Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


def call(bus, name, obj, iface, member, args=None):
    return bus.call_sync(name, obj, iface, member, args, None, Gio.DBusCallFlags.NONE, 10000, None)


class Hardware:
    outcome = "available"
    identity = "diskseq:2,capacity:1024,namespace:1\n"
    status = "never_sanitized"
    command = 0
    remaining = -1
    auth = "approve"
    mode = "success"
    owner_override = None
    after_inspection = None
    on_authorization = None

    def __init__(self):
        self.ready = threading.Event()
        self.calls = []
        self.subjects = []
        threading.Thread(target=self.run, daemon=True).start()
        assert self.ready.wait(5)

    def run(self):
        self.bus = connection()
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        for interface in node.interfaces:
            obj = AUTHORITY if interface.name.endswith(".Authority") else DRIVE
            self.bus.register_object(obj, interface, self.handle, None, None)
        for name in ("org.freedesktop.UDisks2", POLKIT):
            result = call(self.bus, DBUS, "/org/freedesktop/DBus", DBUS, "RequestName",
                          GLib.Variant("(su)", (name, 4)))
            assert result.unpack() == (1,)
        self.ready.set()
        GLib.MainLoop().run()

    def handle(self, bus, _sender, _path, iface, member, args, invocation):
        if member == "Inspect":
            invocation.return_value(GLib.Variant("(sssssui)", (
                (self.owner_override or bus.get_unique_name()), self.outcome, self.identity, self.status, "/dev/fixture",
                self.command, self.remaining)))
            if self.after_inspection:
                self.after_inspection()
            return
        if member == "CheckAuthorization":
            subject, action, _, interaction, _ = args.unpack()
            self.subjects.append((subject, action, interaction))
            if self.auth == "change":
                self.identity += "changed\n"
            if self.on_authorization:
                self.on_authorization()
            invocation.return_value(GLib.Variant("((bba{ss}))", ((
                self.auth in ("approve", "change"), False,
                {"polkit.dismissed": "true"} if self.auth == "cancel" else {}),)))
            return
        self.calls.append((iface, member, args))
        if self.mode == "lost":
            self.lost = invocation
        elif self.mode == "error":
            invocation.return_dbus_error("org.freedesktop.UDisks2.Error.Failed", "Fixture command error")
        elif self.mode == "owner-error":
            invocation.return_dbus_error("org.freedesktop.DBus.Error.NameHasNoOwner",
                                         "Backend returned a bus-like error after receiving the call")
        else:
            invocation.return_value(GLib.Variant("()", ()))


def broker_call(client, member, args=None):
    return call(client, SERVICE, OBJECT, SERVICE, member, args)


def wait_for(fn, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for broker state")


def review(client, method, availability=3):
    state, token, scope, _ = broker_call(client, "Review", GLib.Variant("(os)", (DRIVE, method))).unpack()
    assert state == availability, (method, state, availability)
    assert bool(token) == bool(scope) == (availability == 3)
    return token


def start(client, token):
    return broker_call(client, "Start", GLib.Variant("(s)", (token,))).unpack()[0]


def rejected(client, token, code):
    try:
        start(client, token)
    except GLib.Error as error:
        assert Gio.DBusError.get_remote_error(error) == SERVICE + ".Error." + code, error
    else:
        raise AssertionError("Unexpected dispatch")


def status(client, id_, expected, progress=None):
    def found():
        entries, = broker_call(client, "ListOperations").unpack()
        return any(row[0] == id_ and row[2] == expected and (progress is None or row[4] == progress)
                   for row in entries)
    wait_for(found)


def run(fixture):
    client, other = connection(), connection()
    hardware = Hardware()

    def launch(directory):
        process = subprocess.Popen([fixture, directory])
        def registered():
            assert process.poll() is None
            return call(client, DBUS, "/org/freedesktop/DBus", DBUS, "NameHasOwner",
                        GLib.Variant("(s)", (SERVICE,))).unpack()[0]
        wait_for(registered)
        return process

    def verify_call(index, method):
        iface, member, args = wait_for(lambda: hardware.calls[index] if len(hardware.calls) > index else None)
        options = args.get_child_value(args.n_children() - 1)
        assert options.lookup_value("auth.no_user_interaction", GLib.VariantType("b")).get_boolean()
        if method.startswith("ata"):
            assert (iface, member, args.get_type_string()) == (ATA, "SecurityEraseUnit", "(a{sv})")
            assert options.lookup_value("enhanced", GLib.VariantType("b")).get_boolean() == (method == "ata-enhanced")
        else:
            assert (iface, member, args.get_type_string()) == (NVME, "SanitizeStart", "(sa{sv})")
            assert args.get_child_value(0).get_string() == method
            if method == "overwrite":
                for key, signature, value in (("overwrite_pass_count", "y", 1),
                                              ("overwrite_pattern", "u", 0),
                                              ("overwrite_invert_pattern", "b", False)):
                    assert options.lookup_value(key, GLib.VariantType(signature)).unpack() == value
            else:
                assert options.n_children() == 1

    with tempfile.TemporaryDirectory() as directory:
        process = launch(directory)
        try:
            for availability, reason in ((1, "unsupported"), (0, "unknown"), (2, "frozen"),
                    (2, "duplicate identity"), (2, "mounted partition"), (2, "active LUKS"),
                    (2, "active LVM"), (2, "active RAID"), (2, "active Btrfs"),
                    (2, "another namespace is system critical"), (2, "shared controller"),
                    (2, "inaccessible namespace"), (2, "USB bridge"), (2, "NVMe-oF"),
                    (2, "already running"), (2, "unknown holder")):
                hardware.outcome = reason
                review(client, "ata-enhanced" if reason == "frozen" else "block-erase", availability)
            hardware.outcome = "available"
            token = review(client, "ata-normal")
            rejected(other, token, "Review")
            for auth, code in (("deny", "AuthorizationDenied"), ("cancel", "AuthorizationCancelled"),
                               ("change", "Rejected")):
                hardware.auth = auth
                rejected(client, token, code)
                rejected(client, token, "Review")
                token = review(client, "ata-normal")
            assert not hardware.calls
            lock_path = Path(directory) / (hashlib.sha256(b"fixture-scope").hexdigest() + ".lock")
            with lock_path.open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rejected(client, token, "Busy")
            assert not hardware.calls
            hardware.auth = "approve"
            for field, changed in (
                ("identity", "diskseq:3,capacity:1024,namespace:1\n"),
                ("identity", "diskseq:2,capacity:2048,namespace:1\n"),
                ("identity", "changed ATA serial\n"),
                ("identity", "changed ATA WWN\n"),
                ("identity", "changed controller or subsystem NQN\n"),
                ("identity", "namespace appeared\n"),
                ("identity", "namespace disappeared\n"),
                ("identity", "namespace ID reused\n"),
                ("outcome", "mounted"),
                ("outcome", "holder appeared"),
                ("outcome", "root dependency"),
                ("outcome", "frozen"),
                ("status", "inprogress"),
                ("owner_override", other.get_unique_name()),
                ("outcome", "selected object disappeared"),
                ("identity", "object path reused\n"),
            ):
                token = review(client, "block-erase")
                original = getattr(hardware, field)

                def change_after_first_validation():
                    hardware.after_inspection = None
                    setattr(hardware, field, changed)

                def arm_after_authorization():
                    hardware.after_inspection = change_after_first_validation

                hardware.on_authorization = arm_after_authorization
                rejected(client, token, "Rejected")
                hardware.on_authorization = None
                setattr(hardware, field, original)
                assert not hardware.calls

            for index, method in enumerate(("ata-normal", "ata-enhanced", "block-erase", "crypto-erase", "overwrite")):
                op = start(client, review(client, method))
                verify_call(index, method)
                if method.startswith("ata"):
                    status(client, op, "backend-completed")
                else:
                    hardware.command = {"block-erase": 2, "crypto-erase": 4, "overwrite": 19}[method]
                    hardware.status = "inprogress"
                    hardware.remaining = 75
                    status(client, op, "running", 25)
                    hardware.remaining = 25
                    status(client, op, "running", 75)
                    hardware.status = "failure" if method == "crypto-erase" else "success"
                    status(client, op, "device-failure" if method == "crypto-erase" else "device-success")
                    hardware.status = "never_sanitized"
            for subject, action, interaction in hardware.subjects:
                assert subject == ("system-bus-name", {"name": client.get_unique_name()})
                assert action == "com.majoris.disks.Sanitization.erase" and interaction == 1
            hardware.mode = "lost"
            hardware.status, hardware.command = "success", 19
            op = start(client, review(client, "overwrite"))
            verify_call(5, "overwrite")
            hardware.lost.return_dbus_error("org.freedesktop.DBus.Error.NoReply", "Lost reply")
            status(client, op, "uncertain")
            review(client, "overwrite", 2)
            hardware.status, hardware.remaining = "inprogress", 40
            status(client, op, "running", 60)
            hardware.status = "success"
            status(client, op, "uncertain")
            hardware.owner_override = other.get_unique_name()
            hardware.status, hardware.remaining = "inprogress", -1
            status(client, op, "running", -1)
            hardware.status = "success"
            status(client, op, "uncertain")
            process.terminate()
            process.wait(5)
            process = launch(directory)
            status(client, op, "uncertain")
            review(client, "overwrite", 2)
            assert len(hardware.calls) == 6
        finally:
            process.terminate()
            process.wait(5)
    with tempfile.TemporaryDirectory() as directory:
        process = launch(directory)
        try:
            hardware.owner_override = None
            hardware.mode = "owner-error"
            op = start(client, review(client, "ata-normal"))
            verify_call(6, "ata-normal")
            status(client, op, "uncertain")
            review(client, "ata-normal", 2)
            if os.getuid() == 0:
                audit, = broker_call(client, "ReviewHistory", GLib.Variant("(s)", (op,))).unpack()
                assert "classification=result-uncertain" in audit
                records = list(Path(directory).glob(f"{op}.*.review"))
                assert len(records) == 1 and records[0].stat().st_mode & 0o777 == 0o600
                review(client, "ata-normal", 2)
            process.terminate()
            process.wait(5)
            before_dispatch = str(uuid.uuid4())
            contents = (Path(directory) / f"{op}.ini").read_text()
            checkpoint = Path(directory) / f"{before_dispatch}.ini"
            checkpoint.touch(mode=0o600)
            checkpoint.write_text(contents.replace("state=uncertain", "state=dispatch-not-reached")
                                  .replace("scope-key=fixture-scope", "scope-key=separate-fixture-scope"))
            process = launch(directory)
            status(client, before_dispatch, "not-dispatched")
            status(client, op, "uncertain")
            review(client, "ata-normal", 2)
            assert len(hardware.calls) == 7
        finally:
            process.terminate()
            process.wait(5)
    print("Passed isolated ATA/NVMe broker dispatch, authorization, status, lost reply and restart")


if __name__ == "__main__":
    run(sys.argv[1])
