#!/usr/bin/env node
// Read-only chain verification. Writes only into a new, disposable workspace.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const here = path.dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(fs.readFileSync(path.join(here, 'release.json'), 'utf8'));
const [destination, mode = 'build'] = process.argv.slice(2);
if (!destination || !['build', 'test', 'coverage'].includes(mode)) {
  throw new Error('Usage: node reproduce.mjs NEW_WORKSPACE [build|test|coverage]');
}
const testMode = mode !== 'build';
const binary = process.env.SUI_BINARY || 'sui';
const root = path.resolve(destination);
if (fs.existsSync(root)) throw new Error('Workspace must not exist; refusing to overwrite.');
const cliVersion = execFileSync(binary, ['--version'], { encoding: 'utf8' }).trim();
if (!cliVersion.includes('1.66.2-a9a6825eaf62')) throw new Error(`Use the recorded Sui CLI 1.66.2-a9a6825eaf62; got ${cliVersion}`);
fs.mkdirSync(root, { recursive: true });
const run = (cmd, args, cwd = root) => execFileSync(cmd, args, { cwd, stdio: 'inherit', env: { ...process.env, MOVE_HOME: path.join(root, 'move-home') } });
function clone(url, sha, relative, sparse = []) {
  const dest = path.join(root, relative);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  run('git', ['clone', '--filter=blob:none', '--no-checkout', ...(sparse.length ? ['--sparse'] : []), url, dest]);
  if (sparse.length) run('git', ['sparse-checkout', 'set', ...sparse], dest);
  run('git', ['checkout', '--detach', sha], dest);
  const actual = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dest, encoding: 'utf8' }).trim();
  if (actual !== sha) throw new Error(`Source SHA mismatch for ${url}`);
  return dest;
}
const packages = 'crates/sui-framework/packages';
clone('https://github.com/MystenLabs/sui.git', config.frameworkLegacy, 'framework', [packages]);
if (testMode || config.project === 'farming') {
  clone('https://github.com/MystenLabs/sui.git', config.frameworkCurrent, 'framework-current', [`${packages}/sui-framework`, `${packages}/move-stdlib`]);
}
const release = clone(config.repository, config.sourceCommit, config.project);
const preserved = new Map();
function remember(dir) {
  for (const category of ['sources', 'tests']) {
    const visit = current => {
      if (!fs.existsSync(current)) return;
      for (const e of fs.readdirSync(current, { withFileTypes: true })) {
        const p = path.join(current, e.name);
        if (e.isDirectory()) visit(p); else preserved.set(p, fs.readFileSync(p));
      }
    };
    visit(path.join(dir, category));
  }
}
remember(release);
function manifest(dir, filename) {
  fs.copyFileSync(path.join(here, filename), path.join(dir, 'Move.toml'));
  if (fs.existsSync(path.join(dir, 'Published.toml'))) fs.renameSync(path.join(dir, 'Published.toml'), path.join(dir, 'Published.toml.original'));
}
manifest(release, testMode ? 'test.Move.toml' : 'root.Move.toml');
if (config.project === 'vault' && mode === 'build') {
  clone('https://github.com/turbos-finance/turbos-sui-move-interface.git', config.interfaceCommit, 'interface');
  remember(path.join(root, 'interface/clmm'));
  manifest(path.join(root, 'interface/clmm'), 'interface.Move.toml');
}
if (config.project === 'farming' || (config.project === 'vault' && testMode)) {
  const clmm = clone('https://github.com/turbos-finance/turbos-clmm-public.git', config.clmmCommit, 'clmm');
  remember(clmm);
  manifest(clmm, testMode ? 'clmm-test.Move.toml' : 'clmm.Move.toml');
  // The historical V4 lock is superseded by explicitly pinned local dependencies.
  if (fs.existsSync(path.join(release, 'Move.lock'))) fs.renameSync(path.join(release, 'Move.lock'), path.join(release, 'Move.lock.original'));
}
for (const [p, before] of preserved) if (!before.equals(fs.readFileSync(p))) throw new Error(`Source/test changed: ${p}`);
if (testMode) {
  if (fs.existsSync(path.join(release, 'Move.lock'))) fs.renameSync(path.join(release, 'Move.lock'), path.join(release, 'Move.lock.original'));
  const overlay = path.join(here, 'test-overlay.patch');
  if (fs.existsSync(overlay)) {
    run('git', ['apply', '--check', overlay], release);
    run('git', ['apply', overlay], release);
  }
  const extraTests = path.join(here, 'test-files');
  if (fs.existsSync(extraTests)) fs.cpSync(extraTests, path.join(release, 'tests'), { recursive: true });
  // Guard the explicit, reviewed test overlay against any changes during execution.
  // The build mode above never applies it; exact mainnet bytecode verification is separate.
  preserved.clear();
  remember(release);
  if (mode === 'coverage') {
    const output = path.join(root, 'coverage');
    const selected = JSON.parse(fs.readFileSync(path.join(here, 'coverage-filter.json')));
    run(process.execPath, [path.join(here, 'coverage.mjs'), release, output, binary, ...(selected.filter ? [selected.filter] : [])]);
    run(process.execPath, [path.join(here, 'summarize-coverage.mjs'), release, output]);
  } else run(binary, ['move', 'test', '--path', release, '--silence-warnings', '--no-lint', '--statistics', '--gas-limit', '1000000000']);
} else {
  run(binary, ['move', 'build', '--path', release, '--silence-warnings']);
  run(process.execPath, [path.join(here, 'compare-bytecode.mjs'), path.join(release, 'build', config.packageName, 'bytecode_modules'), config.packageId, path.join(root, 'bytecode-verification.json')]);
}
for (const [p, before] of preserved) if (!before.equals(fs.readFileSync(p))) throw new Error(`Source/test changed during build: ${p}`);
