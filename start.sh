#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
PORT="${PORT:-3000}"
export PORT

/usr/bin/time -p npm ci
/usr/bin/time -p rm -rf "$PROJECT_DIR/dist"
/usr/bin/time -p mkdir -p "$PROJECT_DIR/dist"
/usr/bin/time -p cp "$PROJECT_DIR/index.html" "$PROJECT_DIR/style.css" "$PROJECT_DIR/game.js" "$PROJECT_DIR/dist/"
/usr/bin/time -p ln -s "$PROJECT_DIR/node_modules" "$PROJECT_DIR/dist/node_modules"
/usr/bin/time -p mkdir -p /home/runner/work/_temp/omgithub-web
/usr/bin/time -p node --input-type=module -e '
  import { writeFileSync } from "node:fs";
  writeFileSync("/home/runner/work/_temp/omgithub-web/deployment-output.json", JSON.stringify({
    project: process.cwd(),
    directory: `${process.cwd()}/dist`
  }) + "\n");
'
/usr/bin/time -p python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$PROJECT_DIR/dist"
