import { test, expect } from '@playwright/test';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const faceURL = pathToFileURL(path.resolve('Native/Sources/LooiNative/Resources/Face/index.html')).href;

test.beforeEach(async ({page}) => {
  await page.addInitScript(() => {
    window.__commands = [];
    window.webkit = {messageHandlers: {face: {postMessage(message) {
      if (message.kind === 'ready') { window.__ready = true; return; }
      window.__commands.push(message);
      setTimeout(() => window.looiFace.reply(message.id, {type: 'ack', accepted: true}, window.__failMotion && message.payload?.type === 'motion' ? 'ACK failed' : null), 0);
    }}}};
  });
  await page.goto(faceURL);
  await page.waitForFunction(() => window.__ready && window.looiFace);
});

test('isolated original eyes resize and run original motion without the web application', async ({page}) => {
  const requests = [];
  page.on('request', request => requests.push(request.url()));
  for (const viewport of [{width:390,height:844},{width:844,height:390},{width:390,height:844}]) {
    await page.setViewportSize(viewport);
    const box = await page.locator('.looi-eye').first().boundingBox();
    expect(box.width).toBeGreaterThan(80); expect(box.width).toBeLessThan(viewport.width / 2);
    expect(box.height).toBeLessThan(viewport.height);
  }
  await page.evaluate(() => window.looiFace.state({connected: true, speaking: true, cameraRunning: false}));
  await expect(page.locator('.looi-eyes')).toHaveClass(/is-speaking/);
  const result = await page.evaluate(() => window.looiFace.run('look_left', true));
  expect(result.ok).toBe(true); expect(result.partial).toBe(false);
  const motion = await page.evaluate(() => window.__commands.find(message => message.payload?.type === 'motion')?.payload);
  expect(motion.angular).toBe(-0.055); expect(motion.duration_ms).toBe(170);
  expect(await page.locator('.runtime-gate,.mobile-provider-panel').count()).toBe(0);
  expect(requests.some(url => /^https?:/.test(url))).toBe(false);
});

test('motion failure and disabled camera cannot be reported as completed actions', async ({page}) => {
  await page.evaluate(() => {window.looiFace.state({connected: true}); window.__failMotion = true;});
  const motion = await page.evaluate(() => window.looiFace.run('look_right', true));
  expect(motion.partial).toBe(true);
  const photo = await page.evaluate(() => window.looiFace.run('take_picture', false));
  expect(photo.ok).toBe(false);
  expect(await page.evaluate(() => window.__commands.filter(message => message.kind === 'photo').length)).toBe(0);
});
