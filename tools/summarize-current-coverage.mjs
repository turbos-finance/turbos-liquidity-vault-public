// Produces production-only coverage using official LCOV plus compiler source maps.
// Normal-build function maps are authoritative: tests/test-only helpers are excluded.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
const [key, packageArgument, normalArgument, outputArgument] = process.argv.slice(2);
if (![key, packageArgument, normalArgument, outputArgument].every(Boolean)) throw new Error('Usage: summarize-current-coverage.mjs PROJECT TEST_PACKAGE NORMAL_BUILD OUTPUT');
const pkg = path.resolve(packageArgument), normal = path.resolve(normalArgument), output = path.resolve(outputArgument);
const repo = path.resolve(import.meta.dirname, '..');
const release = JSON.parse(fs.readFileSync(path.join(repo, 'tools/repro/release.json')));
if (release.project !== key) throw new Error('Project mismatch');
const config = {currentPackageId:release.packageId,currentVersion:release.version,versions:{[release.version]:release.sourceCommit}};
const name = /name\s*=\s*"([^"]+)"/.exec(fs.readFileSync(path.join(pkg, 'Move.toml'), 'utf8'))[1];
const hash = b => createHash('sha256').update(b).digest('hex');
function maps(directory) {
  return fs.readdirSync(directory).filter(f => f.endsWith('.json')).map(f => JSON.parse(fs.readFileSync(path.join(directory, f))));
}
const testMaps = maps(path.join(pkg, 'build', name, 'debug_info'));
const normalMaps = maps(path.join(normal, 'build', name, 'debug_info'));
const buffers = new Map();
function addFiles(directory) {
  for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, item.name);
    if (item.isDirectory()) addFiles(file);
    else if (file.endsWith('.json')) {
      const map = JSON.parse(fs.readFileSync(file));
      if (!map.from_file_path) continue;
      const source = fs.readFileSync(map.from_file_path);
      if (hash(source) !== map.definition_location.file_hash) throw new Error('Source-map hash mismatch');
      buffers.set(map.definition_location.file_hash, source);
    }
  }
}
addFiles(path.join(pkg, 'build', name, 'debug_info'));
for (const map of normalMaps) {
  const source = fs.readFileSync(map.from_file_path);
  if (hash(source) !== map.definition_location.file_hash) throw new Error('Normal-map source hash mismatch');
  buffers.set(map.definition_location.file_hash, source);
}
function source(loc) {
  const b = buffers.get(loc.file_hash);
  if (!b) throw new Error(`Unknown source-map hash ${loc.file_hash}`);
  if (loc.start > b.length) throw new Error('Invalid source offset');
  return b;
}
const fnName = f => source(f.definition_location).subarray(f.definition_location.start, f.definition_location.end).toString();
const line = loc => source(loc).subarray(0, loc.start).toString().split('\n').length;
const sourceMaps = new Map(testMaps.map(m => [path.resolve(m.from_file_path), m]));
const productionNames = new Map(normalMaps.map(m => [m.module_name[1], new Set(Object.values(m.function_map).map(fnName))]));
const raw = fs.readFileSync(path.join(output, 'raw-lcov.info'), 'utf8');
const records = raw.split('end_of_record').map(r => r.trim()).filter(Boolean).map(r => r.split('\n'));
const files = [], productionLcov = [], moduleManifest = [];
for (const record of records) {
  const get = field => Number(record.find(l => l.startsWith(field + ':'))?.slice(field.length + 1) ?? 0);
  const sf = record.find(l => l.startsWith('SF:'))?.slice(3);
  if (!sf || !sf.startsWith(path.join(pkg, 'sources') + path.sep)) continue;
  const map = sourceMaps.get(path.resolve(sf));
  if (!map) throw new Error(`Missing root source map: ${sf}`);
  const runtime = productionNames.get(map.module_name[1]);
  if (!runtime) continue; // Modules absent from the normal build are test-only.
  const functions = new Map(record.filter(l => l.startsWith('FN:')).map(l => { const comma = l.indexOf(','); return [l.slice(comma + 1), Number(l.slice(3, comma))]; }));
  const functionHits = new Map(record.filter(l => l.startsWith('FNDA:')).map(l => { const comma = l.indexOf(','); return [l.slice(comma + 1), Number(l.slice(5, comma))]; }));
  const hits = new Map(record.filter(l => l.startsWith('DA:')).map(l => l.slice(3).split(',').map(Number)));
  const allLines = new Set(), runtimeLines = new Set();
  for (const f of Object.values(map.function_map)) {
    const functionName = fnName(f);
    if (!functions.has(functionName)) continue; // Compiler-injected unit-test poison is omitted by official LCOV.
    for (const loc of [f.definition_location, ...Object.values(f.code_map)]) {
      const n = line(loc);
      allLines.add(n);
      if (runtime.has(functionName)) runtimeLines.add(n);
    }
  }
  // Validate our instrumented-line denominator against the official CLI, per module.
  if (allLines.size !== get('LF')) throw new Error(`Line denominator mismatch ${sf}: maps=${allLines.size}, CLI=${get('LF')}`);
  if (functions.size !== get('FNF')) throw new Error('Official function denominator mismatch');
  for (const functionName of runtime) if (!functions.has(functionName)) throw new Error(`Production function missing: ${functionName}`);
  const branches = record.filter(l => l.startsWith('BRDA:')).map(l => l.slice(5).split(','));
  if (branches.length !== get('BRF')) throw new Error('Official branch denominator mismatch');
  const runtimeBranches = branches.filter(parts => runtimeLines.has(Number(parts[0])));
  const linesFound = runtimeLines.size, linesHit = [...runtimeLines].filter(n => (hits.get(n) ?? 0) > 0).length;
  const branchesFound = runtimeBranches.length, branchesHit = runtimeBranches.filter(parts => parts[3] !== '-' && Number(parts[3]) > 0).length;
  const runtimeFunctions = [...runtime].sort();
  const uncoveredFunctions = runtimeFunctions.filter(n => !(functionHits.get(n) > 0));
  const relative = path.relative(pkg, sf).replaceAll(path.sep, '/');
  const stats = { file: relative, module: map.module_name[1], linesFound, linesHit, branchesFound, branchesHit, functionsFound: runtime.size, functionsHit: runtime.size - uncoveredFunctions.length, uncoveredFunctions, uncoveredLines: [...runtimeLines].filter(n => !(hits.get(n) > 0)).sort((a, b) => a - b), officialTestBuildLines: get('LF'), excludedTestBuildLines: get('LF') - linesFound, sourceMapDenominatorValidated: true };
  files.push(stats);
  moduleManifest.push({ module: map.module_name[1], source: relative, normalBuildFunctions: runtimeFunctions, normalSourceSha256: normalMaps.find(m => m.module_name[1] === map.module_name[1]).definition_location.file_hash });
  productionLcov.push([`SF:${relative}`, `FNF:${runtime.size}`, `FNH:${stats.functionsHit}`, `LF:${linesFound}`, `LH:${linesHit}`, `BRF:${branchesFound}`, `BRH:${branchesHit}`, ...runtimeFunctions.map(n => `FN:${functions.get(n)},${n}`), ...runtimeFunctions.filter(n => functionHits.has(n)).map(n => `FNDA:${functionHits.get(n)},${n}`), ...[...runtimeLines].sort((a, b) => a - b).map(n => `DA:${n},${hits.get(n) ?? 0}`), ...runtimeBranches.map(parts => `BRDA:${parts.join(',')}`), 'end_of_record'].join('\n'));
}
if (files.length !== normalMaps.length) throw new Error(`Not every normal root module included: ${files.length}/${normalMaps.length}`);
const sum = field => files.reduce((s, f) => s + f[field], 0);
const percent = (n, d) => d ? Number((100 * n / d).toFixed(2)) : null;
const totals = Object.fromEntries(['linesFound', 'linesHit', 'branchesFound', 'branchesHit', 'functionsFound', 'functionsHit'].map(k => [k, sum(k)]));
Object.assign(totals, { lineCoveragePercent: percent(totals.linesHit, totals.linesFound), branchCoveragePercent: percent(totals.branchesHit, totals.branchesFound), functionCoveragePercent: percent(totals.functionsHit, totals.functionsFound) });
const result = { generatedAt: new Date().toISOString(), project: key, packageId: config.currentPackageId, version: config.currentVersion, sourceCommit: config.versions[config.currentVersion], toolchain: 'sui 1.66.2-a9a6825eaf62, official mainnet release, tracing enabled', run: JSON.parse(fs.readFileSync(path.join(output, 'run.json'))), scope: 'All normal-build root functions; excludes dependency modules, tests modules, inline tests, test-only helpers and compiler test poison. Source-map-derived line denominators validated against official test-build LCOV per module before exclusions.', branchMetric: 'Official Sui LCOV control-flow-graph successor edges, including unconditional/single-successor edges; not a custom decision-only metric.', totals, files };
if (!packageArgument) throw new Error('Current-public mode needs explicit test package and normal-build paths');
const identity = JSON.parse(fs.readFileSync(path.join(path.dirname(pkg), 'identity.json')));
result.baseDeployedSourceCommit = result.sourceCommit;
result.sourceCommit = identity.commit;
result.sourceTreeSha256 = identity.sourceTreeSha256;
result.currentPublicCheckout = true;
result.productionBytecodeReference = JSON.parse(fs.readFileSync(path.join(repo, 'evidence/tests-current-2026-10-15/normal-bytecode.json')));
if (!result.productionBytecodeReference.allMatch) throw new Error('Production module bytecode reference mismatch');
for (const mod of result.productionBytecodeReference.modules) {
  const actual = hash(fs.readFileSync(path.join(normal, 'build', name, 'bytecode_modules', mod.module+'.mv')));
  if (actual !== mod.deployedSha256) throw new Error('Normal-build root module changed: '+mod.module);
}
result.publication = 'Current public source/test checkout only. No private production fixes, chain writes or contract upgrades.';
fs.writeFileSync(path.join(output, 'production-coverage.json'), JSON.stringify(result, null, 2) + '\n');
fs.writeFileSync(path.join(output, 'production-lcov.info'), productionLcov.join('\n') + '\n');
fs.writeFileSync(path.join(output, 'normal-build-functions.json'), JSON.stringify(moduleManifest, null, 2) + '\n');
console.log(JSON.stringify({ project: key, ...totals }));
