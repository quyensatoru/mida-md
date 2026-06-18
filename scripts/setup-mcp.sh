#!/usr/bin/env bash
# setup-mcp.sh — One-time setup for mida-skills MCP servers
# Run: bash .agents/scripts/setup-mcp.sh

set -e

SETTINGS_LOCAL="$HOME/.claude/settings.local.json"

echo ""
echo "=== mida-skills MCP Setup ==="
echo ""
echo "This script configures FIGMA_API_KEY for the Figma Developer MCP."
echo "(Shopify Dev MCP needs no API key.)"
echo ""

# --- Read existing settings.local.json or start fresh ---
if [ -f "$SETTINGS_LOCAL" ]; then
  existing=$(cat "$SETTINGS_LOCAL")
else
  existing="{}"
fi

# --- Check if key is already set ---
if echo "$existing" | grep -q "FIGMA_API_KEY"; then
  echo "FIGMA_API_KEY already found in $SETTINGS_LOCAL"
  echo ""
  read -rp "Overwrite existing key? [y/N] " overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    echo "Skipped. Setup complete."
    exit 0
  fi
fi

# --- Prompt for key ---
echo ""
echo "Get your Figma Personal Access Token:"
echo "  Figma → Account Settings → Security → Personal access tokens"
echo "  Required scope: File content (read)"
echo ""
read -rp "Paste your FIGMA_API_KEY: " figma_key

if [ -z "$figma_key" ]; then
  echo "No key entered. Aborting."
  exit 1
fi

# --- Write to settings.local.json using node ---
node - <<EOF
const fs = require('fs');
const path = '$SETTINGS_LOCAL';
let settings = {};
try { settings = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}
settings.env = settings.env || {};
settings.env.FIGMA_API_KEY = '$figma_key';
fs.mkdirSync(require('path').dirname(path), { recursive: true });
fs.writeFileSync(path, JSON.stringify(settings, null, 2) + '\n');
console.log('Written to ' + path);
EOF

echo ""
echo "Done! FIGMA_API_KEY saved to $SETTINGS_LOCAL"
echo "Claude Code will pass this env var to figma-developer-mcp automatically."
echo ""
echo "To verify: claude mcp list"
echo ""
