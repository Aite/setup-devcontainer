#!/bin/zsh
set -euo pipefail

echo "🔧 Setting up Anthropic devcontainer with spec-kit..."

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

# ── 5. Patch devcontainer.json ─────────────────────────────
echo "🔌 Patching devcontainer.json..."

DEVCONTAINER=".devcontainer/devcontainer.json"

python3 - "$DEVCONTAINER" << 'PYEOF'
import json, sys

path = sys.argv[1]
with open(path, 'r') as f:
    config = json.load(f)

# Add Docker-outside-of-Docker feature
if "features" not in config:
    config["features"] = {}
docker_feature = "ghcr.io/devcontainers/features/docker-outside-of-docker:1"
if docker_feature not in config["features"]:
    config["features"][docker_feature] = {}
    print("✅ Added docker-outside-of-docker feature")
else:
    print("ℹ️  docker-outside-of-docker feature already present, skipping...")

# Add Docker socket mount
mount = "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
if "mounts" not in config:
    config["mounts"] = []
if mount not in config["mounts"]:
    config["mounts"].append(mount)
    print("✅ Docker socket mount added")
else:
    print("ℹ️  Docker socket mount already present, skipping...")

# Fix postStartCommand to also chmod the docker socket
post_start = config.get("postStartCommand", "")
chmod_cmd = "sudo chmod 666 /var/run/docker.sock"

if isinstance(post_start, str):
    if chmod_cmd not in post_start:
        config["postStartCommand"] = f"{post_start} && {chmod_cmd}" if post_start else chmod_cmd
        print("✅ Added docker socket chmod to postStartCommand")
    else:
        print("ℹ️  docker socket chmod already in postStartCommand, skipping...")
elif isinstance(post_start, list):
    if chmod_cmd not in post_start:
        post_start.append(chmod_cmd)
        config["postStartCommand"] = post_start
        print("✅ Added docker socket chmod to postStartCommand")
    else:
        print("ℹ️  docker socket chmod already in postStartCommand, skipping...")

# Add git-graph extension
extension = "mhutchie.git-graph"
try:
    extensions = config["customizations"]["vscode"]["extensions"]
    if extension not in extensions:
        extensions.append(extension)
        print(f"✅ Added {extension} extension")
    else:
        print(f"ℹ️  {extension} already present, skipping...")
except KeyError:
    print(f"ℹ️  Could not find customizations.vscode.extensions in devcontainer.json")

with open(path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF

# ── 6. Patch init-firewall.sh ──────────────────────────────
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

# ── 7. Commit customizations ──────────────────────────────
echo "💾 Committing customizations..."

git add "$DOCKERFILE" "$DEVCONTAINER" "$FIREWALL"

if git diff --cached --quiet; then
  echo "ℹ️  No customization changes to commit"
else
  git commit -m "install: uv, specify-cli in .devcontainer; docker-outside-of-docker feature; fix ipset firewall; add git-graph extension"
fi

echo ""
echo "✅ Done! Devcontainer is ready."
echo "   Open this project in VS Code and select 'Reopen in Container'."