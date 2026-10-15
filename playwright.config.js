import {defineConfig} from '@playwright/test';
export default defineConfig({testDir: './Tests/ui', workers: 1, use: {browserName: 'chromium', channel: process.env.PLAYWRIGHT_CHANNEL || undefined, headless: true}});
