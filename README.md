# BridgeEQ

A system audio equalizer for Apple-silicon Macs running macOS 14.2 or later.

## Install and use

1. Download and extract [BridgeEQ-Standalone.zip](BridgeEQ-Standalone.zip), then move **BridgeEQ.app** to Applications.
2. Open BridgeEQ and choose your headphones, speakers, or DAC in **Output**.
3. Press **Start** and allow **System Audio Recording** when prompted.
4. Adjust the EQ bands, preamp, and output gain. Press **Stop** to return to ordinary playback.

If macOS blocks opening the app, go to **System Settings → Privacy & Security → Open Anyway** after attempting to open it. The app is locally signed and is not Apple-notarized.

If audio capture is unavailable, enable BridgeEQ under **System Settings → Privacy & Security → Screen & System Audio Recording**, then relaunch it.

## EQ and presets

- Choose parametric, shelf, or pass filters; set frequency, gain, and Q.
- Use each band’s checkbox or **Bypass EQ** to compare settings.
- Open **EQ curve** to view the combined response.
- Choose a saved preset from **Preset**. **Save** updates it or asks for a name for new settings.
- The **…** menu contains **Save As…**, **Delete preset**, **Import APO / AutoEQ…**, and **Export…**.

BridgeEQ processes audio locally and remembers your settings. Some protected audio may be unavailable for capture.
