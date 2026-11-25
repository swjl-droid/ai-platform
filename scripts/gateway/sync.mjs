#!/usr/bin/env node
// Copies ai-platform/gateway into one app checkout and stamps it (decision 25/11/2026, Hub row 217).
// Usage: node scripts/gateway/sync.mjs <app> <app-checkout-dir>
//   <app> must be listed in gateway.apps.json, which also gives the target folder (e.g. lib/gateway).
// It replaces the folder, writes STAMP.json, and adds the gateway's dependencies to the app's
// package.json at the versions ai-platform uses. It never commits or pushes: open-copy-prs.mjs does.

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fingerprints, verify, STAMP_FILE } from '../../gateway/stamp.mjs';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const GATEWAY_DEPS = ['pg']; // runtime dependencies of gateway/*.js

export function loadApps() {
  return JSON.parse(readFileSync(join(root, 'gateway.apps.json'), 'utf8'));
}

export function sync(appName, target, { commit } = {}) {
  const config = loadApps();
  const app = config.apps.find((a) => a.app === appName);
  if (!app) throw new Error(`${appName} is not in gateway.apps.json`);
  if (!existsSync(join(target, 'package.json'))) throw new Error(`${target} has no package.json`);

  const src = join(root, 'gateway');
  const dest = join(target, app.path);
  rmSync(dest, { recursive: true, force: true });
  cpSync(src, dest, { recursive: true });

  const version = readFileSync(join(src, 'VERSION'), 'utf8').trim();
  const sha = commit ?? execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  const stamp = { version, source: config.source, commit: sha, files: fingerprints(dest) };
  writeFileSync(join(dest, STAMP_FILE), JSON.stringify(stamp, null, 2) + '\n');

  const rootPkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const pkgPath = join(target, 'package.json');
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
  pkg.dependencies = { ...(pkg.dependencies ?? {}) };
  for (const d of GATEWAY_DEPS) pkg.dependencies[d] = rootPkg.dependencies[d];
  writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

  const problems = verify(dest);
  if (problems.length) throw new Error(`stamp check failed after copy: ${problems.join('; ')}`);
  return { app: app.app, repo: app.repo, path: app.path, version, commit: sha };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [appName, target] = process.argv.slice(2);
  if (!appName || !target) {
    console.error('Usage: node scripts/gateway/sync.mjs <app> <app-checkout-dir>');
    process.exit(2);
  }
  const r = sync(appName, resolve(target));
  console.log(`Copied gateway ${r.version} (${r.commit.slice(0, 7)}) into ${r.repo}/${r.path}`);
}
