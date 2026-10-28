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

// Independent expectations for the source-controlled catalog, not values copied
// from the API response under test. IDs alone come from the isolated fixture.
for (const [name, sizes] of [
  ['Basic Detail', [['Small', '$59.99', 60], ['Medium', '$89.99', 90], ['Large', '$109.99', 120]]],
  ['Mid Detail', [['Small', '$89.99', 90], ['Medium', '$119.99', 120], ['Large', '$139.99', 150]]],
  ['Supreme Detail', [['Small', '$129.99', 150], ['Medium', '$159.99', 180], ['Large', '$179.99', 230]]],
] as const) {
  for (const [size, price, duration] of sizes) {
    test(`${name} / ${size} hands off the correct selection, price and duration`, async ({ page, catalog }) => {
      const service = catalog.services.find((entry) => entry.name === name)!
      const offering = service.prices.find((entry) => entry.vehicle_size === size)!
      await page.goto('/services')
      const card = page.getByRole('heading', { name, exact: true }).locator('..')
      const option = card.getByRole('button', { name: new RegExp(`^${size}\\b`) })
      await expect(option).toContainText(price)
      await expect(option).toContainText(`${duration} min`)
      await option.click()
      await card.getByRole('link', { name: 'Book This Detail' }).click()
      await expect(page).toHaveURL(`/contact?service=${service.id}&size=${offering.vehicle_size_id}`)
      await expect(page.getByRole('heading', { name, exact: true })).toBeVisible()
      await expect(page.getByText(`${size} Vehicle`, { exact: true })).toBeVisible()
      await expect(page.getByText(price, { exact: true })).toBeVisible()
      await expect(page.getByText(`${duration} min`, { exact: true })).toBeVisible()
      await expect.poll(() => page.evaluate(() => scrollY)).toBe(0)
    })
  }
}
