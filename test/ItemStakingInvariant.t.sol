// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ItemStaking} from "src/ItemStaking.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {HostileToken} from "./mocks/HostileToken.sol";

/// @dev All money entering/leaving the staking contract is recorded independently.
/// Deliberately short rewards, paused staking, queued donations, and hostile reads can
/// coexist. Expected failed claims are checked for atomicity instead of discarded.
contract ItemStakingSequenceHandler is Test {
    uint256 public constant INITIAL_PRINCIPAL = 3e26;
    uint256 internal constant D = 7 days;

    ItemStaking public immutable staking;
    LaunchToken public immutable item;
    address[3] public actors;
    address[3] public tokens;
    mapping(address => uint256) public principalIn;
    mapping(address => uint256) public principalOut;
    mapping(address => uint256) public rewardReceived;
    mapping(address => uint256) public rewardBurned;
    mapping(address => uint256) public rewardPaid;
    mapping(address => uint256) public rewardStreamed;
    uint256 public successfulClaims;
    uint256 public failedClaims;
    uint256 public stakeCalls;
    uint256 public unstakeCalls;

    struct ClaimSnapshot {
        uint256 accrued;
        uint256 wallet;
        uint256 available;
        bytes32 rewardState;
        HostileToken.BalanceMode mode;
    }

    constructor(ItemStaking staking_, LaunchToken item_, address[3] memory actors_) {
        staking = staking_;
        item = item_;
        actors = actors_;
        tokens = [staking_.BASK(), staking_.USDG(), staking_.WETH()];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            item.approve(address(staking), type(uint256).max);
        }
    }

    function stake(uint256 actorSeed, uint256 amountSeed) public {
        address user = actors[actorSeed % actors.length];
        uint256 available = item.balanceOf(user);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.recordLogs();
        vm.prank(user);
        staking.stake(amount);
        _recordStreams();
        principalIn[user] += amount;
        ++stakeCalls;
    }

    function unstake(uint256 actorSeed, uint256 amountSeed) public {
        address user = actors[actorSeed % actors.length];
        uint256 principal = principalIn[user] - principalOut[user];
        if (principal == 0) return;
        // Frequently empty a position to exercise idle periods and retained carry.
        uint256 amount = amountSeed % 4 == 0 ? principal : bound(amountSeed, 1, principal);
        vm.recordLogs();
        vm.prank(user);
        staking.unstake(amount);
        _recordStreams();
        principalOut[user] += amount;
        ++unstakeCalls;
    }

    function donate(uint256 tokenSeed, uint256 amountSeed) public {
        address token = tokens[tokenSeed % tokens.length];
        uint256 amount = bound(amountSeed, 1, 1e27);
        HostileToken(token).mint(address(staking), amount);
        rewardReceived[token] += amount;
    }

    function issuerBurn(uint256 tokenSeed, uint256 amountSeed) public {
        address token = tokens[tokenSeed % tokens.length];
        uint256 balance = HostileToken(token).balances(address(staking));
        uint256 amount = bound(amountSeed, 0, balance);
        HostileToken(token).burn(address(staking), amount);
        rewardBurned[token] += amount;
    }

    function elapse(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 14 days));
    }

    function sync(uint256 tokenSeed) public {
        address token = tokens[tokenSeed % tokens.length];
        (,, uint256 oldAmount, uint256 oldSeconds, uint256 oldTimestamp) = staking.rewardInfo(token);
        vm.recordLogs();
        staking.sync(token);
        _recordStreams();
        (,, uint256 newAmount, uint256 newSeconds, uint256 newTimestamp) = staking.rewardInfo(token);
        if (oldAmount > 0 && oldSeconds < D) {
            uint256 elapsed = staking.totalStaked() == 0 ? 0 : vm.getBlockTimestamp() - oldTimestamp;
            if (elapsed < D - oldSeconds) {
                assertEq(newAmount, oldAmount, "an unfinished stream cannot be replaced");
                assertEq(newSeconds, oldSeconds + elapsed, "only time with stake advances a stream");
            }
        }
        assertEq(newTimestamp, vm.getBlockTimestamp(), "sync must advance its wall-clock timestamp even without stake");
    }

    function setHostility(uint256 tokenSeed, uint8 balanceSeed, uint8 transferSeed) public {
        HostileToken token = HostileToken(tokens[tokenSeed % tokens.length]);
        token.setBalanceMode(HostileToken.BalanceMode(balanceSeed % 7));
        // The existing mock's Reenter mode deliberately reports a transfer without moving
        // assets, so use its honest, reverting, and false-returning modes for conservation.
        token.setTransferMode(HostileToken.TransferMode(transferSeed % 3));
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) public {
        address user = actors[actorSeed % actors.length];
        address tokenAddress = tokens[tokenSeed % tokens.length];
        HostileToken token = HostileToken(tokenAddress);
        ClaimSnapshot memory before_ = ClaimSnapshot({
            accrued: staking.earned(user, tokenAddress),
            wallet: token.balances(user),
            available: token.balances(address(staking)),
            rewardState: _rewardState(tokenAddress),
            mode: token.balanceMode()
        });
        vm.recordLogs();
        vm.prank(user);
        (bool ok,) = address(staking).call(abi.encodeCall(ItemStaking.claim, (tokenAddress)));
        assertEq(ok, !_claimShouldFail(token, before_), "a claim can fail only for its balance read or transfer");
        if (!ok) {
            // Foundry may record attempted LOG opcodes from reverted subcalls; no
            // reverted StreamStarted contributes to a successfully accepted stream.
            vm.getRecordedLogs();
            ++failedClaims;
            assertEq(_rewardState(tokenAddress), before_.rewardState, "a failed claim changed stream accounting");
            assertEq(staking.earned(user, tokenAddress), before_.accrued, "a failed claim changed the claimant's debt");
            assertEq(token.balances(user), before_.wallet, "failed transfer moved reward tokens");
            assertEq(token.balances(address(staking)), before_.available);
            return;
        }
        _recordStreams();
        ++successfulClaims;
        uint256 paid = token.balances(user) - before_.wallet;
        uint256 balanceRead = before_.mode == HostileToken.BalanceMode.ReportZero
            ? 0
            : before_.mode == HostileToken.BalanceMode.ReportMax ? type(uint256).max : before_.available;
        uint256 expected = before_.accrued < balanceRead ? before_.accrued : balanceRead;
        assertEq(paid, expected, "partial claims pay exactly min(accrued, read balance)");
        assertEq(staking.earned(user, tokenAddress), before_.accrued - paid, "unpaid debt must survive partial claims");
        rewardPaid[tokenAddress] += paid;
    }

    function _claimShouldFail(HostileToken token, ClaimSnapshot memory before_) internal view returns (bool) {
        HostileToken.BalanceMode mode = before_.mode;
        bool invalidRead = mode == HostileToken.BalanceMode.Revert || mode == HostileToken.BalanceMode.BurnGas
            || mode == HostileToken.BalanceMode.HugeData || mode == HostileToken.BalanceMode.ShortData;
        return invalidRead || token.transferMode() != HostileToken.TransferMode.Normal
            || (mode == HostileToken.BalanceMode.ReportMax && before_.accrued > before_.available);
    }

    function sameTimestampRoundTrip(uint256 actorSeed, uint256 amountSeed) public {
        uint256 actorIndex = actorSeed % actors.length;
        address user = actors[actorIndex];
        uint256 principalBefore = item.balanceOf(user);
        if (principalBefore == 0) return;
        uint256[3] memory debts;
        for (uint256 i; i < tokens.length; ++i) {
            debts[i] = staking.earned(user, tokens[i]);
        }
        uint256 amount = bound(amountSeed, 1, principalBefore);
        vm.recordLogs();
        vm.prank(user);
        staking.stake(amount);
        vm.prank(user);
        staking.unstake(amount);
        _recordStreams();
        principalIn[user] += amount;
        principalOut[user] += amount;
        ++stakeCalls;
        ++unstakeCalls;
        assertEq(item.balanceOf(user), principalBefore, "principal round trip created or lost value");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(staking.earned(user, tokens[i]), debts[i], "zero-time principal changes changed reward debt");
        }
    }

    /// @dev Called only after each invariant sequence, never selected as a random action.
    function exitAllAndSettle() external {
        // First prove principal remains withdrawable in the exact hostile state reached.
        for (uint256 i; i < actors.length; ++i) {
            unstake(i, 0);
        }
        assertEq(staking.totalStaked(), 0);
        assertEq(item.balanceOf(address(staking)), 0);
        for (uint256 t; t < tokens.length; ++t) {
            HostileToken token = HostileToken(tokens[t]);
            token.setBalanceMode(HostileToken.BalanceMode.Normal);
            token.setTransferMode(HostileToken.TransferMode.Normal);
            (uint256 accounted,,,,) = staking.rewardInfo(tokens[t]);
            uint256 available = token.balances(address(staking));
            if (available < accounted) {
                uint256 restored = accounted - available;
                token.mint(address(staking), restored);
                rewardReceived[tokens[t]] += restored;
            }
            for (uint256 u; u < actors.length; ++u) {
                claim(u, t);
                assertEq(
                    staking.earned(actors[u], tokens[t]),
                    0,
                    "restoring burned assets must make all existing debts claimable"
                );
            }
        }
    }

    function _rewardState(address token) internal view returns (bytes32) {
        (uint256 a, uint256 i, uint256 f, uint256 s, uint256 t) = staking.rewardInfo(token);
        return keccak256(abi.encode(a, i, f, s, t));
    }

    function _recordStreams() internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 signature = keccak256("StreamStarted(address,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(staking) && entries[i].topics.length == 2
                    && entries[i].topics[0] == signature
            ) {
                address token = address(uint160(uint256(entries[i].topics[1])));
                rewardStreamed[token] += abi.decode(entries[i].data, (uint256));
            }
        }
    }
}

contract ItemStakingInvariantTest is StdInvariant, Test {
    LaunchToken internal item;
    ItemStaking internal staking;
    ItemStakingSequenceHandler internal handler;
    address[3] internal actors;
    address[3] internal tokens;

    function setUp() public {
        vm.warp(1_800_000_000);
        item = new LaunchToken();
        staking = new ItemStaking(address(item));
        actors = [
            makeAddr("staking-invariant-alice"), makeAddr("staking-invariant-bob"), makeAddr("staking-invariant-carol")
        ];
        tokens = [staking.BASK(), staking.USDG(), staking.WETH()];
        bytes memory code = address(new HostileToken()).code;
        for (uint256 i; i < tokens.length; ++i) {
            vm.etch(tokens[i], code);
            item.transfer(actors[i], 3e26);
        }
        handler = new ItemStakingSequenceHandler(staking, item, actors);
        // Seed real obligations so sequences exercise claims, burns, and full exits immediately.
        handler.stake(0, 1);
        handler.stake(1, 17);
        handler.stake(2, 1e27);
        for (uint256 i; i < tokens.length; ++i) {
            handler.donate(i, i == 1 ? 7_000_003 : 7e18 + 1);
            handler.sync(i);
        }
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.issuerBurn.selector;
        selectors[4] = handler.elapse.selector;
        selectors[5] = handler.sync.selector;
        selectors[6] = handler.setHostility.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.sameTimestampRoundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_principalAndRewardConservationThroughHostileSequences() public view {
        uint256 principalSum;
        for (uint256 i; i < actors.length; ++i) {
            address user = actors[i];
            uint256 principal = handler.principalIn(user) - handler.principalOut(user);
            assertEq(staking.staked(user), principal, "one user's calls changed another user's principal");
            assertEq(
                item.balanceOf(user) + principal, handler.INITIAL_PRINCIPAL(), "user principal was created or lost"
            );
            principalSum += principal;
        }
        assertEq(staking.totalStaked(), principalSum);
        assertEq(item.balanceOf(address(staking)), principalSum, "custodied ITEM must exactly back every stake");
        assertEq(item.totalSupply(), 1e27);
        for (uint256 t; t < tokens.length; ++t) {
            address token = tokens[t];
            uint256 paid = handler.rewardPaid(token);
            uint256 burned = handler.rewardBurned(token);
            uint256 received = handler.rewardReceived(token);
            uint256 balance = HostileToken(token).balances(address(staking));
            assertEq(balance + paid + burned, received, "reward inflows must equal paid, burned, and held tokens");
            (uint256 accounted,, uint256 streamAmount, uint256 seconds_, uint256 timestamp) = staking.rewardInfo(token);
            assertEq(
                accounted + paid,
                handler.rewardStreamed(token),
                "accounted must equal all started streams minus all payments"
            );
            assertLe(accounted + paid, received, "recognition cannot invent reward funding");
            assertLe(seconds_, 7 days);
            assertLe(streamAmount, 1e30);
            assertLe(timestamp, vm.getBlockTimestamp());
            uint256 debt;
            uint256 wallets;
            for (uint256 u; u < actors.length; ++u) {
                debt += staking.earned(actors[u], token);
                wallets += HostileToken(token).balances(actors[u]);
            }
            assertLe(debt, accounted, "aggregate user debt cannot exceed unpaid recognized rewards");
            assertEq(wallets, paid, "recorded payout must reach an actor");
        }
    }

    function afterInvariant() public {
        handler.exitAllAndSettle();
        invariant_principalAndRewardConservationThroughHostileSequences();
        for (uint256 i; i < actors.length; ++i) {
            assertEq(item.balanceOf(actors[i]), handler.INITIAL_PRINCIPAL());
        }
    }
}
