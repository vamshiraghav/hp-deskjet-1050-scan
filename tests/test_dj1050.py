#!/usr/bin/env python3
"""Tests that do not need the printer attached."""

import importlib.machinery
import os
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ["DJ1050_PATH_PREPEND"] = str(ROOT / "tests" / "bin")
os.environ["DJ1050_NO_MDNS"] = "1"

dj = importlib.machinery.SourceFileLoader(
    "dj1050", str(ROOT / "bin" / "dj1050-scan")
).load_module()


class DriverTests(unittest.TestCase):
    def test_picks_1050_ahead_of_another_hp(self):
        listing = "\n".join([
            "device `hpaio:/usb/Smart_Tank_500_series?serial=AAA' is a Smart Tank",
            "device `hpaio:/usb/Deskjet_1050_J410_series?serial=BBB' is a Deskjet 1050",
        ])
        self.assertEqual(
            dj.pick_device(listing),
            "hpaio:/usb/Deskjet_1050_J410_series?serial=BBB",
        )

    def test_a4_geometry_matches_the_glass(self):
        args = dj.scanimage_args("hpaio:/usb/Deskjet_1050", 300, "color", "a4", Path("/tmp/x.jpg"), True)
        self.assertEqual(args[args.index("--br-x") + 1], "210")
        self.assertEqual(args[args.index("--br-y") + 1], "297")
        self.assertEqual(args[args.index("--mode") + 1], "Color")

    def test_local_peer_rejects_other_machines(self):
        local = {"127.0.0.1", "::1", "192.168.1.20"}
        self.assertTrue(dj.is_local_peer("127.0.0.1", local))
        self.assertTrue(dj.is_local_peer("192.168.1.20", local))
        self.assertFalse(dj.is_local_peer("8.8.8.8", local))
        self.assertFalse(dj.is_local_peer("192.168.1.55", local))

    def test_escl_scan_returns_jpeg(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), dj.EsclHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        try:
            base = f"http://127.0.0.1:{port}"
            caps = urllib.request.urlopen(base + "/eSCL/ScannerCapabilities", timeout=5).read()
            self.assertIn(b"HP DeskJet 1050 J410", caps)
            self.assertIn(b"1200", caps)
            body = b"""<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
              <scan:XResolution>300</scan:XResolution>
              <scan:ColorMode>RGB24</scan:ColorMode>
              <scan:DocumentFormat>image/jpeg</scan:DocumentFormat>
            </scan:ScanSettings>"""
            request = urllib.request.Request(base + "/eSCL/ScanJobs", data=body, method="POST")
            created = urllib.request.urlopen(request, timeout=5)
            self.assertEqual(created.status, 201)
            location = created.headers["Location"]
            page = urllib.request.urlopen(location + "/NextDocument", timeout=10)
            data = page.read()
            self.assertTrue(data.startswith(b"\xff\xd8"), data[:8])
        finally:
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
