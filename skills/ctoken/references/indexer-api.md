# cToken Indexer REST API

Public REST API for cToken wallets, history, and prices.

## Base URLs

- Base: `https://api.ctoken.inco.org/api`
- Base Sepolia: `https://api.ctoken.testnet.inco.org/api`

Open, with fair-use rate limits per IP. Localhost origins always work in the browser. Production apps should request origin whitelisting via the [whitelist form](https://docs.google.com/forms/d/e/1FAIpQLSe_lJoMc203TEgdQlL6PhPywG2EW3jdWIOo6QwvoBK0n1QCJQ/viewform?usp=header).

## Endpoints

| Endpoint | Returns |
|---|---|
| `GET /tokens` | All cTokens with name, symbol, decimals, underlying |
| `GET /tokens/:address` | One token, or `null` |
| `GET /tokens/:address/flows` | Wraps, unwraps, burns, with public amounts |
| `GET /tokens/:address/activity` | Confidential transfers, handles only |
| `GET /tokens/:address/disclosures` | Voluntarily revealed amounts |
| `GET /wallets/:address/assets` | Holdings with balance handles |
| `GET /wallets/:address/transactions` | Cross-token history for a wallet |
| `GET /wallets/:address/operators` | Operator approvals with expiry |
| `GET /factory` | Factory status: paused, blocklist |
| `GET /prices?tokens=a,b` | USD prices by underlying ERC-20 |
| `GET /icons/:address` | Redirects to the token logo, or `404` |

Amounts are decimal strings. Encrypted values only ever appear as `bytes32` handles.

## Pagination

List endpoints take `page` and `limit` (max 100) and return `{ items, total, page, pages, limit }`.

## Under load

Hot responses are cached briefly. When saturated the API answers `503` with a `Retry-After` header. Honor it, the SDK already does.

## Privacy

The indexer stores what the chain emits and nothing more. Public amounts exist only where the chain makes them public: wrap and unwrap legs, and explicit disclosures.
