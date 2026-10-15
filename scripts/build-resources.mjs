import fs from 'node:fs';
import { build } from 'esbuild';
import {fileURLToPath} from 'node:url';
import { buildGeminiLiveSetup } from '../FaceSource/frontend/js/gemini/geminiLiveTools.js';

const root = new URL('../', import.meta.url);
process.chdir(fileURLToPath(root));
const destination = 'Native/Sources/LooiNative/Resources';
fs.mkdirSync(`${destination}/Face`, {recursive: true});
await build({entryPoints: ['FaceSource/mobile/face/entry.js'], outfile: `${destination}/Face/face.js`, bundle: true, minify: true, format: 'iife', target: 'safari15'});
for (const name of ['index.html', 'face.css']) fs.copyFileSync(`FaceSource/${name}`, `${destination}/Face/${name}`);
fs.writeFileSync(`${destination}/LiveSetup.json`, JSON.stringify(buildGeminiLiveSetup({model: 'gemini-3.8-live'})));
console.log('Eye animation, original motion engine and Live configuration rebuilt.');
