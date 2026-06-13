const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ deviceScaleFactor: 4 });
  const p = await ctx.newPage();
  // render favicon svg at 64 and at 24 (favicon-ish) on a white bg with a label
  await p.setContent(`<body style="margin:0;background:#fff;display:flex;gap:30px;align-items:center;padding:30px;font-family:sans-serif">
    <img src="http://localhost:3106/fav.svg" width="96" height="96">
    <img src="http://localhost:3106/fav.svg" width="48" height="48">
    <img src="http://localhost:3106/fav.svg" width="24" height="24">
    <img src="http://localhost:3106/fav.svg" width="16" height="16">
  </body>`);
  await p.waitForTimeout(400);
  await p.screenshot({ path: '/tmp/fav-check.png' });
  await browser.close();
  console.log('ok');
})();
