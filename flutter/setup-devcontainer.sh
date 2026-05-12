#!/bin/zsh
set -euo pipefail

echo "🔧 Setting up Anthropic devcontainer with spec-kit and Flutter..."

# ── 1. Add upstream remote and fetch ──────────────────────
if git remote get-url anthropic-claude &>/dev/null; then
  echo "ℹ️  Remote 'anthropic-claude' already exists, fetching..."
  git fetch anthropic-claude
else
  echo "➕ Adding anthropic-claude remote..."
  git remote add anthropic-claude https://github.com/anthropics/claude-code.git
  git fetch anthropic-claude
fi

# ── 2. Create upstream tracking branch ────────────────────
if git show-ref --quiet refs/heads/upstream/devcontainer; then
  echo "ℹ️  Branch 'upstream/devcontainer' already exists, updating..."
  git checkout upstream/devcontainer
  git merge anthropic-claude/main
else
  echo "🌿 Creating upstream/devcontainer branch..."
  git checkout -b upstream/devcontainer anthropic-claude/main
fi

# ── 3. Copy .devcontainer into main branch ─────────────────
echo "📁 Copying .devcontainer to current branch..."
git checkout main
git checkout upstream/devcontainer -- .devcontainer/

# ── Commit upstream .devcontainer as-is ───────────────────
git add .devcontainer/

if git diff --cached --quiet; then
  echo "ℹ️  Nothing to commit, working tree clean"
else
  git commit -m "chore: add Anthropic devcontainer from upstream"
fi

# ── 4. Apply Dockerfile customizations ────────────────────
echo "🐳 Patching Dockerfile..."

DOCKERFILE=".devcontainer/Dockerfile"

# Append project customizations block if not already present
if grep -q "Start Project customizations" "$DOCKERFILE"; then
  echo "ℹ️  Dockerfile customizations already present, skipping..."
else
  cat >> "$DOCKERFILE" << 'EOF'

# ── Start Project customizations ──────────────────────────
USER root

# Grant node user passwordless sudo for docker socket chmod
RUN groupadd -f docker && usermod -aG docker node \
    && echo "node ALL=(root) NOPASSWD:/bin/chmod 666 /var/run/docker.sock" \
       > /etc/sudoers.d/node-docker \
    && chmod 0440 /etc/sudoers.d/node-docker

# Install uv system-wide
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install specify-cli
RUN uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v0.7.3
ENV PATH="/root/.local/bin:$PATH"

USER node
# ── End Project customizations ────────────────────────────
EOF
  echo "✅ Dockerfile customizations applied"
fi

# ── 5. Force linux/amd64 build platform in Dockerfile ────
# Flutter Linux SDK only ships as x86_64 — no arm64 tarball exists.
# runArgs --platform only affects the running container, NOT the docker buildx
# build step that VS Code Dev Containers CLI invokes. The only reliable way to
# enforce the build platform is to rewrite the FROM line in the Dockerfile itself.
echo "🏗️  Patching Dockerfile FROM line to force linux/amd64..."

if grep -q "FROM --platform=linux/amd64" "$DOCKERFILE"; then
  echo "ℹ️  FROM --platform=linux/amd64 already present, skipping..."
else
  # Replace the first FROM line using Python to avoid sed quoting issues on macOS
  python3 -c "
import sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
patched = content.replace('FROM node:', 'FROM --platform=linux/amd64 node:', 1)
with open(sys.argv[1], 'w') as f:
    f.write(patched)
" "$DOCKERFILE"
  echo "✅ Patched FROM line to FROM --platform=linux/amd64 node:..."
fi

# ── 6. Apply Flutter customizations to Dockerfile ─────────
echo "🐦 Patching Dockerfile with Flutter..."

FLUTTER_VERSION="3.41.0"
ANDROID_SDK_VERSION="11076708"
ANDROID_BUILD_TOOLS_VERSION="35.0.0"
ANDROID_PLATFORM_VERSION="35"

if grep -q "Start Flutter customizations" "$DOCKERFILE"; then
  echo "ℹ️  Flutter Dockerfile customizations already present, skipping..."
else
  cat >> "$DOCKERFILE" << EOF

# ── Start Flutter customizations ──────────────────────────
# macOS host: emulators run on host, container handles build/analyze/test only
# iOS builds run on macOS host (Xcode required); Android connects via ADB over TCP
USER root

ARG FLUTTER_VERSION=${FLUTTER_VERSION}
ARG ANDROID_SDK_VERSION=${ANDROID_SDK_VERSION}
ARG ANDROID_BUILD_TOOLS_VERSION=${ANDROID_BUILD_TOOLS_VERSION}
ARG ANDROID_PLATFORM_VERSION=${ANDROID_PLATFORM_VERSION}

ENV FLUTTER_HOME=/opt/flutter
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV FLUTTER_SUPPRESS_ANALYTICS=true
ENV PATH="\${FLUTTER_HOME}/bin:\${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:\${ANDROID_SDK_ROOT}/platform-tools:\${PATH}"

# Flutter system dependencies (on top of the node:20 base)
RUN apt-get update && apt-get install -y --no-install-recommends \\
    curl xz-utils zip unzip \\
    libglu1-mesa openjdk-17-jdk-headless \\
    clang cmake ninja-build pkg-config \\
    libgtk-3-dev liblzma-dev libstdc++-12-dev \\
    adb \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Flutter SDK — Linux x86_64 only.
# Google does not publish a Linux arm64 Flutter SDK tarball. The FROM line above
# is patched to --platform=linux/amd64 so this binary always matches the
# container platform on both Intel and Apple Silicon Macs.
RUN curl -fsSL \\
       "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_\${FLUTTER_VERSION}-stable.tar.xz" \\
       | tar -xJ -C /opt \\
    && chown -R node:node \${FLUTTER_HOME}

# Android SDK — command-line tools only (no emulator image; emulator runs on macOS host)
RUN mkdir -p \${ANDROID_SDK_ROOT}/cmdline-tools \\
    && curl -fsSL \\
       "https://dl.google.com/android/repository/commandlinetools-linux-\${ANDROID_SDK_VERSION}_latest.zip" \\
       -o /tmp/cmdline-tools.zip \\
    && unzip -q /tmp/cmdline-tools.zip -d \${ANDROID_SDK_ROOT}/cmdline-tools \\
    && mv \${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools \${ANDROID_SDK_ROOT}/cmdline-tools/latest \\
    && rm /tmp/cmdline-tools.zip \\
    && chown -R node:node \${ANDROID_SDK_ROOT}

# Accept Android licenses and install required SDK packages
RUN yes | \${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null 2>&1 \\
    && \${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager \\
       "platform-tools" \\
       "build-tools;\${ANDROID_BUILD_TOOLS_VERSION}" \\
       "platforms;android-\${ANDROID_PLATFORM_VERSION}"

# Flutter config and pre-cache (Android only; iOS toolchain lives on macOS host)
USER node
RUN flutter config --no-analytics \\
    && flutter config --android-sdk \${ANDROID_SDK_ROOT} \\
    && flutter precache --android

# Pub cache volume directory (populated at runtime via devcontainer mount)
RUN mkdir -p /home/node/.pub-cache \\
    && chown -R node:node /home/node/.pub-cache

USER root
# ── End Flutter customizations ────────────────────────────
EOF
  echo "✅ Flutter Dockerfile customizations applied"
fi

# ── 6. Patch devcontainer.json ─────────────────────────────
echo "🔌 Patching devcontainer.json..."

DEVCONTAINER=".devcontainer/devcontainer.json"

python3 - "$DEVCONTAINER" << 'PYEOF'
import json, sys

path = sys.argv[1]
with open(path, 'r') as f:
    config = json.load(f)

if "features" not in config:
    config["features"] = {}
docker_feature = "ghcr.io/devcontainers/features/docker-outside-of-docker:1"
if docker_feature not in config["features"]:
    config["features"][docker_feature] = {}
    print("✅ Added docker-outside-of-docker feature")
else:
    print("ℹ️  docker-outside-of-docker feature already present, skipping...")

# ── Docker socket mount ────────────────────────────────────
mount_docker = "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
if "mounts" not in config:
    config["mounts"] = []
if mount_docker not in config["mounts"]:
    config["mounts"].append(mount_docker)
    print("✅ Docker socket mount added")
else:
    print("ℹ️  Docker socket mount already present, skipping...")

# ── Flutter pub-cache persistent volume ───────────────────
mount_pub = "source=khatm-pub-cache,target=/home/node/.pub-cache,type=volume"
if mount_pub not in config["mounts"]:
    config["mounts"].append(mount_pub)
    print("✅ Flutter pub-cache volume mount added")
else:
    print("ℹ️  Flutter pub-cache volume mount already present, skipping...")

# ── Flutter environment variables ─────────────────────────
if "containerEnv" not in config:
    config["containerEnv"] = {}

flutter_env = {
    # Tell adb inside the container to reach the macOS host emulator over TCP
    # Docker Desktop for macOS exposes the host at host.docker.internal
    "ADB_SERVER_SOCKET":         "tcp:host.docker.internal:5554",
    "ANDROID_SDK_ROOT":          "/opt/android-sdk",
    "FLUTTER_HOME":              "/opt/flutter",
    "FLUTTER_SUPPRESS_ANALYTICS": "true",
}
for key, value in flutter_env.items():
    if key not in config["containerEnv"]:
        config["containerEnv"][key] = value
        print(f"✅ Added containerEnv: {key}")
    else:
        print(f"ℹ️  containerEnv {key} already present, skipping...")

# ── postStartCommand: docker socket chmod + adb connect ───
post_start = config.get("postStartCommand", "")
chmod_cmd  = "sudo chmod 666 /var/run/docker.sock"
adb_cmd    = "adb connect host.docker.internal:5555 || true"

if isinstance(post_start, str):
    if chmod_cmd not in post_start:
        post_start = f"{post_start} && {chmod_cmd}" if post_start else chmod_cmd
        print("✅ Added docker socket chmod to postStartCommand")
    else:
        print("ℹ️  docker socket chmod already in postStartCommand, skipping...")
    if adb_cmd not in post_start:
        post_start = f"{post_start} && {adb_cmd}"
        print("✅ Added adb connect to postStartCommand")
    else:
        print("ℹ️  adb connect already in postStartCommand, skipping...")
    config["postStartCommand"] = post_start
elif isinstance(post_start, list):
    for cmd in [chmod_cmd, adb_cmd]:
        if cmd not in post_start:
            post_start.append(cmd)
            print(f"✅ Added '{cmd}' to postStartCommand")
        else:
            print(f"ℹ️  '{cmd}' already in postStartCommand, skipping...")
    config["postStartCommand"] = post_start

# ── VS Code extensions ─────────────────────────────────────
extensions_to_add = [
    "mhutchie.git-graph",     # git graph (from original script)
    "dart-code.flutter",      # Flutter
    "dart-code.dart-code",    # Dart
    "usernamehw.errorlens",   # inline error highlighting
]
try:
    extensions = config["customizations"]["vscode"]["extensions"]
    for ext in extensions_to_add:
        if ext not in extensions:
            extensions.append(ext)
            print(f"✅ Added extension: {ext}")
        else:
            print(f"ℹ️  Extension {ext} already present, skipping...")
except KeyError:
    print("ℹ️  Could not find customizations.vscode.extensions in devcontainer.json")

# ── VS Code settings for Dart/Flutter ─────────────────────
dart_settings = {
    "dart.flutterSdkPath": "/opt/flutter",
    "dart.debugExternalPackageLibraries": False,
    "dart.debugSdkLibraries": False,
    "[dart]": {
        "editor.defaultFormatter": "Dart-Code.dart-code",
        "editor.formatOnSave": True,
        "editor.formatOnType": True,
        "editor.suggestSelection": "first",
        "editor.tabCompletion": "onlySnippets",
        "editor.wordBasedSuggestions": "off"
    }
}
try:
    settings = config["customizations"]["vscode"].setdefault("settings", {})
    for key, value in dart_settings.items():
        if key not in settings:
            settings[key] = value
            print(f"✅ Added VS Code setting: {key}")
        else:
            print(f"ℹ️  VS Code setting {key} already present, skipping...")
except KeyError:
    print("ℹ️  Could not find customizations.vscode in devcontainer.json")

# ── postCreateCommand: flutter pub get ────────────────────
post_create = config.get("postCreateCommand", "")
pub_get_cmd = "flutter pub get"
if isinstance(post_create, str):
    if pub_get_cmd not in post_create:
        config["postCreateCommand"] = f"{post_create} && {pub_get_cmd}" if post_create else pub_get_cmd
        print("✅ Added flutter pub get to postCreateCommand")
    else:
        print("ℹ️  flutter pub get already in postCreateCommand, skipping...")
elif isinstance(post_create, list):
    if pub_get_cmd not in post_create:
        post_create.append(pub_get_cmd)
        config["postCreateCommand"] = post_create
        print("✅ Added flutter pub get to postCreateCommand")
    else:
        print("ℹ️  flutter pub get already in postCreateCommand, skipping...")

with open(path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print("✅ devcontainer.json patched")
PYEOF

# ── 7. Patch init-firewall.sh ──────────────────────────────
echo "🔥 Patching init-firewall.sh..."

FIREWALL=".devcontainer/init-firewall.sh"

# Fix ipset add for CIDR ranges
if grep -q 'ipset add allowed-domains "\$cidr"' "$FIREWALL"; then
  sed -i '' 's/ipset add allowed-domains "\$cidr"/ipset add --exist allowed-domains "\$cidr"/g' "$FIREWALL"
  echo "✅ Patched ipset add for CIDR ranges"
else
  echo "ℹ️  CIDR ipset line already patched or not found, skipping..."
fi

# Fix ipset add for resolved IPs
if grep -q 'ipset add allowed-domains "\$ip"' "$FIREWALL"; then
  sed -i '' 's/ipset add allowed-domains "\$ip"/ipset add --exist allowed-domains "\$ip"/g' "$FIREWALL"
  echo "✅ Patched ipset add for resolved IPs"
else
  echo "ℹ️  IP ipset line already patched or not found, skipping..."
fi

# Add api.z.ai to the firewall domain whitelist
if grep -q '"api.z.ai"' "$FIREWALL"; then
  echo "ℹ️  api.z.ai already in whitelist, skipping..."
else
  sed -i '' 's/"update.code.visualstudio.com";/"update.code.visualstudio.com" \\\n    "api.z.ai";/' "$FIREWALL"
  echo "✅ Added api.z.ai to firewall whitelist"
fi

# Add Flutter/Android CDN domains to firewall whitelist
# These are required for flutter pub get, precache, and Android SDK tools
FLUTTER_DOMAINS=(
  "storage.googleapis.com"
  "dl.google.com"
  "pub.dev"
  "pub.dartlang.org"
  "dart.dev"
  "flutter.dev"
  "firebase.googleapis.com"
  "crashlytics.googleapis.com"
)

for domain in "${FLUTTER_DOMAINS[@]}"; do
  if grep -q "\"${domain}\"" "$FIREWALL"; then
    echo "ℹ️  ${domain} already in firewall whitelist, skipping..."
  else
    # Insert after the last known domain entry before the closing semicolon block
    sed -i '' "s/\"api.z.ai\";/\"api.z.ai\" \\\\\n    \"${domain}\";/" "$FIREWALL"
    echo "✅ Added ${domain} to firewall whitelist"
  fi
done

# ── 8. Commit all customizations ──────────────────────────
echo "💾 Committing customizations..."

git add "$DOCKERFILE" "$DEVCONTAINER" "$FIREWALL"

if git diff --cached --quiet; then
  echo "ℹ️  No customization changes to commit"
else
  git commit -m "install: uv, specify-cli, Flutter SDK, Android SDK in .devcontainer; docker-outside-of-docker; fix ipset firewall; add Flutter domains to whitelist; add Flutter/Dart VS Code extensions"
fi

echo ""
echo "✅ Done! Devcontainer is ready."
echo ""
echo "   Next steps:"
echo "   1. Open this project in VS Code"
echo "   2. Select 'Reopen in Container' when prompted"
echo "   3. First build takes ~10 min (Flutter SDK + Android SDK download)"
echo "   4. Authenticate Claude Code inside the container: claude"
echo "   5. Run with full permissions: claude --dangerously-skip-permissions"
echo ""
echo "   For iOS/Android testing (macOS host — not in container):"
echo "   • iOS:     open -a Simulator && flutter run"
echo "   • Android: start AVD from Android Studio, then adb tcpip 5555"
echo "              Container auto-connects at startup via host.docker.internal:5555"
