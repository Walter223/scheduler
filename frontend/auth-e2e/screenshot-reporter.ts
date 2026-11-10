import { execFileSync } from 'node:child_process'
import type { FullResult, Reporter } from '@playwright/test/reporter'
export default class ScreenshotReporter implements Reporter {
  private since = Date.now()
  onEnd(result: FullResult) {
    if (result.status !== 'passed') return
    try {
      execFileSync(process.execPath, ['scripts/archive-screenshots.mjs', String(this.since)], {stdio:'inherit'})
    } catch { console.warn('Optional screenshot archive unavailable; original captures preserved.') }
  }
}
