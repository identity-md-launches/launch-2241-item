# Basket Protocol: ITEM reward token and contracts

Reward token and four application contracts for Basket Protocol (vault token BASK) on Robinhood Chain
(chain id 4663). Foundry project at the repository root: `forge build`, `forge test`,
`forge fmt --check`. There is no dapp: the only page is a static token logo page (`web/` → `dist/`, see
[Token logo page](#token-logo-page)) that shows and serves ITEM's logo files. It has no wallet connection
and makes no chain calls.

## Contracts

| Solidity name    | File                     | Constructor arguments                                     |
| ---------------- | ------------------------ | --------------------------------------------------------- |
| `LaunchToken`    | `src/LaunchToken.sol`    | none                                                      |
| `ItemStaking`    | `src/ItemStaking.sol`    | `address item` = `$token`                                 |
| `BaskUsdgGauge`  | `src/BaskUsdgGauge.sol`  | `address item` = `$token`                                 |
| `ItemEthGauge`   | `src/ItemEthGauge.sol`   | `address item` = `$token`                                 |
| `DevVesting`     | `src/DevVesting.sol`     | `address item` = `$token`, `address beneficiary` = `0xc5e21e7A89F1fBDc5554e31702e627dD6262C856` |

Shared code: `src/LpGauge.sol` (abstract gauge base), `src/ReentrancyGuard.sol`,
`src/libraries/RewardMath.sol` (512-bit mulDiv, 1e36 index, carry accrual) and
`src/libraries/TokenTransfer.sol` (transfer helpers). Every library function is internal, so nothing is
linked at deploy time. No contract has an owner, admin, pause, upgrade, rescue or sweep path, and none uses
delegatecall or selfdestruct. Constructors call no other contract.

Fixed addresses compiled in as constants, all on chain 4663:

| Name         | Address                                      |
| ------------ | -------------------------------------------- |
| `BASK`       | `0x739fD5B653aA092a434534FA1aDE67C1770b5a5B` |
| `USDG`       | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| `WETH`       | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `V2_FACTORY` | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |

### LaunchToken (ITEM)

Standard launch token: name `Item`, symbol `ITEM`, 18 decimals, 1,000,000,000 tokens minted once to the
deployer (the factory). No mint, owner, pause, blocklist, fee or upgrade functions. The brief asked for
nothing beyond the standard token, so nothing was left out.

### ItemStaking

Stake ITEM, earn BASK, USDG and WETH. Anyone may send a reward token to the contract; the Basket vault
sends BASK fees here once this contract is its fee recipient, with no call into it.

- `stake(amount)` and `unstake(amount)` work at any time, move only ITEM, and never transfer a reward
  token. They run `sync` for all three tokens first, so no reward token can block them.
- `sync(token)` first advances the live stream to now. Stream time passes only while `totalStaked > 0`;
  the sync timestamp still moves while nothing is staked. A stream of `F` has released `floor(F * s / D)`
  after `s` staked seconds, with `s` capped at `D` = 7 days. It then reads `balanceOf(this)` by
  staticcall with 50,000 gas, copying at most 32 bytes; the read is valid only on success with exactly 32
  bytes. If the read is invalid, below `accounted`, or `fresh = balance - accounted` is above 1e30, no
  stream starts. Otherwise, if `fresh > 0` and no stream is unfinished, `accounted += fresh` and a stream
  of `F = fresh` starts now. A live stream is never backdated, restarted or changed; later amounts wait.
- `claim(token)` syncs only that token and pays `min(accrued, balance read)`; the rest stays owed. An
  invalid read or a failed or false transfer reverts the claim whole.
- `accounted` per token is all stream amounts minus all payments.

### Gauges (BaskUsdgGauge, ItemEthGauge)

Stake the canonical v2 LP of (tokenA, tokenB), earn ITEM. `BaskUsdgGauge`: BASK/USDG, allocation
490,000,000 ITEM. `ItemEthGauge`: ITEM/WETH, allocation 210,000,000 ITEM.

- `start()`: once. Requires `V2_FACTORY.getPair(tokenA, tokenB)` to be non-zero, stores the pair and
  pulls exactly `ALLOCATION` of ITEM from the caller. ITEM sent any other way is ignored and stays in the
  contract. `stake` reverts before start.
- `released(t) = ALLOCATION * t * (2T - t) / T^2`, `T` = 4 * 365 days, `t` = seconds since start during
  which `totalStaked > 0`, capped at `T`. Paid pro rata to staked LP.
- `stake(amount)`, `withdraw(amount)`, `claim()`. Only `claim()` pays ITEM; `withdraw` moves only the LP,
  so it always works. A failed claim reverts whole and the amount stays owed.

### DevVesting

40,000,000 ITEM to the fixed beneficiary. `fund()` pulls exactly the allocation once from the caller.
`elapsed` counts from deployment: nothing vests before 365 days, then
`ALLOCATION * min(elapsed, 1460 days) / 1460 days`. `release()` by anyone after `fund()` sends
`vested - released` to the beneficiary. Not revocable. The constructor reverts on a zero beneficiary.

### Reward accounting (gauges and ItemStaking)

One index per reward token at 1e36 precision, grown by `mulDiv(released, 1e36, totalStaked)` rounding
down. Before any stake change the global index is updated, then the caller. A user accrues
`floor((stake * (index - userIndex) + carry) / 1e36)` and keeps the remainder as carry across claims and
exits. Release is always the difference of the cumulative formulas, never a per-second rate. Total payouts
never exceed what the contract received; the dust lost to rounding is at most a few wei per claim and stays
in the contract.

## Token logo

ITEM's own logo, for chain 4663 at `0x4f1b7a5aaf3768f7500e9ab5cbbf3762834e8b57`, lives in
`assets/logo/`. The 256 x 256 PNG is the token image. Every file is byte-for-byte what the IPFS gateway
served for its CID, with no redrawing or re-encoding. `assets/logo/logo.json` lists the same CIDs, sizes
and SHA-256 hashes.

| File           | Use                 | CID                                                           |
| -------------- | ------------------- | ------------------------------------------------------------- |
| `item-256.png` | Token image, 256 px | `bafkreifenq2t55lzpff6ffoxct6klzoy6ur3rbscdpjdrkp3e42kumxpby` |
| `item.svg`     | SVG master          | `bafkreicqjagwzaq63lpsnlb2gq4nl7wtplqz5772jomqgvpsbva3ohws2e` |
| `item-32.svg`  | 32 px SVG           | `bafkreihtkwltlruqamom7sgy43jxdchkydqflruzzghbkbe37g3c33vbt4` |
| `item-64.svg`  | 64 px SVG           | `bafkreiejgix7cndhixbbbs5r6olnnjr3qvjpyhgvddafxbda7mpcpni6e4` |

To check the bytes, recompute each CID (CIDv1, raw codec, sha2-256) from its file and compare it with the
table, or compare `sha256sum assets/logo/*` with `logo.json`. If you submit the token's logo to a block
explorer (RobinScan, Blockscout), use these same files.

## Token logo page

A one-page static site that shows ITEM's logo and serves the four files above for download. It shows each
file's CID and SHA-256, can hash the served files in the browser, and lists the token facts (name, symbol,
decimals, chain, contract). It changes nothing about the token, pool or contracts. It has no wallet and no
RPC calls. Vite 6 and TypeScript 5, no UI framework. Design system: [DESIGN.md](DESIGN.md).

| Path | What it is |
| --- | --- |
| `web/index.html` | Document head (title, description, favicon, og:title, og:image) and header |
| `web/src/main.ts` | Page markup, the Copy address button and the SHA-256 check |
| `web/src/logo.ts` | Reads `assets/logo/logo.json`; hashing helper |
| `web/src/config.ts` | Chain name, ID and explorer from the pinned network file; token decimals |
| `web/src/style.css` | Design tokens and all component styles |
| `web/package.json`, `web/package-lock.json` | Manifest and lockfile (registry.npmjs.org only) |
| `dist/` | Committed production export served as is: `index.html`, `assets/` (hashed JS and CSS), `logo/` |

`dist/logo/` is Vite's public dir `assets/` copied unchanged, so the files the page serves are the files in
`assets/logo/`, byte for byte. Every URL in the export is relative (`base: "./"`), so the site works from a
gateway subpath or an ENS name. `web/.gitignore` excludes only `web/node_modules/`.

### Install, preview, rebuild

Node 18 or newer (checked with Node 24.21.0).

```sh
cd web
npm ci                 # install the exact versions in package-lock.json
npm run dev            # live development server
npm run build          # tsc --noEmit, then vite build into ../dist (replaces it)
npm run preview        # serve the built ../dist locally
npm run typecheck      # tsc --noEmit only
```

After changing anything in `web/` or `assets/logo/`, run `npm run build` and commit `dist/` with the source.
The host serves the committed `dist/` and does not rebuild.

### Validation (2026-10-19, final source)

| Check | Command | Result |
| --- | --- | --- |
| Typecheck | `npm run typecheck` (TypeScript 5.9.3) | passed, no errors |
| Production build | `npm run build` (Vite 6.4.4) | passed: `dist/index.html` 2.28 kB, CSS 6.83 kB, JS 8.72 kB |
| Logo bytes in the export | `cmp`, `sha256sum dist/logo/* assets/logo/*` | identical to `logo.json` hashes |
| Design probe taste@1 | `node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste` (Playwright from outside the repository via `IMD_PLAYWRIGHT`) | **16/16 passed** at 320, 390 and 1440: render, layout, targets, contrast, casing, tracking, eyebrows, type-sizes (4 sizes), type-faces (2 families, weights 400/600), glyphs, slogans, repetition, copy-budget (15 prose words on the 390 first screen), chrome, motion, share |
| Interaction tests | a Playwright script in the scratch area (not committed). It serves `dist/` under `/preview/` and drives Google Chrome 154 (Playwright, `channel: "chrome"`) at 320, 390 and 1440 | **33 assertions passed, 0 failed**, four runs in a row on the final export |

The interaction tests covered:

- No console errors, failed requests or horizontal scroll at any width.
- The logo and the "Download 256 px PNG" button are on the first screen at 320×844, 390×844 and
  1440×844.
- The hero image and all thumbnails load.
- All four downloads save the right file name with bytes identical to `assets/logo/`.
- "Copy address" puts `0x4f1b7a5aaf3768f7500e9ab5cbbf3762834e8b57` on the clipboard and shows "Address
  copied."
- "Check SHA-256 hashes" reports "All 4 files match their SHA-256." and each row shows a match.
- With one file swapped for other bytes, it reports "3 of 4 files match" and marks the row. With a file
  request aborted, the row reports "Unable to load the file".
- The button is re-enabled after each check.
- The first Tab stop is the skip link, which focuses `<main>`. The next six stops each show a 2px solid
  focus outline.
- The title, description, og:title, og:image and favicon are present.

I looked at the screenshots at 320, 390 (including a focused state) and 1440. At 390 the first screen
shows the title, the one-line description, the logo, both download buttons and the token address.

Limitations, not checked:

- WebKit/Safari was not run (the WebKit browser is not installed on this machine). Only Google Chrome was
  used.
- No screen-reader session, no native 200% browser zoom (the narrow viewport at 320 stands in for reflow),
  no physical device.
- The clipboard fallback path for an insecure context and the "only on an HTTPS page" message were not
  exercised in a browser.
- `og:image` is a relative path, as static hosting requires. Some unfurlers need an absolute URL, which
  is only known once the site is hosted.
- Whether RobinScan or Blockscout accept the files is outside this repository. No logo was submitted to
  either explorer by this job.

### Better Interface review

The page was built and reviewed with the pinned Better Interface guide (all six domains).
`artifacts/validation.md` holds the same record with more detail.

| Domain | Coverage | Notes |
| --- | --- | --- |
| Accessibility | Checked | Native `<a download>` and `<button>`, one `h1` and nested `h2`/`h3`, a `<main>` landmark, a skip link, `:focus-visible` 2px outline, polite `role="status"` regions for copy and the hash check, informative alt on the hero logo and `alt=""` on decorative thumbnails, `prefers-reduced-motion` guard. The keyboard walk ran in Chrome. Not run: a screen reader or an automated axe audit. |
| Layout | Checked | One column under 40rem, three-column file rows from 40rem, two-column hero from 52rem. Logical properties throughout. Long hashes wrap (`overflow-wrap: anywhere`). No horizontal scroll at 320/390/1440. Not run: an RTL mirror (no RTL locale is shipped). |
| Writing | Checked | Verb-first labels that name the file. Sentence case. Errors say how to recover ("Reload and try again", "press Ctrl+C or Cmd+C"). No em dashes or emoji. |
| Typography | Checked | 4 sizes, 2 weights, a system sans plus monospace for data only. Headings balanced, intros `pretty`, measure capped at 34 to 40rem. |
| Colors | Checked | Role tokens over hex primitives. One filled action per view. Status is never colour alone. Contrast computed from declared pairs (lowest text pair 6.75:1) and measured by the probe. |
| UI | Checked | Flat surfaces with no shadows. Radius 0.5rem for controls and 1rem for the tile. Scale 0.96 on press, only `scale` and `background-color` transition, 150ms. Not applicable: overlays, theme switch, icon animations (none exist). |

Findings, all fixed before the final build:

1. Medium, `web/src/style.css:253`. The hero image carried a 1px outline inside the white tile. Because
   the PNG has a transparent background, this drew a second frame (seen on the 390 screenshot). The
   outline and its token were removed, and the 390 screenshot was rechecked.
2. Low, `web/src/main.ts:19`. File metadata read "token image. PNG, 256 × 256…": lowercase start and a
   repeated type. It now reads "Token image · 256 × 256 PNG · 8,740 bytes", and the probe was rerun.
3. Low, `web/src/main.ts:31`. Thumbnails used `loading="lazy"`, which left `item-64.svg` blank in a
   full-page capture. These files are under 1 KB each, so the attribute was removed. The test checks that
   every thumbnail loads.
4. Low, `web/index.html:35`. The header RobinScan link had `href="#"` until script ran. It is now a
   static link to the token on RobinScan.
5. Low, `web/src/style.css:108`. The probe reported a control under the comfortable 44px. Measured at
   390: "Copy address" (a `.button--small` variant) and the skip link were each 40px tall. The small
   variant was deleted, and the skip link got `min-height: 2.75rem`. The probe now reports 0 controls
   under 44px.

Remaining notes:

- The focus outline on the filled primary button sits 2px outside it, on the page background (6.75:1).
  Against the button's own ink fill the blue would be 2.42:1, but the 2px offset keeps the two apart.

## Views

- Gauges: `item`, `tokenA`, `tokenB`, `V2_FACTORY`, `ALLOCATION`, `T`, `pair`, `started`, `stakedSeconds`,
  `released`, `rate`, `remaining`, `totalStaked`, `staked(user)`, `earned(user)`. `rate` is
  `2 * ALLOCATION * (T - t) / T^2` per second while `totalStaked > 0`, else 0.
- ItemStaking: `item`, `BASK`, `USDG`, `WETH`, `STREAM_DURATION`, `MAX_FRESH`, `totalStaked`,
  `staked(user)`, `earned(user, token)`, `rewardInfo(token)`.
- DevVesting: `item`, `beneficiary`, `ALLOCATION`, `CLIFF`, `DURATION`, `deployedAt`, `funded`, `vested`,
  `released`.

## Deployment parameters

The launch deploys the token then the four contracts, in the order of the table above, each with the
arguments listed there. `$token` is the deployed `LaunchToken`. The DevVesting beneficiary is the literal
address the brief gives. No contract takes an owner, and none should: there is nothing to administer.
Settings: `solc 0.8.26`, optimizer on at 200 runs, `evm_version = cancun`, `bytecode_hash = none`.

## After launch: operational responsibilities

The contracts have no privileged roles, so these are plain transactions anyone holding the tokens can send.
The ITEM for them comes from the requester's share of the supply, not from the contracts.

1. Create the BASK/USDG and ITEM/WETH pairs on the v2 factory. `start()` reverts with `NoPair` until
   `getPair` returns a non-zero address.
2. Approve and call `start()` on `BaskUsdgGauge` with 490,000,000 ITEM and on `ItemEthGauge` with
   210,000,000 ITEM. Whoever calls pays; the gauge pulls exactly the allocation.
3. Approve and call `fund()` on `DevVesting` with 40,000,000 ITEM. Vesting time runs from deployment,
   not from funding, so a late fund does not delay the schedule.
4. Set `ItemStaking` as the Basket vault's fee recipient. BASK fees then arrive by plain transfer and are
   streamed after the next `sync(BASK)`, `stake` or `unstake`.
5. Anyone may call `release()` on `DevVesting` and `sync(token)` on `ItemStaking` at any time.

## Assumptions and accepted behaviour

- BASK, USDG and WETH are plain ERC-20s whose issuer may burn balances. ITEM and the v2 LP tokens are
  plain ERC-20s returning `true`. Fee-on-transfer or rebasing tokens are not supported by the gauges or
  the stake path; the reward path tolerates any behaviour without blocking stake or unstake.
- `V2_FACTORY.getPair` returns the canonical pair or zero. The gauge reads it once, at `start()`.
- No staking lock in any contract.
- The first LP staker in a gauge earns alone until others join; gauge time only runs while something is
  staked, so an idle gauge keeps its allocation.
- While an issuer burn leaves ItemStaking short of a token, claims of that token are first come, first
  served; the unpaid amount stays owed and is paid when the balance returns. No stream starts while the
  balance is below `accounted`.
- A single deposit above 1e30 units of a reward token, or a balance read that is invalid, never starts a
  stream. If the fresh balance ever exceeds 1e30 it stays ignored until payments or burns bring it back
  under the cap.
- A stream started while nothing is staked waits for the first staker; later deposits wait for it to
  finish. Streams run over staked time, so rewards cannot be captured by a flash stake.
- Gauge `start()` and `DevVesting.fund()` are open calls: the first caller with the allocation funds the
  contract. Neither is revocable.
- Timestamps are `block.timestamp`; a builder can nudge them by seconds, which moves rewards by the same
  seconds and nothing more.
- This is not an audit. The contracts hold other people's funds, so they need an independent adversarial
  review before launch.

## Tests

`test/LaunchToken.t.sol`, `test/LpGauge.t.sol` (one suite run against both gauges), `test/ItemStaking.t.sol`
and `test/DevVesting.t.sol`, with mocks under `test/mocks/`. They cover every rule above and its reverts,
lone and odd-sized stakers (paid at most released, last claimer in full), rounding at 1 wei and 1e27,
hostile reward tokens (revert, false, gas burn, huge or short data, reporting 0 or 2^256-1), partial issuer
burns, reentrancy through the LP and reward tokens, the release curve and its cap, time with nothing
staked, and DevVesting on days 364, 365 and 1,460. Fuzz tests check that payouts never exceed receipts.
Tests use no forks, environment variables or filesystem access. forge-std is vendored under
`lib/forge-std` as plain files.
