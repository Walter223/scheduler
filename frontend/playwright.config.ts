import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  // One catalog per invocation; distinct dates per test. CLI --workers still overrides.
  workers: 2,
  fullyParallel: false,
  globalSetup: './e2e/setup.ts',
  globalTeardown: './e2e/teardown.ts',
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:5174',
    timezoneId: 'America/Denver',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: [
    {
      command: 'mix ecto.create --quiet && mix ecto.migrate --quiet && mix run --no-start scripts/e2e.exs server',
      cwd: '../backend',
      env: { MIX_ENV: 'test', MIX_TEST_PARTITION: '_e2e', PORT: '4002' },
      url: 'http://127.0.0.1:4002/api/services',
      reuseExistingServer: false,
      timeout: 120_000,
      gracefulShutdown: { signal: 'SIGTERM', timeout: 5_000 },
    },
    {
      command: 'npm run dev -- --host 127.0.0.1 --port 5174 --strictPort',
      url: 'http://127.0.0.1:5174',
      env: { MAGNUM_API_UPSTREAM: 'http://127.0.0.1:4002' },
      reuseExistingServer: false,
      gracefulShutdown: { signal: 'SIGTERM', timeout: 5_000 },
    },
  ],
})
