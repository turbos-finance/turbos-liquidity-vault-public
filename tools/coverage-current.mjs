#!/usr/bin/env node
// Reproduce full coverage of the current public checkout. No chain or wallet access.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
const repo=path.resolve(import.meta.dirname,'..');
const settings=JSON.parse(fs.readFileSync(path.join(repo,'tools/repro/release.json')));
const baseline=JSON.parse(fs.readFileSync(path.join(repo,'evidence/tests-current-2026-10-15/result.json')));
const destination=process.argv[2];
const partial=process.argv[3]==='--documented-partial';
if(process.argv[3]&&!partial)throw new Error('Unknown option');
if(partial&&!['clmm','vault'].includes(settings.project))throw new Error('Documented partial mode applies only to CLMM/Vault');
if(!destination)throw new Error('Usage: SUI_BINARY=/path/to/tracing/sui node tools/coverage-current.mjs NEW_DISPOSABLE_DIRECTORY [--documented-partial]');
const directory=path.resolve(destination);
if(fs.existsSync(directory))throw new Error('Destination exists; refusing to overwrite');
const binary=process.env.SUI_BINARY||'sui';
const version=execFileSync(binary,['--version'],{encoding:'utf8'}).trim();
if(!version.includes('1.66.2-a9a6825eaf62'))throw new Error(`Use official tracing-enabled Sui 1.66.2-a9a6825eaf62; got ${version}`);
const hash=b=>createHash('sha256').update(b).digest('hex');
function hashes(at){const out=[];function visit(dir,prefix){if(!fs.existsSync(dir))return;for(const e of fs.readdirSync(dir,{withFileTypes:true})){const full=path.join(dir,e.name),file=path.join(prefix,e.name);if(e.isDirectory())visit(full,file);else out.push({file,sha256:hash(fs.readFileSync(full))});}}for(const n of ['sources','tests'])visit(path.join(at,n),n);return out.sort((a,b)=>a.file.localeCompare(b.file));}
const before=hashes(repo),tree=hash(JSON.stringify(before));
if(tree!==baseline.sourceTreeSha256)throw new Error('Source/tests differ from the published test baseline; review and update that baseline first');
const commit=execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
fs.mkdirSync(directory,{recursive:true});
const pkg=path.join(directory,'package'),normal=path.join(directory,'normal'),output=path.join(directory,'evidence');
for(const at of [pkg,normal]){fs.mkdirSync(at);for(const n of ['sources','tests','Move.toml','Published.toml'])if(fs.existsSync(path.join(repo,n)))fs.cpSync(path.join(repo,n),path.join(at,n),{recursive:true});}
fs.mkdirSync(output);
const isolated=path.join(directory,'isolated-client');fs.mkdirSync(isolated);
fs.writeFileSync(path.join(isolated,'sui.keystore'),'[]\n');
fs.writeFileSync(path.join(isolated,'client.yaml'),`---\nkeystore:\n  File: ${JSON.stringify(path.join(isolated,'sui.keystore'))}\nexternal_keys: ~\nenvs:\n  - alias: mainnet\n    rpc: "https://fullnode.mainnet.sui.io:443"\n    ws: ~\n    basic_auth: ~\n    chain_id: 35834a8a\nactive_env: mainnet\nactive_address: ~\n`);
const original=fs.readFileSync(path.join(repo,'Move.toml'),'utf8'),index=original.indexOf('[dependencies]');
if(index<0)throw new Error('Missing dependency manifest section');
const dep=subdir=>`{ git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/${subdir}", rev = "${settings.frameworkCurrent}", override = true }`;
let manifest=original.slice(0,index)+'[dependencies]\nSui = '+dep('sui-framework')+'\nMoveStdlib = '+dep('move-stdlib')+'\n';
if(['vault','farming'].includes(settings.project)){const entry=original.match(/^TurbosCLMM\s*=\s*\{[^\n]*rev\s*=\s*"([0-9a-f]{40})"[^\n]*\}/m);if(!entry)throw new Error('Expected pinned public CLMM dependency');manifest+=entry[0]+'\n';}
fs.writeFileSync(path.join(pkg,'Move.toml'),manifest);
fs.writeFileSync(path.join(directory,'identity.json'),JSON.stringify({project:settings.project,repo,commit,sourceTreeSha256:tree,sourceHashes:before,packageName:settings.packageName,expectedTests:baseline.testResult.total},null,2)+'\n');
const env={...process.env,RUST_MIN_STACK:'536870912',SUI_CONFIG_DIR:isolated};
async function run(command,args,name){const file=path.join(output,name),fd=fs.openSync(file,'wx');const child=spawn(command,args,{env,stdio:['ignore','pipe','pipe'],detached:process.platform!=='win32'});let text='',timedOut=false,diskStopped=false;
  const stop=()=>{try{process.platform==='win32'?child.kill('SIGTERM'):process.kill(-child.pid,'SIGTERM');}catch{}};
  for(const s of [child.stdout,child.stderr])s.on('data',b=>{fs.writeSync(fd,b);text=(text+b).slice(-1000000);});
  const guard=setInterval(()=>{const s=fs.statfsSync(directory);if(s.bavail*s.bsize<5*1024**3){diskStopped=true;stop();}},1000);
  const timeout=setTimeout(()=>{timedOut=true;stop();},1200000);
  const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});clearInterval(guard);clearTimeout(timeout);fs.closeSync(fd);
  fs.writeFileSync(file+'.result.json',JSON.stringify({command:[command,...args].map(a=>a.replaceAll(directory,'DISPOSABLE_DIRECTORY')),exitCode:code,timedOut,diskStopped},null,2)+'\n');
  if(code!==0||timedOut||diskStopped){console.log(text.slice(-5000));throw new Error(`${name} failed; retained logs at ${file}`);}return text;
}
await run(binary,['move','build','--path',normal,'--build-env','mainnet','--silence-warnings','--no-lint'],'normal-build.log');
if(partial){const full=await run(binary,['move','test','--path',pkg,'--build-env','mainnet','--silence-warnings','--no-lint','--gas-limit','1000000000','--threads','1'],'full-tests.log');const m=full.match(/Test result: (\w+)\. Total tests: (\d+); passed: (\d+); failed: (\d+)/);if(!m||m[1]!=='OK'||Number(m[2])!==baseline.testResult.total||Number(m[4])!==0)throw new Error('Full unfiltered suite did not pass');}
const filter=partial?JSON.parse(fs.readFileSync(path.join(repo,'tools/repro/coverage-filter.json'))).filter:null;
const expectedTraceCount=partial?JSON.parse(fs.readFileSync(path.join(repo,'evidence/coverage-2026-10-14/production-coverage.json'))).run.total:baseline.testResult.total;
const text=await run(binary,['move','test','--path',pkg,'--build-env','mainnet','--coverage','--trace','--silence-warnings','--no-lint','--gas-limit','1000000000','--threads','1',...(filter?[filter]:[])],'traced-tests.log');
const match=text.match(/Test result: (\w+)\. Total tests: (\d+); passed: (\d+); failed: (\d+)/);
if(!match||match[1]!=='OK'||Number(match[2])!==expectedTraceCount||Number(match[4])!==0)throw new Error('Incomplete expected tracing suite');
const passedNames=[...text.matchAll(/\[ PASS\s+\]\s+(\S+)/g)].map(m=>m[1]);
const traces=fs.readdirSync(path.join(pkg,'traces')).filter(f=>f.endsWith('.json.zst'));
if(passedNames.length!==Number(match[2])||traces.length!==Number(match[2])||passedNames.some(n=>!traces.some(f=>f.startsWith(n.replaceAll('::','__')+'.'))))throw new Error('Missing per-test trace; refusing to label this full-suite coverage');
await run(binary,['move','coverage','--path',pkg,'--build-env','mainnet','lcov','--silence-warnings','--no-lint'],'lcov-generation.log');
await run(binary,['move','coverage','--path',pkg,'--build-env','mainnet','summary','--test','--silence-warnings','--no-lint','--summarize-functions'],'instruction-summary.log');
fs.copyFileSync(path.join(pkg,'lcov.info'),path.join(output,'raw-lcov.info'));
if(JSON.stringify(before)!==JSON.stringify(hashes(repo))||JSON.stringify(before)!==JSON.stringify(hashes(pkg))||JSON.stringify(before)!==JSON.stringify(hashes(normal)))throw new Error('Source/tests changed');
const runResult={generatedAt:new Date().toISOString(),project:settings.project,total:Number(match[2]),passed:Number(match[3]),failed:Number(match[4]),coverage:true,fullSuiteCovered:!partial,fullSuiteTraced:!partial,fullSuiteTests:baseline.testResult.total,fullSuitePassed:baseline.testResult.total,perTestTraceCount:traces.length,allTracedTestsHaveTrace:true,allPassingTestsHaveTrace:!partial,traceRequested:true,filter,sourceAndTestsUnchanged:true,sourceTreeSha256:tree,sourceCommit:commit,toolchain:version,platform:process.platform,threads:1};
fs.writeFileSync(path.join(output,'run.json'),JSON.stringify(runResult,null,2)+'\n');
await run(process.execPath,[path.join(repo,'tools/summarize-current-coverage.mjs'),settings.project,pkg,normal,output],'production-summary.log');
console.log(JSON.stringify({output,...JSON.parse(fs.readFileSync(path.join(output,'production-coverage.json'))).totals},null,2));
