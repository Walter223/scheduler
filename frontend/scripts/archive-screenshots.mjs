#!/usr/bin/env node
import {copyFileSync, existsSync, mkdirSync, readdirSync, statSync, utimesSync, writeFileSync} from 'node:fs'
import {homedir} from 'node:os'
import {join, basename} from 'node:path'
import {randomUUID} from 'node:crypto'
const groups = {'magnum-guided-onboarding':'7b-1-guide','magnum-branding-onboarding':'7a-5b-branding','magnum-admin-ux':'ux-1-admin','magnum-hr-ux':'ux-2-hr','magnum-calendar-ux':'ux-3-calendar','magnum-platform':'7a-3b-platform','magnum-signup':'6a-2b-signup','magnum-setup':'7a-3-setup','magnum-staff-onboarding':'7a-4-staff','magnum-catalog-onboarding':'7a-5a-catalog'}
export function syncScreenshots({root = process.env.MAGNUM_SCREENSHOT_ARCHIVE, source = '/private/tmp', since = 0} = {}) {
  if (!root && process.env.CI) return {skipped:true}
  root ||= join(homedir(), 'projects', 'Magnum-Screenshots')
  const run = new Date().toISOString().replaceAll(':','-') + '-' + randomUUID().slice(0,8)
  const counts = {}, missing = []
  mkdirSync(root,{recursive:true})
  for (const [folder,milestone] of Object.entries(groups)) {
    const path = join(source,folder)
    if (!existsSync(path)) {missing.push(folder);continue}
    for (const name of readdirSync(path)) {
      if (!name.endsWith('.png')) continue
      const file = join(path,name), info = statSync(file)
      if (!info.isFile() || info.mtimeMs < since) continue
      const area = folder.includes('guided') ? 'onboarding-setup' : folder.includes('branding') ? 'onboarding-setup' : folder.includes('catalog') ? 'services-pricing' : folder.includes('staff') || folder === 'magnum-setup' ? 'onboarding-setup' : folder.includes('calendar') ? 'calendar' : folder.includes('hr') ? 'employees-hr' : folder.includes('admin') ? 'admin' : folder.includes('signup') ? 'signup' : name.startsWith('setup') ? 'onboarding-setup' : name.startsWith('admin') ? 'admin' : name.startsWith('signup') ? 'signup' : 'platform'
      for (const dest of [join(root,milestone,run,name), join(root,'latest',area,`${milestone}-${basename(name)}`)]) {
        if (dest.includes('/latest/') && existsSync(dest) && statSync(dest).mtimeMs > info.mtimeMs) continue
        mkdirSync(join(dest,'..'),{recursive:true});copyFileSync(file,dest);utimesSync(dest,info.atime,info.mtime)
      }
      counts[milestone] = (counts[milestone] || 0) + 1
    }
  }
  writeFileSync(join(root,'README.md'), '# Magnum screenshot archive\n\nIntentional PNG captures only. Milestone/run folders preserve each sync; latest/<area> contains the newest capture for each milestone/page/viewport filename. Source modification times are preserved. Historical imports reflect source timestamps, not a new verification claim.\n\nOpen in Finder: `open "' + root + '"`.\n\nSync: from Scheduler run `node frontend/scripts/archive-screenshots.mjs`. Override destination with MAGNUM_SCREENSHOT_ARCHIVE. CI skips without an explicit destination. Traces, videos, failure artifacts and databases are excluded.\n')
  return {root,counts,missing}
}
if (process.argv[1]?.endsWith('archive-screenshots.mjs')) {
  try {console.log(JSON.stringify(syncScreenshots({since:Number(process.argv[2] || 0)})))} catch (error) {console.warn(`Optional screenshot archive unavailable: ${error.code || 'copy failed'}`)}
}
