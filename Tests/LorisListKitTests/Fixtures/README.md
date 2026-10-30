# API fixtures

Each file is one response from the Lori's List API: `{ "status": 200, "body": { ... }, "headers": { ... } }`.

They were recorded by running the server's real API code (`lib/api.js` in
`horinezachary/shoppingList`, branch `mobile-api`) against its in-memory test database, through a full
sign-up, sign-in, lists, items, sharing and sign-out session, including the error cases. They are not
hand-written, so they show what the server sends rather than what its docs say.

Re-record them with `node scripts/capture-fixtures.js`. Only the random tokens and the share key change.

A few worth knowing:

| File | Why it matters |
| --- | --- |
| `refresh_ok` | Only `accessToken`, `tokenType`, `expiresIn`. No `user`, no `refreshToken`. |
| `me_with_replaced_token` | 401. After a refresh the previous access token is dead. |
| `list_with_items` | `count` is `null` for items without a quantity. |
| `lists_two` | `lastChange` is a number here (the test database); the spec says an ISO string. Both are accepted. |
| `login_rate_limited` | 429 with a `Retry-After` header. |
| `account_deleted` | 204 from `DELETE /me`. Every token for the account is gone afterwards (`after_account_deleted_unauthorized`). |
