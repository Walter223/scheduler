import { test, expect } from './fixtures'

test('selection is exclusive, toggleable and accessible at 320px', async ({ page, catalog }) => {
  expect(catalog.services).toHaveLength(3)
  await page.setViewportSize({ width: 320, height: 900 })
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'View Services', exact: true })).toHaveAttribute('href', '/services')
  await expect(page.getByRole('link', { name: 'Check Availability', exact: true })).toHaveAttribute('href', '/contact')
  await page.getByRole('navigation').getByRole('link', { name: 'Services', exact: true }).click()
  const links = page.getByRole('link', { name: 'Book This Detail', exact: true })
  await expect(links).toHaveCount(3)
  for (const link of await links.all()) {
    await expect(link).toHaveAttribute('aria-disabled', 'true')
    await expect(link).toHaveAttribute('tabindex', '-1')
  }
  // Bypass only Playwright's disabled-action guard to test that the link's own
  // click handler prevents navigation. The disabled/accessibility checks stay.
  await links.first().click({ force: true })
  await expect(page).toHaveURL(/\/services$/)

  const mid = page.getByRole('heading', { name: 'Mid Detail', exact: true }).locator('..')
  const small = mid.getByRole('button', { name: /^Small\b/ })
  const medium = mid.getByRole('button', { name: /^Medium\b/ })
  const book = mid.getByRole('link', { name: 'Book This Detail' })
  await expect(small).toHaveAttribute('aria-pressed', 'false')
  await small.click()
  await expect(small).toHaveAttribute('aria-pressed', 'true')
  await expect(book).toHaveAttribute('aria-disabled', 'false')
  await expect(book).toHaveAttribute('tabindex', '0')
  await medium.click()
  await expect(small).toHaveAttribute('aria-pressed', 'false')
  await expect(medium).toHaveAttribute('aria-pressed', 'true')

  const supreme = page.getByRole('heading', { name: 'Supreme Detail', exact: true }).locator('..')
  const large = supreme.getByRole('button', { name: /^Large\b/ })
  await large.click()
  await expect(medium).toHaveAttribute('aria-pressed', 'false')
  await expect(page.getByRole('button', { pressed: true })).toHaveCount(1)
  await expect(book).toHaveAttribute('aria-disabled', 'true')
  await expect(book).toHaveAttribute('tabindex', '-1')
  await large.click()
  await expect(page.getByRole('button', { pressed: true })).toHaveCount(0)
  await expect(supreme.getByRole('link', { name: 'Book This Detail' })).toHaveAttribute('aria-disabled', 'true')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})

