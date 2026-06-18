#!/usr/bin/env bash
# setup-mcp.sh — One-time setup for mida-skills MCP servers
# Run: bash .agents/scripts/setup-mcp.sh

set -e

SETTINGS_LOCAL="$HOME/.claude/settings.local.json"

echo ""
echo "=== mida-skills MCP Setup ==="
echo ""
echo "Configures API keys for:"
echo "  1. Figma Developer MCP  (FIGMA_API_KEY)"
echo "  2. Jira MCP             (JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN)"
echo "  - Shopify Dev MCP needs no API key"
echo ""

# --- Read existing settings.local.json or start fresh ---
read_settings() {
  if [ -f "$SETTINGS_LOCAL" ]; then cat "$SETTINGS_LOCAL"; else echo "{}"; fi
}

# --- Write a key to settings.local.json ---
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

# ─────────────────────────────────────────────
# FIGMA
# ─────────────────────────────────────────────
echo "── Figma ──────────────────────────────────"
echo "Get token: Figma → Account Settings → Security → Personal access tokens"
echo "Required scope: File content (read)"
echo ""

existing=$(read_settings)
if echo "$existing" | grep -q "FIGMA_API_KEY"; then
  read -rp "FIGMA_API_KEY already set. Overwrite? [y/N] " ow
  [[ "$ow" =~ ^[Yy]$ ]] || { echo "Skipped."; echo ""; goto_jira=1; }
fi

if [ -z "${goto_jira:-}" ]; then
  read -rp "FIGMA_API_KEY: " figma_key
  if [ -n "$figma_key" ]; then
    write_env_key "FIGMA_API_KEY" "$figma_key"
  else
    echo "  Skipped (empty)."
  fi
fi

echo ""

# ─────────────────────────────────────────────
# JIRA
# ─────────────────────────────────────────────
echo "── Jira ───────────────────────────────────"
echo "Get API token: https://id.atlassian.com/manage-profile/security/api-tokens"
echo ""

existing=$(read_settings)
jira_already=0
if echo "$existing" | grep -q "JIRA_API_TOKEN"; then
  jira_already=1
  read -rp "Jira credentials already set. Overwrite? [y/N] " ow2
  [[ "$ow2" =~ ^[Yy]$ ]] || { echo "Skipped."; jira_already=2; }
fi

if [ "$jira_already" != "2" ]; then
  read -rp "JIRA_URL (e.g. https://yourcompany.atlassian.net): " jira_url
  read -rp "JIRA_USERNAME (your Atlassian email): " jira_user
  read -rp "JIRA_API_TOKEN: " jira_token

  if [ -n "$jira_url" ] && [ -n "$jira_user" ] && [ -n "$jira_token" ]; then
    write_env_key "JIRA_URL" "$jira_url"
    write_env_key "JIRA_USERNAME" "$jira_user"
    write_env_key "JIRA_API_TOKEN" "$jira_token"
  else
    echo "  Skipped (incomplete input)."
  fi
fi

echo ""
echo "=== Done! ==="
echo "Keys saved to $SETTINGS_LOCAL"
echo "Claude Code injects these env vars into MCP servers automatically."
echo ""
echo "To verify: claude mcp list"
echo ""
