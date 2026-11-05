# Deterministic Route Mocking & Fixture Matrix

Visual Regression Testing (VRT) must be 100% deterministic, reproducible offline, and independent of live database states or rate-limit expirations.

---

## Determinism requirements

- render the app deterministically: pinned browser, bundled fonts, frozen clock, animations disabled, mocked network data;
- write PNG screenshots plus `{out}/manifest.json`:
  - `key` matches `^[A-Za-z0-9._/@-]{1,120}$` and is unique.
  - `file` is a relative path inside `{out}`.
  - `component` and `viewport` are free text, at most 80 characters.

---

## 1. Principles of Deterministic VRT

1. **Zero Database Dependency**: Intercept API requests in Playwright using `page.route()` and respond with static, deterministic JSON fixtures.
2. **Frozen Clocks / Time**: If components display relative timestamps (e.g., "5 seconds ago", "updated 12:43 PM"), mock the Date object or inject fixed ISO strings in the payload.
3. **Consistent Dimensions**: Fixed desktop (`1280x900`) and mobile (`390x844`) viewport dimensions.
4. **Font Loading Completion**: Wait for `document.fonts.ready` before taking snapshots to prevent intermittent font rendering diffs.

---

## 2. Playwright Route Mocking Pattern

```javascript
// Intercept API endpoint with static test fixture
await page.route('**/api/items', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(MOCK_FIXTURE_ITEMS),
  });
});

// Intercept secondary/detail endpoint
await page.route('**/api/item-detail', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(MOCK_FIXTURE_DETAIL),
  });
});
```

---

## 3. Scenario Matrix Template

Each scenario should test a specific component state:

| Scenario ID | Title | Route / State | Interaction Target |
| :--- | :--- | :--- | :--- |
| `01-button-default` | Button (Default) | Default state | None |
| `01-button-active` | Button (Active) | Default state | Click `.<prefix>-button__btn--active` |
| `02-card-default` | Card (Default) | Full mock state | None |
| `02-card-expanded` | Card (Expanded) | Full mock state | Click `.<prefix>-card__toggle-btn` |
| `03-list-empty` | Item List (Empty) | Empty mock state | None |
| `03-list-populated` | Item List (Populated) | Multi-item state | None |
| `04-drawer-open` | Drawer (Open) | Item selected | Click trigger or open drawer |
