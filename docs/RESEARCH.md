# DeskJet 1050 J410 on macOS 27

This Mac is running macOS 27.0.1 on Apple Silicon. CUPS already has a print queue for an HP DeskJet 1050 J410 series and reports **Scanning support: No**. The queue uses Apple's generic HP raster driver, which is why printing works and scanning does not.

## What the hardware actually is

| Item | Value |
| --- | --- |
| Family | HP DeskJet 1050 J410, also sold as 1051, 1055, and 1056 |
| USB ID | `03f0:8911` (decimal vendor 1008, product 35089) |
| Connection | USB only. No Wi-Fi, no AirPrint scan, no embedded web server |
| Scanner | Flatbed CIS, 1200 dpi optical, no document feeder |
| HPLIP record | `deskjet_1050_j410_series` |
| Scan protocol | LEDM (`scan-type=7`) |
| Proprietary plugin | None (`plugin=0`) |
| First scan support | HPLIP 3.11.1, January 2011 |

HP's own developer page lists scan-to-PC as supported through a SANE application, over USB, with no binary plugin. HPLIP 3.11.1 turned on LEDM scanning for this model after 3.10.6 shipped the printer record without a working scan path. The current `models.dat` in HPLIP 3.25.8 still has `scan-type=7`, `io-mfp-mode=1`, and `scan-src=1` (flatbed only).

LEDM is HP's Low End Data Model. The scan job is an XML document posted to `/Scan/Jobs`, and the scanner returns JPEG that was compressed on the device. On this printer that HTTP conversation is not on the network. It is carried over USB, multiplexed with printing (IEEE 1284.4 / HP MUSB) on the same cable.

## Why no HP or Apple scanner driver appears

HP's last Mac software for this all-in-one targeted much older OS X releases. Current macOS prints the DeskJet through the generic CUPS HP driver and does not install an Image Capture device module for it. Image Capture, Preview's Import from Scanner, and Notes look for either:

- a vendor scanner module under `/Library/Image Capture/Devices/`, or
- an AirScan (eSCL) scanner advertised with Bonjour as `_uscan._tcp`

This model provides neither by itself. A DriverKit USB driver is not a usable substitute here: a third-party dext cannot claim HP's USB vendor ID `0x03f0` unless Apple grants that entitlement. The scanner path that loads on macOS 27 is a normal user-space program using libusb.

## What this project installs

1. HPLIP's GPL `hpaio` SANE backend, built for Darwin, with the DeskJet 1050 model names the USB product string actually uses (`Deskjet 1050 J410 series`).
2. A small command, `dj1050-scan`, that selects that device, scans the glass, and writes PDF, JPEG, PNG, or TIFF.
3. A Mac app, DeskJet 1050 Scan, for the same scan.
4. An optional local AirScan bridge on `127.0.0.1:8092` so Image Capture can see the flatbed. Requests from other computers are refused. Ports 8080 and 8081 are left alone because other local tools use them.

Printing stays on the existing CUPS queue. This project does not replace it.

The Darwin build fixes (missing headers, the unused Orblite plugin, an uninitialized device-list call, a USB device-id stall, and a null-handle close) follow the same approach as the public macOS port of `hpaio` for other LEDM printers. The 1050-specific part is the model alias and a device-id string that includes `MDL`, so a stalled `GET_DEVICE_ID` still matches this record.

## Image quality

HP's LEDM scan job in HPLIP 3.25.8 hardcodes `<CompressionQFactor>15</CompressionQFactor>` and ignores the SANE `jpeg-quality` option. HPLIP documents that factor as "larger numbers mean better compression, and smaller numbers mean better image quality." 15 is a soft, blocky JPEG, which is why a color page can look dull. The Windows HP Scan window for this model exposes JPEG, PDF, PNG, and TIFF, plus Color, Grayscale, and Black and white, and its advanced quality control can be set to no compression.

`patches/04-ledm-jpeg-quality.patch` sends the SANE factor instead. `dj1050-scan` passes `0`, the clear end of that scale. The Mac app follows the Windows order: choose Color, scan, look at the page, then save as JPEG, PDF, PNG, or TIFF.

## What was checked on the glass

A later session with the cable connected listed `hpaio:/usb/Deskjet_1050_J410_series` and completed a 1,200 DPI color scan from the app. Image Capture listed the flatbed under Shared and retrieved a page. The JPEG-quality change above is compiled into the backend and still needs one new page on the glass to confirm the picture is clearer.
