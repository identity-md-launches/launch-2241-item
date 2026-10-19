# Basket Protocol test coverage

Run the complete offline suite with the assignment's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xc607832cdffea31bf2f926d2881584bb83d302525302ac50e5be34dec731816c forge test
```

The original tests remain intact. Additional suites cover:

| Suite | Properties and failure paths |
| --- | --- |
| `ItemStakingAdversarial.t.sol` | Carry across complete exits, late arrivals, same-timestamp stakes, atomic failed claims and principal transfers, malformed balance responses, all three hostile rewards together, callback reentrancy, gas exhaustion, and oversized transfer responses. |
| `ItemStakingInvariant.t.sol` | Three actors randomly stake, exit, donate, burn rewards, advance time, sync, claim, and change token behavior. Independent inflow/outflow totals reconcile principal and rewards; successful stream events reconcile `accounted`; partial claims preserve unpaid debt. Every sequence ends with full principal withdrawal under the reached hostile state. Burned reward shortfalls are then restored to check debt settlement. |
| `GaugeAdversarial.t.sol` | Both concrete gauges: failed funding and LP transfers, canonical-pair errors and caching, hostile ITEM isolation, claim rollback, callback entry points, single-transaction LP borrowing, late entry, fractional carry through repeated exits, and randomized claim order. |
| `GaugeInvariant.t.sol` | Both gauges, four actors: deposits, withdrawals, claims, time changes, donations, full exits, rejected over-withdrawals, and instantaneous round trips. Ghost transfers reconcile custody, individual stakes, and payments; a separate active clock checks release and idle periods. Unpaid release is bounded by documented index/user rounding dust. Every sequence ends with all principal returned and existing debt paid. |
| `DevVestingAdversarial.t.sol` | Literal beneficiary, permissionless funding/release, failed funding retry, day 364 and cliff/completion adjacent seconds, cumulative rounding, donations, malformed transfers, and fund/release callback combinations. |
| `DevVestingInvariant.t.sol` | Random funding, donations, time advances, and releases using the real ITEM supply. Actual beneficiary receipts reconcile custody, funding is one-time, the deployment-based cliff and floor hold, and full maturity remains payable. |
| `LaunchTokenAdversarial.t.sol`, `LaunchTokenInvariant.t.sol` | Fixed supply, actual balances and finite/infinite allowances across actor transfers, self-transfers, approvals, rejected spending, and failed delegated transfers. |
| `RewardMathProperties.t.sol` | Full 512-bit multiplication/division checked with an independent 128-bit-limb quotient/remainder identity; carry preservation, split-claim equivalence, overflow, one wei, and `1e27`. |
| `BalanceReadBoundary.t.sol` | The balance query is static, receives the specified gas stipend, and cannot let a reward token write state or obstruct principal withdrawal. |
| `ProjectBoundaries.t.sol` | All five contracts deploy in one transaction with no constructor calls; fixed supply remains at the deployer. Runtime opcode checks, common forbidden administrative selectors, and a combined real-ITEM lifecycle cover integration boundaries. |

Invariant campaigns use 256 sequences each, with 80 calls for staking, 96 for each gauge, and 128 for vesting/token. Inline configuration makes unexpected handler reverts fail the campaign. Target selectors restrict random calls to the handlers' intended actions. Unit and fuzz tests exercise invalid inputs separately instead of filtering them away.

All external services are local mocks at the specified addresses. USDG amounts use six-decimal units; BASK and WETH use eighteen-decimal units. There are no forks, RPC calls, environment reads, FFI, added dependencies, or changes to production contracts/configuration. Deliberately hostile ITEM/LP mocks test rollback and isolation; normal integration uses the actual `LaunchToken`.

The tests preserve the specified economics: immediate exits are allowed, a lone LP staker earns alone, reward deposits arriving during a stream wait, and claims under issuer burns are first come, first served. Integer dust is bounded rather than incorrectly required to be zero for arbitrary stake sizes. Selector/opcode checks are regression checks for the stated interface restrictions, not a proof about every possible future entry point.
