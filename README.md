# HP DeskJet 1050 scanner for macOS

User-space scanner driver for the **HP DeskJet 1050 J410** series (also sold as the 1051, 1055, and 1056) on macOS, including Apple Silicon and macOS 27.

The printer can already print. macOS does not ship a scanner driver for this USB-only model, and HP's old Mac scan software does not load. This project builds HP's open-source LEDM scanner backend and adds a Mac app plus an Image Capture bridge.

USB ID: `03f0:8911`. Flatbed only, up to 1200 dpi. No proprietary HP plugin.

## Install

```bash
cd hp-deskjet-1050-scan
./build.sh
```

`build.sh` installs `sane-backends` and `libusb` with Homebrew if they are missing, downloads HPLIP 3.25.8, builds the `hpaio` scanner backend, and installs **DeskJet 1050 Scan** into `~/Applications`.

## Scan

1. Turn the printer on and connect it with USB.
2. Put the page face down on the glass, against the front-right corner.
3. Open **DeskJet 1050 Scan**, or run:

```bash
dj1050-scan doctor
dj1050-scan --dpi 300 --mode color --paper a4
```

The app scans first and shows the page. **Output type** is Color, Grayscale, or Black and white. **File type** is JPEG, PDF, PNG, or TIFF, and Save asks for that file. Rotate, Lighter, and Darker apply to the preview before it is written.

From the terminal, `--paper` accepts `a4`, `letter`, or `full`. `--format` accepts `pdf`, `jpeg`, `png`, or `tiff`. `--mode` accepts `color`, `gray`, or `lineart`. Color is the default. The scanner is asked for its clearest JPEG, the same idea as HP Scan's "None" compression on Windows.

## Image Capture and Preview

```bash
dj1050-scan bridge --install-agent
```

That starts a small AirScan service on this Mac only (`127.0.0.1:8092`) and advertises the flatbed to Image Capture, Preview, and Notes. Other computers on the network cannot start a scan. The app's **Image Capture** button does the same thing.

Printing continues to use the CUPS queue you already have.

## If a scan says the device is busy

macOS holds the USB printer interface for CUPS. The scan command pauses this model's print queues, scans, and turns them back on. Quit VueScan or HP Smart first if they are open; both try to claim the same USB device.

## Layout

| Path | Role |
| --- | --- |
| `build.sh` | Download HPLIP, apply the macOS and 1050 patches, install the backend and app |
| `bin/dj1050-scan` | Status, scan, and the Image Capture bridge |
| `app/` | SwiftUI app |
| `patches/`, `stubs/` | Darwin build fixes and the 1050 device-id match |
| `docs/RESEARCH.md` | Why this model has no Apple scanner driver, and which protocol it speaks |

## License

GPL-2.0-or-later, the same license as HPLIP. See `LICENSE`.

HPLIP is copyright Hewlett-Packard Development Company, L.P. This repository does not vendor the HPLIP tree; `build.sh` downloads it. The Darwin compile fixes follow the public `hpaio` macOS port at [nricaurte/hp-scan-macos](https://github.com/nricaurte/hp-scan-macos), extended here so a DeskJet 1050 device id matches `deskjet_1050_j410_series`.
