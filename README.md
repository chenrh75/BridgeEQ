# BridgeEQ

BridgeEQ is a native Apple-silicon macOS app that routes system audio from a virtual device such as BlackHole through a parametric EQ to headphones, speakers, or a DAC.

## Features

- Separate Core Audio input and physical output devices
- Parametric, low/high shelf, and low/high pass filters
- Preamp, output gain, per-band bypass, and global bypass
- Equalizer APO / AutoEQ text import and export
- Stereo input/output peak meters

## Requirements

- macOS 14 or newer on Apple silicon
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), or another virtual audio device
- Xcode 16 or newer to build from source

## Use

1. Set the macOS system output to **BlackHole 2ch**.
2. Open BridgeEQ and allow audio-input access when prompted.
3. Select **BlackHole 2ch** as Input and your headphones, speakers, or DAC as Output.
4. Press **Start**.

To build from source, open `HeadphoneEQ.xcodeproj`, select **My Mac**, and press Run. The built product is named **BridgeEQ**.

The included standalone build is locally signed rather than Apple-notarized. On first launch, you may need to Control-click `BridgeEQ.app` and choose **Open**.
