# BridgeEQ

BridgeEQ is an all-in-one Apple-silicon macOS equalizer. It captures system audio using a private Core Audio process tap, applies parametric EQ, and plays it through headphones, speakers, or a DAC. No BlackHole or installed audio driver is required.

## Features

- System audio capture with a selectable physical output
- Parametric, low/high shelf, and low/high pass filters
- Preamp, output gain, per-band bypass, and global bypass
- Equalizer APO / AutoEQ text import and export
- Stereo input/output peak meters

## Requirements

- macOS 14.2 or newer on Apple silicon
- Xcode 16 or newer to build from source

## Use

Download and extract [BridgeEQ-Standalone.zip](BridgeEQ-Standalone.zip), then move `BridgeEQ.app` to Applications. The included app is version **0.3.0 (build 8)**, locally signed and not Apple-notarized. If macOS blocks first launch, use System Settings → Privacy & Security → Open Anyway after attempting to open it.

1. Keep the macOS system output set to a physical device. If you previously used BlackHole, switch back to headphones, speakers, or a DAC.
2. Open BridgeEQ and select your headphones, speakers, or DAC in **Output**.
3. Press **Start** and allow System Audio Recording when prompted. If necessary, enable BridgeEQ in System Settings → Privacy & Security → Screen & System Audio Recording and relaunch it.
4. Play audio and adjust EQ. Press **Stop** to restore ordinary playback.

The tap excludes BridgeEQ's own audio to prevent feedback, and mutes the original audio only while capture is active. Audio stays on your Mac; the app does not record or upload it. The macOS default output is never changed by BridgeEQ. Output selection changes restart the route automatically. If an output disconnects, the app retries the selected device for up to eight seconds rather than switching to speakers.

This is an experimental capture backend. Verify permission handling, audible EQ, start/stop restoration, device switching, sleep/wake, different sample rates, and sustained playback on your devices before using it as your everyday route. Protected content or apps using unusual/exclusive audio paths may not be capturable. Capture and playback use separate clocks and a bounded buffer pool; long-run latency and drift still require hardware testing.

## Build from source

Open `HeadphoneEQ.xcodeproj`, select **My Mac**, and press Run. The built product is named **BridgeEQ**.

## Route verification

`BridgeEQ.app/Contents/MacOS/BridgeEQ --smoke-test-route` starts a route briefly, checks that it stays running and leaves the macOS default output unchanged, stops, and exits. Set `BRIDGEEQ_ROUTE_TEST_SECONDS` to change the duration.

For a signal check, compile and run the separate tone producer:

```sh
xcrun swiftc Tests/RouteSignalCheck.swift -o /tmp/BridgeEQ-RouteSignalCheck
/tmp/BridgeEQ-RouteSignalCheck /absolute/path/to/BridgeEQ.app
```

This plays a quiet tone, runs BridgeEQ with a temporary −12 dB preamp, and checks for nonzero input/output meters and measured attenuation within 1 dB. It leaves saved presets untouched, stops routing, and removes the generated tone. The signal includes any other apps currently playing, so this checks the processing path rather than isolating one app. The built app needs local signing and system audio permission for runtime checks.

The all-in-one route has passed a local startup/stop check and a signal test measuring −12.0 dB attenuation on external headphones. Sleep/wake, device changes, different sample rates, and extended playback still need broader testing.
