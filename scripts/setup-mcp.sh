#!/usr/bin/env bash
# setup-mcp.sh — One-time setup for mida-skills MCP servers
# Run: bash .agents/scripts/setup-mcp.sh

set -e

SETTINGS_LOCAL="$HOME/.claude/settings.local.json"

echo ""
echo "=== mida-skills MCP Setup ==="
echo ""
echo "Configures API key for:"
echo "  1. Figma Developer MCP  (FIGMA_API_KEY)"
echo "  - Shopify Dev MCP needs no API key"
echo "  - Jira: use claude.ai Atlassian Rovo (authenticate via /mcp)"
echo ""

read_settings() {
  if [ -f "$SETTINGS_LOCAL" ]; then cat "$SETTINGS_LOCAL"; else echo "{}"; fi
}

write_env_key() {
  local key="$1"
  local value="$2"
  node - "$key" "$value" "$SETTINGS_LOCAL" <<'JSEOF'
const fs = require('fs');
const [,, key, value, path] = process.argv;
let settings = {};
try { settings = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}
settings.env = settings.env || {};
settings.env[key] = value;
fs.mkdirSync(require('path').dirname(path), { recursive: true });
fs.writeFileSync(path, JSON.stringify(settings, null, 2) + '\n');
console.log('  ✔ ' + key + ' saved');
JSEOF
}

echo "── Figma ──────────────────────────────────"
echo "Get token: Figma → Account Settings → Security → Personal access tokens"
echo "Required scope: File content (read)"
echo ""

existing=$(read_settings)
if echo "$existing" | grep -q "FIGMA_API_KEY"; then
  read -rp "FIGMA_API_KEY already set. Overwrite? [y/N] " ow
  if [[ ! "$ow" =~ ^[Yy]$ ]]; then
    echo "Skipped."
    echo ""
    echo "=== Done! ==="
    echo "Keys saved to $SETTINGS_LOCAL"
    echo "Restart Claude Code to activate MCP servers."
    exit 0
  fi
fi

read -rp "FIGMA_API_KEY: " figma_key
if [ -n "$figma_key" ]; then
  write_env_key "FIGMA_API_KEY" "$figma_key"
else
  echo "  Skipped (empty)."
fi

echo ""
echo "=== Done! ==="
echo "Key saved to $SETTINGS_LOCAL"
echo "Restart Claude Code to activate Figma MCP."
echo ""
echo "For Jira access: run /mcp in Claude Code → select 'claude.ai Atlassian Rovo' → authenticate."
echo ""
