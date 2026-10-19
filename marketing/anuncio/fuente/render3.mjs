import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
const mode = process.argv[2] || 'preview';
const b = await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
const p = await b.newPage({viewport:{width:540,height:960}, deviceScaleFactor:2});
const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('console',m=>m.type()==='error'&&errs.push(m.text()));
await p.goto('file://'+process.cwd()+'/ad2.html');
await p.evaluate(()=>document.fonts.ready);
await p.waitForTimeout(300);
if (mode==='preview'){
  const ts = process.argv.slice(3).map(Number);
  for (const t of ts){ await p.evaluate(t=>seek(t),t); await p.screenshot({path:`pv_${t}.png`}); }
} else {
  const fps=30, total=await p.evaluate(()=>TOTAL);
  const first=+(process.argv[3]||0);
  const last=+(process.argv[4]||Math.round(total*fps)); for (let i=first;i<last;i++){
    await p.evaluate(t=>seek(t), i/fps);
    await p.screenshot({path:`frames2/${String(i).padStart(5,'0')}.jpg`, type:'jpeg', quality:93});
  }
}
console.log('errors',errs);
await b.close();
