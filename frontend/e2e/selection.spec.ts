import { test, expect } from './fixtures'

test('selection is exclusive, toggleable and accessible at 320px', async ({ page, catalog, homePage, servicesPage }) => {
  expect(catalog.services).toHaveLength(3)
  await page.setViewportSize({ width: 320, height: 900 })
  await homePage.goto()
  await expect(homePage.viewServicesLink).toHaveAttribute('href', '/services')
  await expect(homePage.checkAvailabilityLink).toHaveAttribute('href', '/contact')
  await homePage.openServices()
  const links = servicesPage.bookingLinks
  await expect(links).toHaveCount(3)
  for (const link of await links.all()) {
    await expect(link).toHaveAttribute('aria-disabled', 'true')
    await expect(link).toHaveAttribute('tabindex', '-1')
  }
  // Bypass only Playwright's disabled-action guard to test that the link's own
  // click handler prevents navigation. The disabled/accessibility checks stay.
  await servicesPage.bookingLink('Basic Detail').click({ force: true })
  await expect(page).toHaveURL(/\/services$/)

  const small = servicesPage.option('Mid Detail', 'Small')
  const medium = servicesPage.option('Mid Detail', 'Medium')
  const book = servicesPage.bookingLink('Mid Detail')
  await expect(small).toHaveAttribute('aria-pressed', 'false')
  await small.click()
  await expect(small).toHaveAttribute('aria-pressed', 'true')
  await expect(book).toHaveAttribute('aria-disabled', 'false')
  await expect(book).toHaveAttribute('tabindex', '0')
  await medium.click()
  await expect(small).toHaveAttribute('aria-pressed', 'false')
  await expect(medium).toHaveAttribute('aria-pressed', 'true')

  const large = servicesPage.option('Supreme Detail', 'Large')
  await large.click()
  await expect(medium).toHaveAttribute('aria-pressed', 'false')
  await expect(servicesPage.selectedOptions).toHaveCount(1)
  await expect(book).toHaveAttribute('aria-disabled', 'true')
  await expect(book).toHaveAttribute('tabindex', '-1')
  await large.click()
  await expect(servicesPage.selectedOptions).toHaveCount(0)
  await expect(servicesPage.bookingLink('Supreme Detail')).toHaveAttribute('aria-disabled', 'true')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})

