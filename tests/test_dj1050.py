#!/usr/bin/env python3
"""Tests that do not need the printer attached."""

import importlib.machinery
import io
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
        self.assertEqual(args[args.index("-l") + 1], "0")
        self.assertEqual(args[args.index("-t") + 1], "0")
        self.assertEqual(args[args.index("-x") + 1], "210")
        self.assertEqual(args[args.index("-y") + 1], "297")
        self.assertEqual(args[args.index("--mode") + 1], "Color")
        self.assertEqual(args[args.index("--jpeg-quality") + 1], "0")
        selected = dj.scanimage_args(
            "hpaio:/usb/Deskjet_1050", 600, "color", "a4", Path("/tmp/x.jpg"), True,
            region=(20, 30, 120, 160),
        )
        self.assertEqual(selected[selected.index("-l") + 1], "20")
        self.assertEqual(selected[selected.index("-t") + 1], "30")
        self.assertEqual(selected[selected.index("-x") + 1], "100")
        self.assertEqual(selected[selected.index("-y") + 1], "130")
        full = dj.geometry_args("full")
        self.assertEqual(full[full.index("-x") + 1], "215.9")
        self.assertEqual(dj.parse_region("20,30,120,160", "a4"), (20.0, 30.0, 120.0, 160.0))
        self.assertTrue(dj.io_busy("scanimage: sane_start: Device busy"))
        self.assertTrue(dj.option_rejected("scanimage: attempted to set inactive option jpeg-quality"))

    def test_preview_shows_each_tenth_of_the_page(self):
        width, height = 4, 10
        pixels = bytes([255, 0, 0]) * (width * height)
        payload = b"P6\n# scanner\n%d %d\n255\n" % (width, height) + pixels
        marks = []
        live = Path("/tmp/dj1050-progress-test.jpg")
        raw, got_width, got_height, channels = dj.stream_pnm_preview(
            io.BytesIO(payload), live, marks.append, step=10
        )
        self.assertEqual(marks, [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        self.assertEqual((got_width, got_height, channels), (4, 10, 3))
        self.assertEqual(len(raw), width * height * 3)
        self.assertGreater(live.stat().st_size, 100)

    def test_save_name_keeps_a_real_suffix(self):
        self.assertEqual(dj.normalize_destination(Path("/tmp/page.tiff"), "jpeg").name, "page.tiff")
        self.assertEqual(dj.normalize_destination(Path("/tmp/page.img"), "jpeg").name, "page.jpg")
        self.assertEqual(dj.normalize_destination(Path("/tmp/page"), "pdf").name, "page.pdf")

    def test_local_peer_rejects_other_machines(self):
        local = {"127.0.0.1", "::1", "192.168.1.20"}
        self.assertTrue(dj.is_local_peer("127.0.0.1", local))
        self.assertTrue(dj.is_local_peer("::ffff:127.0.0.1", local))
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
            self.assertLess(caps.find(b"RGB24"), caps.find(b"BlackAndWhite1"))
            self.assertIn(b"image/jpeg", caps)
            self.assertIn(b"image/png", caps)
            self.assertIn(b"image/tiff", caps)
            self.assertIn(b"application/pdf", caps)
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
