#!/bin/bash
# PostToolUse hook: remind to deploy after pushing MCP project changes
# Triggers on: Bash commands containing "git push"
# Condition: cwd has both Package.swift (or pyproject.toml/package.json) AND mcpb/ directory

TOOL_INPUT="$1"

# Only trigger on git push commands
if ! echo "$TOOL_INPUT" | grep -q "git push"; then
  exit 0
fi

# Check if we're in an MCP project (has mcpb/ directory)
if [ ! -d "mcpb" ]; then
  exit 0
fi

# Check if it's a code project (not just docs)
if [ ! -f "Package.swift" ] && [ ! -f "pyproject.toml" ] && [ ! -f "package.json" ]; then
  exit 0
fi

# Get project name
PROJECT_NAME=$(basename "$(pwd)")

cat <<EOF
[mcp-tools] Detected git push in MCP project: $PROJECT_NAME

If you changed server functionality, consider running:
  /mcp-tools:mcp-deploy — build, package mcpb, create GitHub Release, update Plugin
  /mcp-tools:mcp-publish — publish to MCP Registry + Glama
EOF
