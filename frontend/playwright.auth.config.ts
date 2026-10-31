import { defineConfig, devices } from '@playwright/test'

// Started only by scripts/bff_e2e.py; never reuse the developer's API/database.
export default defineConfig({
  testDir: './auth-e2e', workers: 1, fullyParallel: false, retries: 0,
  reporter: 'list', forbidOnly: Boolean(process.env.CI),
  use: {
    ...devices['Desktop Chrome'], baseURL: 'http://localhost:5174',
    trace: 'off', screenshot: 'off', video: 'off',
  },
})
