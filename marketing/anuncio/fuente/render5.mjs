import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import fs from 'fs';
const mode = process.argv[2] || 'preview';
const b = await chromium.launch();
const p = await b.newPage({viewport:{width:540,height:960}, deviceScaleFactor:2});
const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('console',m=>m.type()==='error'&&errs.push(m.text()));
const dur = fs.existsSync('dur.json') ? fs.readFileSync('dur.json','utf8') : 'null';
await p.addInitScript(`window.DUR=${dur}||undefined;`);
await p.goto('file://'+process.cwd()+'/anuncio_v5.html');
await p.evaluate(()=>document.fonts.ready);
await p.waitForTimeout(400);
if (mode==='preview'){
  for (const t of process.argv.slice(3).map(Number)){ await p.evaluate(t=>seek(t),t); await p.screenshot({path:`pv/pv_${t}.png`}); }
} else {
  fs.mkdirSync('frames5',{recursive:true});
  const fps=30, total=await p.evaluate(()=>TOTAL);
  const first=+(process.argv[3]||0), last=Math.min(+(process.argv[4]||1e9),Math.ceil(total*fps));
  for (let i=first;i<last;i++){
    await p.evaluate(t=>seek(t), i/fps);
    await p.screenshot({path:`frames5/${String(i).padStart(5,'0')}.jpg`, type:'jpeg', quality:92});
  }
  console.log('total',total);
}
console.log('errors',errs);
await b.close();
