// Render the explainer at a true 390px viewport and report any element wider than it.
// Usage: node tests/render-phone.js <path-to-playwright-module>
const { chromium } = require(process.argv[2]);
const path = require('path');

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.resolve(__dirname, '../docs/show-me-orchard.html'));
  const report = await page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    const wide = [...document.querySelectorAll('body *')]
      .filter((el) => el.getBoundingClientRect().right > vw + 1 && !el.closest('pre, .table-wrap'))
      .slice(0, 8)
      .map((el) => `${el.tagName.toLowerCase()}.${el.className?.baseVal ?? el.className} right=${Math.round(el.getBoundingClientRect().right)}`);
    return { vw, scrollWidth: document.documentElement.scrollWidth, wide };
  });
  console.log(JSON.stringify(report, null, 2));
  await page.screenshot({ path: '/tmp/orchard-doc-phone.png', fullPage: true });
  await browser.close();
})();
