import fs from 'node:fs';
import path from 'node:path';

const rootDir = process.cwd();
const publicDir = path.join(rootDir, 'public');
const distDir = path.join(rootDir, 'dist');

fs.mkdirSync(publicDir, { recursive: true });
fs.mkdirSync(distDir, { recursive: true });

const rootIndex = path.join(rootDir, 'index.html');
const publicIndex = path.join(publicDir, 'index.html');
const distIndex = path.join(distDir, 'index.html');

if (fs.existsSync(rootIndex)) {
  const html = fs.readFileSync(rootIndex, 'utf-8');
  fs.writeFileSync(publicIndex, html, 'utf-8');
  fs.writeFileSync(distIndex, html, 'utf-8');
}

const healthPayload = JSON.stringify({
  status: 'HEALTHY',
  app: 'modular-pos-monorepo',
  phasesCompleted: 9,
  vercelReady: true,
  builtAt: new Date().toISOString()
}, null, 2);

fs.writeFileSync(path.join(publicDir, 'health.json'), healthPayload, 'utf-8');
fs.writeFileSync(path.join(distDir, 'health.json'), healthPayload, 'utf-8');

console.log('✔ Modular POS Vercel static bundle prepared in public/ and dist/');
