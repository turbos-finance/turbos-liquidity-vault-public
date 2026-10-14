#!/usr/bin/env node
// Read-only comparison of freshly built root modules against immutable mainnet BCS.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { SuiGrpcClient } from '@mysten/sui/grpc';
const [moduleDir,packageId,output]=process.argv.slice(2);
if(!moduleDir||!packageId||!output)throw new Error('Usage: compare-built-bytecode.mjs MODULE_DIR PACKAGE_ID OUTPUT_JSON');
const client=new SuiGrpcClient({network:'mainnet',baseUrl:'https://fullnode.mainnet.sui.io:443'});
const {response}=await client.ledgerService.getObject({objectId:packageId,readMask:{paths:['version','package']}});
const {response:metadata}=await client.movePackageService.getPackage({packageId});
const deployed=response.object.package;
const hash=b=>createHash('sha256').update(b).digest('hex');
const localFiles=fs.readdirSync(moduleDir).filter(f=>f.endsWith('.mv'));
const modules=deployed.modules.map(m=>{
  const file=path.join(moduleDir,`${m.name}.mv`);
  if(!fs.existsSync(file))return {module:m.name,present:false,match:false};
  const built=fs.readFileSync(file);
  return {module:m.name,present:true,match:built.equals(m.contents),builtBytes:built.length,deployedBytes:m.contents.length,builtSha256:hash(built),deployedSha256:hash(m.contents)};
});
const extra=localFiles.filter(file=>!deployed.modules.some(m=>file===`${m.name}.mv`));
const result={verifiedAt:new Date().toISOString(),packageId,originalId:metadata.package.originalId,version:String(metadata.package.version??response.object.version),comparison:'Exact byte-for-byte module BCS; no normalization or exceptions',allModulesMatch:modules.every(m=>m.match)&&extra.length===0,modules,extra,linkage:deployed.linkage};
fs.writeFileSync(output,JSON.stringify(result,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n');
console.log(JSON.stringify({packageId,version:result.version,matched:modules.filter(m=>m.match).length,total:modules.length,extra,allModulesMatch:result.allModulesMatch,output}));
if(!result.allModulesMatch)process.exitCode=1;
