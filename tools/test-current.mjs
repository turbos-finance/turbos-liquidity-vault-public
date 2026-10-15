#!/usr/bin/env node
// Test the source and tests in THIS checkout, not an older anchor plus a patch.
// Only a new disposable directory is changed; no signing, publishing or keystore access.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
const repo=path.resolve(import.meta.dirname,'..');
const settings=JSON.parse(fs.readFileSync(path.join(repo,'tools/repro/release.json')));
const destination=process.argv[2];
if(!destination)throw new Error('Usage: node tools/test-current.mjs NEW_DISPOSABLE_DIRECTORY');
const directory=path.resolve(destination);
if(fs.existsSync(directory))throw new Error('Destination exists; refusing to overwrite');
const binary=process.env.SUI_BINARY||'sui';
const version=execFileSync(binary,['--version'],{encoding:'utf8'}).trim();
if(!version.includes('1.66.2-a9a6825eaf62'))throw new Error(`Use the recorded Sui 1.66.2-a9a6825eaf62; got ${version}`);
function hashes(){const out=[];function visit(dir,prefix){if(!fs.existsSync(dir))return;for(const e of fs.readdirSync(dir,{withFileTypes:true})){const name=path.join(prefix,e.name),full=path.join(dir,e.name);if(e.isDirectory())visit(full,name);else out.push({file:name,sha256:createHash('sha256').update(fs.readFileSync(full)).digest('hex')});}}for(const name of ['sources','tests'])visit(path.join(repo,name),name);return out.sort((a,b)=>a.file.localeCompare(b.file));}
const before=hashes();
fs.mkdirSync(directory,{recursive:true});
for(const name of ['sources','tests','Published.toml'])if(fs.existsSync(path.join(repo,name)))fs.cpSync(path.join(repo,name),path.join(directory,name),{recursive:true});
const original=fs.readFileSync(path.join(repo,'Move.toml'),'utf8'),index=original.indexOf('[dependencies]');
if(index<0)throw new Error('Expected the current public manifest structure');
const framework=settings.frameworkCurrent;
const dependency=subdir=>`{ git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/${subdir}", rev = "${framework}", override = true }`;
let manifest=original.slice(0,index)+'[dependencies]\nSui = '+dependency('sui-framework')+'\nMoveStdlib = '+dependency('move-stdlib')+'\n';
let clmmCommit=null;
if(['vault','farming'].includes(settings.project)){
 const entry=original.match(/^TurbosCLMM\s*=\s*\{[^\n]*rev\s*=\s*"([0-9a-f]{40})"[^\n]*\}/m);
 if(!entry)throw new Error('Expected a pinned public CLMM dependency');
 clmmCommit=entry[1];manifest+='TurbosCLMM = '+entry[0].split('=').slice(1).join('=').trim()+'\n';
}
fs.writeFileSync(path.join(directory,'Move.toml'),manifest);
const env={...process.env,RUST_MIN_STACK:'536870912'};
const args=['move','test','--path',directory,'--build-env','mainnet','--silence-warnings','--no-lint','--gas-limit','1000000000','--threads','1'];
const fd=fs.openSync(path.join(directory,'tests.log'),'wx');
const startedAt=new Date().toISOString();
const child=spawn(binary,args,{env,stdio:['ignore','pipe','pipe']});let output='',diskStopped=false,timedOut=false;
for(const stream of [child.stdout,child.stderr])stream.on('data',b=>{fs.writeSync(fd,b);output=(output+b).slice(-200000);});
const guard=setInterval(()=>{const s=fs.statfsSync(directory);if(s.bavail*s.bsize<5*1024**3){diskStopped=true;child.kill('SIGTERM');}},1000);
const timeout=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');},600000);
const exitCode=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});clearInterval(guard);clearTimeout(timeout);fs.closeSync(fd);
const match=output.match(/Test result: (\w+)\. Total tests: (\d+); passed: (\d+); failed: (\d+)/);
const sourceAndTestsUnchanged=JSON.stringify(before)===JSON.stringify(hashes());
const result={startedAt,completedAt:new Date().toISOString(),project:settings.project,toolchain:version,testFrameworkCommit:framework,clmmMetadataCommit:clmmCommit,command:[binary,...args.map(a=>a===directory?'DISPOSABLE_DIRECTORY':a)],exitCode,diskStopped,timedOut,testResult:match?{status:match[1],total:Number(match[2]),passed:Number(match[3]),failed:Number(match[4])}:null,currentCheckoutSourcesAndTests:true,sourceAndTestsUnchanged,sourceTreeSha256:createHash('sha256').update(JSON.stringify(before)).digest('hex'),coverageMeasured:false,scope:'Current-checkout unit tests only; production bytecode verification is separate'};
fs.writeFileSync(path.join(directory,'test-result.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
if(exitCode!==0||!match||match[1]!=='OK'||Number(match[4])!==0||!sourceAndTestsUnchanged){console.log(output.slice(-12000));process.exitCode=1;}
