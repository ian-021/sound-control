# SoundSystem

Per-app volume for macOS, in the menu bar. Click the sliders icon for a slider and mute button per app.

    scripts/install.sh      # build and install to /Applications (needs Xcode, macOS 26+)

macOS asks for audio access the first time you change a volume, and again after each reinstall.

To also open it from Control Center: Control Center > Edit Controls > App Volumes.
(macOS only lets apps add buttons and toggles there, so the sliders themselves live in the menu bar panel.)

## How it works

Apps at 100% are never touched. Changing one creates a Core Audio process tap that diverts that app's
sound, and a private aggregate device plays it back scaled. A muted app is just a tap, with nothing played.
If SoundSystem quits or crashes, macOS removes the taps and every app returns to normal.

- `Audio/AudioEngine.swift` – tracks which apps are playing and keeps taps in line with your settings
- `Audio/ProcessTap.swift` – one app on one output device
- `Audio/Renderer.c` – the real-time gain loop
- `Audio/AppResolver.swift` – maps helper processes to the app you recognise
- `UI/` – the panel; `SoundSystemControls/` – the Control Center button
