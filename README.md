# Basket Protocol: ITEM reward token and contracts

Reward token and four application contracts for Basket Protocol (vault token BASK) on Robinhood Chain
(chain id 4663). No website. Foundry project at the repository root: `forge build`, `forge test`,
`forge fmt --check`.

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
