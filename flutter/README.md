# Khatm — Dev Environment Setup

## Architecture

```
┌──────────────────────────────────────┐    ┌─────────────────────────────────────┐
│  VS Code Window — Dev Container      │    │  macOS Host                         │
│                                      │    │                                     │
│  • Claude Code (--dangerously-skip)  │    │  • iOS Simulator (Xcode)            │
│  • Flutter SDK (build + analyze)     │◄──►│  • Android Emulator (ADB over TCP)  │
│  • dart analyze / flutter test       │    │  • VS Code (second window, optional)│
│  • git / gh / spec-kit               │    │  • Physical device via USB           │
└──────────────────────────────────────┘    └─────────────────────────────────────┘
         Docker Container                              macOS
    node:20 (Debian) base image              (simulators + physical devices)
         (isolated, safe)
```

Claude Code runs inside Docker with full permissions. Your macOS filesystem is
protected — the container only mounts the project folder at `/workspace`.

Simulators and emulators run on the macOS host because:
- iOS Simulator requires macOS Hypervisor.framework — not available in Docker
- Android KVM hardware acceleration is Linux-only — not available in macOS Docker

The container connects to the Android emulator on the host over ADB TCP via
Docker Desktop's built-in `host.docker.internal` DNS name.

---

## Prerequisites — Install on macOS Host

### 1. Docker Desktop
Download from https://www.docker.com/products/docker-desktop/

Recommended resource allocation (Docker Desktop → Settings → Resources):
- CPUs: 4 or more
- Memory: 8 GB or more
- Disk: 60 GB or more (Flutter SDK + Android SDK + pub cache)

### 2. VS Code
Download from https://code.visualstudio.com/

Install the Dev Containers extension:
```bash
code --install-extension ms-vscode-remote.remote-containers
```

### 3. Flutter on macOS host (required for iOS + Android device/simulator)
```bash
# Using Homebrew
brew install --cask flutter

# Or manually — https://docs.flutter.dev/get-started/install/macos
```

Verify:
```bash
flutter doctor
```

### 4. Xcode (for iOS Simulator)
Install from the Mac App Store, then run:
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### 5. Android Studio (AVD Manager only — not your daily IDE)
Download from https://developer.android.com/studio

After install: open Android Studio → Virtual Device Manager → create a Pixel
device with an **x86_64 system image, API 35**. You do not need to use Android
Studio as your daily editor.

---

## First-Time Setup

### Step 1 — Clone the project
```bash
git clone <repo-url> khatm
cd khatm
```

### Step 2 — Run the setup script
The setup script pulls the upstream Anthropic devcontainer, applies the Flutter
and spec-kit customisations, and patches the firewall whitelist. Run it once from
the project root:
```bash
zsh setup-devcontainer.sh
```

This creates `.devcontainer/` with a patched `Dockerfile`, `devcontainer.json`,
and `init-firewall.sh`. The script is idempotent — safe to re-run after pulling
upstream changes.

### Step 3 — Open in VS Code and reopen in container
```bash
code .
```

When VS Code opens, click **Reopen in Container** in the notification popup, or
open the Command Palette (⌘⇧P) and run:
> Dev Containers: Reopen in Container

The first build takes **10–15 minutes** (Flutter SDK + Android SDK download +
Node.js + Claude Code install). Subsequent starts take under 30 seconds.

### Step 4 — Authenticate Claude Code
In the container terminal (zsh):
```zsh
claude
```

Follow the OAuth flow to sign in. Your credentials are stored in the
`claude-code-config-<devcontainerId>` Docker volume and persist across rebuilds.

To use an API key instead:
```zsh
export ANTHROPIC_API_KEY=sk-ant-...
# To persist across sessions, add to ~/.zshrc inside the container
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.zshrc
```

### Step 5 — Run Claude Code with full permissions
```zsh
claude --dangerously-skip-permissions
```

This is safe because the container is fully isolated from your macOS host.
Claude can only touch files inside `/workspace`.

---

## Daily Workflow

### Claude Code — inside container terminal (zsh)
```zsh
# Interactive session with full permissions
claude --dangerously-skip-permissions

# One-shot command
claude --dangerously-skip-permissions -p "Run flutter analyze and fix all warnings"

# spec-kit slash commands are available inside the container
/speckit.specify
/speckit.plan
/speckit.implement
```

### flutter analyze and tests — inside container
```zsh
# Static analysis
flutter analyze

# Unit + widget tests
flutter test

# With coverage report
flutter test --coverage
```

### Running on iOS Simulator — macOS host only
Open a **native macOS terminal** (not the VS Code container terminal):
```bash
cd /path/to/khatm        # same project folder on disk
open -a Simulator        # or launch a simulator from Xcode
flutter run              # auto-detects the running simulator
```

Hot reload (`r`) and hot restart (`R`) work normally from the host terminal.

### Running on Android Emulator — host emulator, container ADB bridge

**Step 1** — Start the emulator on the macOS host:
```bash
# In a native macOS terminal
~/Library/Android/sdk/emulator/emulator -avd <your_avd_name> &
```

**Step 2** — Enable ADB over TCP on the macOS host:
```bash
adb tcpip 5555
```

**Step 3** — The container connects automatically at startup via `postStartCommand`.
Verify inside the container:
```zsh
adb devices
# Expected: host.docker.internal:5555   device
```

If the device does not appear, reconnect manually:
```zsh
adb connect host.docker.internal:5555
```

**Step 4** — Run from the **macOS host terminal** (hot reload works):
```bash
flutter run
```

To run integration tests against the connected emulator from **inside the container**:
```zsh
flutter test integration_test/
```

### Running on a physical device (USB)
Connect your iPhone or Android device via USB to the Mac. Run from the
**macOS host terminal** — USB devices cannot be forwarded into the container:
```bash
flutter devices      # verify the device appears
flutter run
```

---

## Persistent Volumes

The container uses named Docker volumes that survive rebuilds. Volume names
include the devcontainer ID so each project workspace gets its own isolated set.

| Volume | Contents | Survives rebuild? |
|---|---|---|
| `claude-code-config-<devcontainerId>` | Claude Code auth + session history | ✅ Yes |
| `claude-code-bashhistory-<devcontainerId>` | Shell (zsh) history | ✅ Yes |
| `khatm-pub-cache` | Flutter pub cache (`~/.pub-cache`) | ✅ Yes |

The Android SDK and Flutter SDK are **baked into the container image** — they are
not volumes. Wiping volumes does not remove them; only a full container rebuild does.

To find and wipe the pub cache volume:
```bash
docker volume ls | grep khatm-pub-cache
docker volume rm khatm-pub-cache
```

To wipe Claude auth and force re-authentication:
```bash
docker volume ls | grep claude-code-config
docker volume rm <full-volume-name>
```

---

## Rebuilding the Container

After any changes to `Dockerfile`, `devcontainer.json`, or `init-firewall.sh`
(e.g. after re-running `setup-devcontainer.sh` to pull upstream updates):

Command Palette (⌘⇧P) → **Dev Containers: Rebuild Container**

Volumes are preserved. Only the image layer is rebuilt.

---

## Updating the Flutter SDK Version

The Flutter version is set as a shell variable at the top of step 5 in
`setup-devcontainer.sh`. To update:

1. Edit `setup-devcontainer.sh` — change `FLUTTER_VERSION` in step 5
2. Re-run: `zsh setup-devcontainer.sh`
3. Rebuild: Command Palette → Dev Containers: Rebuild Container
4. Update Flutter on your macOS host to match: `flutter upgrade`

---

## Troubleshooting

### "adb: no devices/emulators found" inside the container
The Android emulator may not be running on the host, or ADB TCP was not enabled.

On the macOS host:
```bash
adb tcpip 5555
adb devices    # confirm the emulator appears here first
```

Then inside the container:
```zsh
adb connect host.docker.internal:5555
adb devices    # should show: host.docker.internal:5555  device
```

### Network errors during flutter pub get or SDK tools
The container runs a strict outbound firewall (`init-firewall.sh`). All Flutter,
Dart, and Android CDN domains are whitelisted by the setup script. If you hit an
unexpected network failure for a new domain:

1. Edit `setup-devcontainer.sh` — add the domain to the `FLUTTER_DOMAINS` array
   in step 7
2. Re-run the script and rebuild the container

### Claude Code authentication lost after rebuild
Credentials live in a named volume and survive rebuilds. If lost, the volume was
likely deleted manually. Re-authenticate:
```zsh
claude
```

### flutter doctor shows iOS/macOS warnings inside the container
Expected — Xcode and the iOS toolchain live on macOS, not in the container.
Only the Android toolchain should be fully green inside the container.

### Container build fails on Apple Silicon (M1/M2/M3/M4)
The Flutter Linux SDK is x86_64 only — Google does not publish a Linux arm64
tarball. The setup script patches the `FROM` line in the Dockerfile to
`FROM --platform=linux/amd64 node:20`, forcing Docker Desktop to build and run
the container as x86_64 via Rosetta 2. This is the only reliable fix —
`runArgs` only affects the running container, not the `docker buildx build` step
that VS Code invokes.

If you see `rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2`:
1. Re-run `zsh setup-devcontainer.sh` from the project root
2. Confirm the Dockerfile now starts with `FROM --platform=linux/amd64 node:20`
3. Rebuild: Command Palette → Dev Containers: Rebuild Container

Ensure Docker Desktop has Rosetta enabled:
- **Use Virtualization framework** enabled (Settings → General)
- **Use Rosetta for x86/amd64 emulation** enabled (Settings → General)

---

## Project Directory Structure

```
khatm/
├── .devcontainer/
│   ├── devcontainer.json     ← generated by setup-devcontainer.sh
│   ├── Dockerfile            ← generated by setup-devcontainer.sh
│   ├── init-firewall.sh      ← generated by setup-devcontainer.sh
│   └── README.md             ← this file
├── setup-devcontainer.sh     ← run once (or after upstream updates)
├── lib/
│   ├── core/
│   │   ├── audio/
│   │   ├── database/
│   │   ├── network/
│   │   └── utils/
│   ├── features/
│   │   ├── khatm/
│   │   ├── player/
│   │   └── recitation/
│   └── main.dart
├── test/
├── integration_test/
└── pubspec.yaml
```
