import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
const [packageArgument, outputArgument, binaryArgument, filter] = process.argv.slice(2);
if (!packageArgument || !outputArgument || !binaryArgument) throw new Error('Usage: run-traced-coverage.mjs PACKAGE OUTPUT SUI_BINARY');
const pkg = path.resolve(packageArgument), output = path.resolve(outputArgument), binary = binaryArgument.includes(path.sep) ? path.resolve(binaryArgument) : binaryArgument;
if (fs.existsSync(output)) throw new Error('Refusing to overwrite coverage evidence');
if (fs.existsSync(path.join(pkg, 'traces'))) throw new Error('Use a clean trace directory to avoid mixing test runs');
fs.mkdirSync(output, { recursive: true });
const env = { ...process.env, MOVE_HOME: path.join(path.dirname(pkg), 'move-home'), RUST_MIN_STACK: '536870912' };
async function run(args, name, diskGuard = false) {
  const log = path.join(output, name);
  const fd = fs.openSync(log, 'wx');
  const child = spawn(binary, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let text = '', stoppedForDisk = false;
  for (const stream of [child.stdout, child.stderr]) stream.on('data', b => { fs.writeSync(fd, b); if (text.length < 1024 * 1024) text += b.toString(); });
  const timer = diskGuard ? setInterval(() => {
    const stat = fs.statfsSync(pkg);
    if (stat.bavail * stat.bsize < 5 * 1024 ** 3) { stoppedForDisk = true; child.kill('SIGTERM'); }
  }, 500) : null;
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
  if (timer) clearInterval(timer);
  fs.closeSync(fd);
  if (code !== 0 || stoppedForDisk) throw new Error(`${name} failed: exit ${code}; disk guard ${stoppedForDisk}. See ${log}`);
  return text;
}
const test = await run(['move', 'test', '--path', pkg, '--coverage', '--trace', '--no-lint', '--silence-warnings', '--gas-limit', '1000000000', '--threads', '1', ...(filter ? [filter] : [])], 'traced-tests.log', true);
const summary = test.match(/Test result: (\w+)\. Total tests: (\d+); passed: (\d+); failed: (\d+)/);
if (!summary || summary[1] !== 'OK' || Number(summary[4]) !== 0) throw new Error('No passing test summary');
await run(['move', 'coverage', '--path', pkg, 'lcov', '--silence-warnings', '--no-lint'], 'lcov-generation.log', true);
await run(['move', 'coverage', '--path', pkg, 'summary', '--test', '--silence-warnings', '--no-lint', '--summarize-functions'], 'instruction-summary.log');
fs.copyFileSync(path.join(pkg, 'lcov.info'), path.join(output, 'raw-lcov.info'));
const result = { generatedAt: new Date().toISOString(), total: Number(summary[2]), passed: Number(summary[3]), failed: Number(summary[4]), tracing: true, coverage: true, filter: filter ?? null, fullSuiteTraced: !filter, rustMinStack: env.RUST_MIN_STACK, threads: 1 };
fs.writeFileSync(path.join(output, 'run.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify({ package: path.basename(pkg), ...result }));
