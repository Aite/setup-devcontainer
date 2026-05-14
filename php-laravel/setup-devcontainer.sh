#!/bin/zsh
set -euo pipefail

echo "🔧 Setting up Anthropic + Laravel devcontainer with spec-kit..."

# ── 1. Add upstream remote and fetch ──────────────────────
if git remote get-url anthropic-claude &>/dev/null; then
  echo "ℹ️ Remote exists, fetching..."
  git fetch anthropic-claude
else
  echo "➕ Adding anthropic remote..."
  git remote add anthropic-claude https://github.com/anthropics/claude-code.git
  git fetch anthropic-claude
fi

# ── 2. Create/update upstream tracking branch ──────────────────────
if git show-ref --quiet refs/heads/upstream/devcontainer; then
  echo "ℹ️  Branch 'upstream/devcontainer' already exists, updating..."
  git checkout upstream/devcontainer
  git merge anthropic-claude/main
else
  echo "🌿 Creating upstream/devcontainer branch..."
  git checkout -b upstream/devcontainer anthropic-claude/main
fi

# ── 3. Copy .devcontainer into feature/claude-dev-container branch ─────────────────
echo "📁 Copying .devcontainer to current branch..."
git checkout feature/claude-dev-container
git checkout upstream/devcontainer -- .devcontainer/

# ── Commit upstream .devcontainer as-is ───────────────────
git add .devcontainer/

if git diff --cached --quiet; then
  echo "ℹ️  Nothing to commit, working tree clean"
else
  git commit -m "chore: add Anthropic devcontainer from upstream"
fi

# ── 4. Patch Dockerfile ───────────────────────────────────
echo "🐳 Patching Dockerfile..."

DOCKERFILE=".devcontainer/Dockerfile"

if grep -q "Start Laravel customizations" "$DOCKERFILE"; then
  echo "ℹ️ Laravel customizations already exist"
else

cat >> "$DOCKERFILE" <<'EOF'

# ── Start Laravel customizations ──────────────────────────
USER root

RUN apt-get update && apt-get install -y \
    php \
    php-cli \
    php-common \
    php-mysql \
    php-pgsql \
    php-sqlite3 \
    php-mbstring \
    php-xml \
    php-curl \
    php-zip \
    php-gd \
    php-bcmath \
    php-intl \
    php-soap \
    php-common \
    unzip \
    sqlite3 \
    default-mysql-client \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Laravel installer
RUN composer global require laravel/installer

ENV PATH="/root/.composer/vendor/bin:/root/.config/composer/vendor/bin:$PATH"

# Existing Anthropic setup

# Grant node user passwordless sudo for docker socket chmod
RUN groupadd -f docker && usermod -aG docker node \
    && echo "node ALL=(root) NOPASSWD:/bin/chmod 666 /var/run/docker.sock" \
       > /etc/sudoers.d/node-docker \
    && chmod 0440 /etc/sudoers.d/node-docker

# Install uv system-wide
RUN curl -LsSf https://astral.sh/uv/install.sh | \
    env UV_INSTALL_DIR=/usr/local/bin sh

# Install specify-cli
RUN uv tool install specify-cli \
    --from git+https://github.com/github/spec-kit.git@v0.7.3

ENV PATH="/root/.local/bin:$PATH"

USER node

# ── End Laravel customizations ────────────────────────────
EOF

echo "✅ Dockerfile customized"

fi

# ── 5. Patch devcontainer.json ────────────────────────────

echo "🔌 Patching devcontainer.json..."

DEVCONTAINER=".devcontainer/devcontainer.json"

python3 - "$DEVCONTAINER" << 'PYEOF'
import json, sys

path = sys.argv[1]
with open(path, 'r') as f:
    config = json.load(f)

# Add Docker-outside-of-Docker feature
config.setdefault("features",{})

docker_feature = "ghcr.io/devcontainers/features/docker-outside-of-docker:1"
if docker_feature not in config["features"]:
    config["features"][docker_feature] = {}

config.setdefault("mounts",[])

docker_mount="source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"

if docker_mount not in config["mounts"]:
    config["mounts"].append(docker_mount)

# Ports
ports=[8000,5173,3306,5432]

config.setdefault("forwardPorts",[])

for p in ports:
    if p not in config["forwardPorts"]:
        config["forwardPorts"].append(p)

# Laravel setup
post_create = """
if [ -f composer.json ]; then composer install; fi &&
if [ ! -f .env ] && [ -f .env.example ]; then cp .env.example .env; fi &&
php artisan key:generate || true &&
if [ -f package.json ]; then npm install; fi
""".strip()

existing_post_create = config.get("postCreateCommand", "")

if existing_post_create:
    config["postCreateCommand"] = (
        existing_post_create + " && " + post_create
    )
else:
    config["postCreateCommand"] = post_create


# Fix Anthropic postStartCommand so firewall failures don't stop startup
existing_post_start = config.get("postStartCommand", "")

if isinstance(existing_post_start, str):

    if "init-firewall.sh" in existing_post_start:
        existing_post_start = existing_post_start.replace(
            "sudo /usr/local/bin/init-firewall.sh",
            "sudo /usr/local/bin/init-firewall.sh || true"
        )

    chmod_cmd = "sudo chmod 666 /var/run/docker.sock || true"

    if chmod_cmd not in existing_post_start:
        config["postStartCommand"] = (
            existing_post_start + " && " + chmod_cmd
        )
    else:
        config["postStartCommand"] = existing_post_start

elif isinstance(existing_post_start, list):

    updated=[]

    for cmd in existing_post_start:
        if "init-firewall.sh" in cmd:
            cmd=cmd.replace(
                "sudo /usr/local/bin/init-firewall.sh",
                "sudo /usr/local/bin/init-firewall.sh || true"
            )

        updated.append(cmd)

    if "sudo chmod 666 /var/run/docker.sock || true" not in updated:
        updated.append(
            "sudo chmod 666 /var/run/docker.sock || true"
        )

    config["postStartCommand"]=updated

extensions=[
"bmewburn.vscode-intelephense-client",
"xdebug.php-debug",
"onecentlin.laravel-blade",
"amiralizadeh9480.laravel-extra-intellisense",
"MehediDracula.php-namespace-resolver",
"mhutchie.git-graph"
]

try:
    ext=config["customizations"]["vscode"]["extensions"]

    for e in extensions:
        if e not in ext:
            ext.append(e)

except KeyError:
    pass

with open(path,"w") as f:
    json.dump(config,f,indent=2)
    f.write("\n")

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
  git commit -m \
  "install: uv + specify-cli + Laravel tooling + PHP extensions + Anthropic devcontainer; docker-outside-of-docker feature; fix ipset firewall rules; forward common Laravel ports"
fi

echo ""
echo "✅ Done! Devcontainer is ready."
echo "Open project → Reopen in Container"