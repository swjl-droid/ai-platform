#!/usr/bin/env node
// Opens one pull request per app in gateway.apps.json with the stamped gateway copy.
// Run from an ai-platform checkout on main, by a person or a Claude session that can push to the
// app repos (decision 25/11/2026: no new secret, so no robot token holds that right).
// Usage: node scripts/gateway/open-copy-prs.mjs <work-dir> [app ...]
// Needs: git and gh, signed in with push rights to the app repos.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { loadApps, sync } from './sync.mjs';

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], ...opts }).trim();

const [workDir, ...only] = process.argv.slice(2);
if (!workDir) {
  console.error('Usage: node scripts/gateway/open-copy-prs.mjs <work-dir> [app ...]');
  process.exit(2);
}
mkdirSync(workDir, { recursive: true });

for (const app of loadApps().apps.filter((a) => only.length === 0 || only.includes(a.app))) {
  const dir = resolve(join(workDir, app.app));
  if (!existsSync(dir)) run('git', ['clone', '--depth', '1', `https://github.com/${app.repo}`, dir]);
  run('git', ['-C', dir, 'fetch', '--depth', '1', 'origin', 'main']);
  run('git', ['-C', dir, 'checkout', '-B', 'tmp-gateway-sync', 'origin/main']);
  const r = sync(app.app, dir);
  const branch = `gateway/v${r.version}`;
  run('git', ['-C', dir, 'checkout', '-B', branch]);
  run('git', ['-C', dir, 'add', '-A']);
  if (!run('git', ['-C', dir, 'status', '--porcelain'])) {
    console.log(`${app.repo}: already at gateway ${r.version}, nothing to do`);
    continue;
  }
  run('git', ['-C', dir, 'commit', '-m', `Gateway ${r.version} from ai-platform@${r.commit.slice(0, 7)}`]);
  run('git', ['-C', dir, '-c', 'push.negotiate=true', 'push', '-u', 'origin', branch, '--force-with-lease']);
  const body = [
    `Stamped copy of the LLM gateway **${r.version}** from ${loadApps().source}@${r.commit}.`,
    '',
    `- Folder \`${r.path}\` is replaced as a whole; \`STAMP.json\` lists every file's fingerprint.`,
    '- Do not edit the copy here: CI fails if it differs from its stamp. Change ai-platform/gateway instead.',
  ].join('\n');
  // REST API only (works where GraphQL is not available).
  const owner = app.repo.split('/')[0];
  const existing = run('gh', ['api', `repos/${app.repo}/pulls?state=open&head=${owner}:${encodeURIComponent(branch)}`,
    '--jq', '.[0].html_url // empty']);
  const url = existing || run('gh', ['api', `repos/${app.repo}/pulls`, '-f', `title=Gateway ${r.version}`,
    '-f', `head=${branch}`, '-f', 'base=main', '-f', `body=${body}`, '--jq', '.html_url']);
  console.log(`${app.repo}: ${url}`);
}
