import { test, expect } from './fixtures'

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
