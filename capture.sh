#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_URL="${CAPTURE_URL:-}"
CAPTURE_DIR="${CAPTURE_DIR:-}"
if [[ -z "$CAPTURE_URL" || -z "$CAPTURE_DIR" ]]; then
  echo 'Set CAPTURE_URL and CAPTURE_DIR.' >&2
  exit 1
fi
export PROJECT_DIR CAPTURE_URL CAPTURE_DIR

/usr/bin/time -p node --input-type=module <<'NODE'
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { performance } from 'node:perf_hooks';

const started = performance.now();
const timing = (label, begin) => console.log(`timing ${label}: ${(performance.now() - begin).toFixed(0)}ms`);
const runtime = join(process.env.HOME, '.local/share/omgithub-playwright');
const require = createRequire(join(runtime, 'package.json'));
let browser;
let exitCode = 1;
try {
  const target = new URL(process.env.CAPTURE_URL);
  if (!['http:', 'https:'].includes(target.protocol)) throw new Error('CAPTURE_URL must use HTTP or HTTPS.');
  const project = resolve(process.env.PROJECT_DIR);
  const output = resolve(process.env.CAPTURE_DIR);
  const pathFromProject = relative(project, output);
  if (!isAbsolute(process.env.CAPTURE_DIR) || pathFromProject === '' || (!pathFromProject.startsWith(`..${sep}`) && pathFromProject !== '..')) {
    throw new Error('CAPTURE_DIR must be an absolute path outside the source project.');
  }
  let begin = performance.now();
  mkdirSync(output, { recursive: true });
  timing('prepare capture directory', begin);

  const { chromium } = require('playwright');
  const configPath = join(runtime, process.platform === 'darwin' ? 'metal.json' : 'linux.json');
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  if (process.platform === 'linux') process.env.DISPLAY ||= ':' + readFileSync(join(runtime, 'display'), 'utf8').trim();
  begin = performance.now();
  try {
    browser = await chromium.launch({ ...config.browser.launchOptions, timeout: 30000 });
  } catch (error) {
    error.exitCode = 75;
    throw error;
  }
  timing('launch browser', begin);

  for (const [name, width, height] of [['desktop', 1440, 900], ['mobile', 390, 844]]) {
    begin = performance.now();
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, isMobile: name === 'mobile', hasTouch: name === 'mobile' });
    page.setDefaultTimeout(30000);
    const failures = [];
    page.on('pageerror', error => failures.push(`JavaScript error: ${error.message}`));
    page.on('response', response => {
      if (response.status() >= 400 && new URL(response.url()).origin === target.origin) {
        failures.push(`HTTP ${response.status()}: ${response.url()}`);
      }
    });
    page.on('requestfailed', request => {
      if (new URL(request.url()).origin === target.origin) failures.push(`Request failed: ${request.url()} (${request.failure()?.errorText || 'unknown error'})`);
    });
    let response;
    try {
      response = await page.goto(target.href, { waitUntil: 'load', timeout: 45000 });
    } catch (error) {
      error.exitCode = 75;
      throw error;
    }
    if (!response) throw Object.assign(new Error(`No HTTP response loading ${target.href}`), { exitCode: 75 });
    if (!response.ok()) {
      const status = response.status();
      throw Object.assign(new Error(`HTTP ${status} loading preview`), { exitCode: [408, 429, 500, 502, 503, 504].includes(status) ? 75 : 1 });
    }
    try {
      await page.waitForFunction(() => {
        const canvas = document.querySelector('#world canvas');
        const towers = document.querySelector('#towerList');
        return document.querySelector('.topbar')?.getBoundingClientRect().height > 0 &&
          canvas?.getBoundingClientRect().width > 0 && canvas?.getBoundingClientRect().height > 0 &&
          towers?.children.length > 0;
      }, { timeout: 30000 });
    } catch (error) {
      throw Object.assign(new Error(`Game did not render a playable scene in ${name} view: ${error.message}`), { exitCode: 1 });
    }
    await page.waitForTimeout(1000);
    if (failures.length) throw Object.assign(new Error(`Rendering defects in ${name} view: ${failures.join('; ')}`), { exitCode: 1 });
    try {
      await page.screenshot({ path: join(output, `final-${name}.png`), timeout: 30000 });
    } catch (error) {
      error.exitCode = !browser.isConnected() || error.name === 'TimeoutError' ? 75 : 1;
      throw error;
    }
    await page.close();
    timing(`navigate, render, and capture ${name}`, begin);
  }
  exitCode = 0;
} catch (error) {
  console.error(error);
  exitCode = error.exitCode ?? 1;
} finally {
  if (browser) {
    const begin = performance.now();
    try {
      await browser.close();
      timing('close browser', begin);
    } catch (error) {
      console.error(`Failed to close capture browser: ${error.message}`);
      if (exitCode === 0) exitCode = 75;
    }
  }
  timing('total capture', started);
}
process.exitCode = exitCode;
NODE
