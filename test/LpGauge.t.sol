// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LpGauge} from "../src/LpGauge.sol";
import {BaskUsdgGauge} from "../src/BaskUsdgGauge.sol";
import {ItemEthGauge} from "../src/ItemEthGauge.sol";
import {ReentrancyGuard} from "../src/ReentrancyGuard.sol";
import {TokenTransfer} from "../src/libraries/TokenTransfer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {ReentrantLp} from "./mocks/ReentrantLp.sol";

/// @dev Shared suite for both gauges; the concrete test contracts below pick the gauge and its expected constants.
abstract contract LpGaugeTestBase is Test {
    uint256 constant T = 4 * 365 days;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;

    MockERC20 item;
    MockERC20 lp;
    MockV2Factory factory;
    LpGauge gauge;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address funder = makeAddr("funder");

    uint256 ALLOCATION;
    address expectedTokenA;
    address expectedTokenB;

    function _deployGauge(address item_) internal virtual returns (LpGauge);

    function setUp() public {
        vm.warp(1_700_000_000);
        item = new MockERC20();
        lp = new MockERC20();
        vm.etch(FACTORY, address(new MockV2Factory()).code);
        factory = MockV2Factory(FACTORY);
        gauge = _deployGauge(address(item));
        ALLOCATION = gauge.ALLOCATION();
        expectedTokenA = gauge.tokenA();
        expectedTokenB = gauge.tokenB();
        item.mint(funder, ALLOCATION * 2);
        vm.prank(funder);
        item.approve(address(gauge), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address u = i == 0 ? alice : i == 1 ? bob : carol;
            lp.mint(u, 1e27);
            vm.prank(u);
            lp.approve(address(gauge), type(uint256).max);
        }
    }

    function _registerPair() internal {
        factory.setPair(expectedTokenA, expectedTokenB, address(lp));
    }

    function _start() internal {
        _registerPair();
        vm.prank(funder);
        gauge.start();
    }

    function _stake(address u, uint256 amount) internal {
        vm.prank(u);
        gauge.stake(amount);
    }

    function _claim(address u) internal returns (uint256 paid) {
        uint256 before = item.balanceOf(u);
        vm.prank(u);
        gauge.claim();
        paid = item.balanceOf(u) - before;
    }

    function _released(uint256 t) internal view returns (uint256) {
        return ALLOCATION * t * (2 * T - t) / (T * T);
    }

    // ───────────────────────── constructor and views ─────────────────────────

    function test_initialViews() public view {
        assertEq(gauge.item(), address(item));
        assertEq(gauge.V2_FACTORY(), FACTORY);
        assertEq(gauge.T(), T);
        assertEq(gauge.pair(), address(0));
        assertFalse(gauge.started());
        assertEq(gauge.stakedSeconds(), 0);
        assertEq(gauge.released(), 0);
        assertEq(gauge.rate(), 0);
        assertEq(gauge.remaining(), ALLOCATION);
        assertEq(gauge.totalStaked(), 0);
        assertEq(gauge.staked(alice), 0);
        assertEq(gauge.earned(alice), 0);
    }

    // ───────────────────────────────── start ─────────────────────────────────

    function test_startRevertsWithoutPair() public {
        vm.prank(funder);
        vm.expectRevert(LpGauge.NoPair.selector);
        gauge.start();
        assertFalse(gauge.started());
    }

    function test_startPullsExactlyAllocationAndStoresPair() public {
        _registerPair();
        uint256 before = item.balanceOf(funder);
        vm.expectEmit(true, false, false, true);
        emit LpGauge.Started(address(lp), ALLOCATION);
        vm.prank(funder);
        gauge.start();
        assertTrue(gauge.started());
        assertEq(gauge.pair(), address(lp));
        assertEq(before - item.balanceOf(funder), ALLOCATION);
        assertEq(item.balanceOf(address(gauge)), ALLOCATION);
    }

    function test_startRevertsWithoutAllowance() public {
        _registerPair();
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        gauge.start();
    }

    function test_startOnlyOnce() public {
        _start();
        vm.prank(funder);
        vm.expectRevert(LpGauge.AlreadyStarted.selector);
        gauge.start();
    }

    function test_stakeRevertsBeforeStart() public {
        vm.prank(alice);
        vm.expectRevert(LpGauge.NotStarted.selector);
        gauge.stake(1e18);
    }

    function test_zeroAmountsRevert() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(LpGauge.ZeroAmount.selector);
        gauge.stake(0);
        vm.prank(alice);
        vm.expectRevert(LpGauge.ZeroAmount.selector);
        gauge.withdraw(0);
    }

    function test_withdrawMoreThanStakedReverts() public {
        _start();
        _stake(alice, 10);
        vm.prank(alice);
        vm.expectRevert(LpGauge.InsufficientStake.selector);
        gauge.withdraw(11);
        vm.prank(bob);
        vm.expectRevert(LpGauge.InsufficientStake.selector);
        gauge.withdraw(1);
    }

    // ───────────────────────────── release curve ─────────────────────────────

    function test_releasedFollowsCurveForLoneStaker() public {
        _start();
        _stake(alice, 5e18);
        uint256[6] memory ts = [uint256(1), 1 days, 100 days, 365 days, 730 days, T - 1];
        uint256 t0 = block.timestamp;
        for (uint256 i; i < ts.length; ++i) {
            vm.warp(t0 + ts[i]);
            assertEq(gauge.stakedSeconds(), ts[i]);
            assertEq(gauge.released(), _released(ts[i]));
            assertEq(gauge.remaining(), ALLOCATION - _released(ts[i]));
            assertEq(gauge.rate(), 2 * ALLOCATION * (T - ts[i]) / (T * T));
            assertLe(gauge.earned(alice), _released(ts[i]));
            assertApproxEqAbs(gauge.earned(alice), _released(ts[i]), 1);
        }
    }

    function test_releaseCapsAtT() public {
        _start();
        _stake(alice, 1e18);
        vm.warp(block.timestamp + T + 1000 days);
        assertEq(gauge.stakedSeconds(), T);
        assertEq(gauge.released(), ALLOCATION);
        assertEq(gauge.remaining(), 0);
        assertEq(gauge.rate(), 0);
        assertEq(_claim(alice), ALLOCATION);
        vm.warp(block.timestamp + 365 days);
        assertEq(gauge.earned(alice), 0);
        assertEq(_claim(alice), 0);
        assertEq(item.balanceOf(address(gauge)), 0);
    }

    function test_rateIsZeroWhileNothingStaked() public {
        _start();
        assertEq(gauge.rate(), 0);
        _stake(alice, 1);
        assertGt(gauge.rate(), 0);
        vm.prank(alice);
        gauge.withdraw(1);
        assertEq(gauge.rate(), 0);
    }

    function test_timeWithoutStakersDoesNotCount() public {
        _start();
        vm.warp(block.timestamp + 100 days);
        assertEq(gauge.stakedSeconds(), 0);
        assertEq(gauge.released(), 0);
        _stake(alice, 1e18);
        assertEq(gauge.stakedSeconds(), 0);
        vm.warp(block.timestamp + 10 days);
        assertEq(gauge.stakedSeconds(), 10 days);
        vm.prank(alice);
        gauge.withdraw(1e18);
        vm.warp(block.timestamp + 50 days);
        assertEq(gauge.stakedSeconds(), 10 days);
        assertEq(gauge.released(), _released(10 days));
        _stake(bob, 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(gauge.stakedSeconds(), 11 days);
        assertEq(gauge.earned(bob), _released(11 days) - _released(10 days));
        assertEq(gauge.earned(alice), _released(10 days));
    }

    function test_extraItemSentIsIgnored() public {
        _start();
        item.mint(address(gauge), 1_000e18);
        _stake(alice, 1e18);
        vm.warp(block.timestamp + T);
        assertEq(gauge.released(), ALLOCATION);
        assertEq(_claim(alice), ALLOCATION);
        assertEq(item.balanceOf(address(gauge)), 1_000e18);
    }

    // ─────────────────────────── stake, withdraw, claim ───────────────────────

    function test_stakeMovesLpAndEmits() public {
        _start();
        vm.expectEmit(true, false, false, true);
        emit LpGauge.Staked(alice, 3e18);
        _stake(alice, 3e18);
        assertEq(gauge.staked(alice), 3e18);
        assertEq(gauge.totalStaked(), 3e18);
        assertEq(lp.balanceOf(address(gauge)), 3e18);
        assertEq(lp.balanceOf(alice), 1e27 - 3e18);
    }

    function test_withdrawMovesOnlyLpAndKeepsRewardsOwed() public {
        _start();
        _stake(alice, 3e18);
        vm.warp(block.timestamp + 30 days);
        uint256 owed = gauge.earned(alice);
        assertLe(owed, _released(30 days));
        assertApproxEqAbs(owed, _released(30 days), 1);
        vm.expectEmit(true, false, false, true);
        emit LpGauge.Withdrawn(alice, 3e18);
        vm.prank(alice);
        gauge.withdraw(3e18);
        assertEq(lp.balanceOf(alice), 1e27);
        assertEq(item.balanceOf(alice), 0);
        assertEq(item.balanceOf(address(gauge)), ALLOCATION);
        assertEq(gauge.staked(alice), 0);
        assertEq(gauge.earned(alice), owed);
        vm.warp(block.timestamp + 30 days);
        assertEq(gauge.earned(alice), owed);
        assertEq(_claim(alice), owed);
        assertEq(gauge.earned(alice), 0);
    }

    function test_withdrawWorksEvenWhenItemIsGone() public {
        _start();
        _stake(alice, 3e18);
        vm.warp(block.timestamp + 30 days);
        item.burn(address(gauge), ALLOCATION);
        vm.prank(alice);
        gauge.withdraw(3e18);
        assertEq(lp.balanceOf(alice), 1e27);
    }

    function test_failedClaimRevertsWhole() public {
        _start();
        _stake(alice, 3e18);
        vm.warp(block.timestamp + 30 days);
        uint256 owed = gauge.earned(alice);
        item.burn(address(gauge), ALLOCATION);
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        gauge.claim();
        assertEq(gauge.earned(alice), owed);
        item.mint(address(gauge), ALLOCATION);
        assertEq(_claim(alice), owed);
    }

    function test_claimEmitsAndResets() public {
        _start();
        _stake(alice, 1e18);
        vm.warp(block.timestamp + 1 days);
        uint256 expected = _released(1 days);
        vm.expectEmit(true, false, false, true);
        emit LpGauge.Claimed(alice, expected);
        assertEq(_claim(alice), expected);
        assertEq(gauge.earned(alice), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(gauge.earned(alice), _released(2 days) - _released(1 days));
    }

    function test_partialWithdrawKeepsEarningOnRemainder() public {
        _start();
        _stake(alice, 4e18);
        _stake(bob, 4e18);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        gauge.withdraw(2e18);
        vm.warp(block.timestamp + 10 days);
        uint256 r1 = _released(10 days);
        uint256 r2 = _released(20 days) - r1;
        assertApproxEqAbs(gauge.earned(alice), r1 / 2 + r2 / 3, 2);
        assertApproxEqAbs(gauge.earned(bob), r1 / 2 + r2 * 2 / 3, 2);
    }

    function test_noCallTouchesAnotherStake() public {
        _start();
        _stake(alice, 5e18);
        _stake(bob, 7e18);
        vm.prank(bob);
        gauge.withdraw(7e18);
        assertEq(gauge.staked(alice), 5e18);
        vm.prank(bob);
        vm.expectRevert(LpGauge.InsufficientStake.selector);
        gauge.withdraw(1);
    }

    // ────────────────────────── odd sizes, rounding, dust ─────────────────────

    function test_oddSizedStakersPaidAtMostReleasedAndLastClaimerInFull() public {
        _start();
        uint256 t0 = block.timestamp;
        _stake(alice, 1);
        vm.warp(t0 + 3 days + 17);
        _stake(bob, 7_777_777_777_777_777_777);
        vm.warp(t0 + 11 days + 1234);
        _stake(carol, 333_333_333_333_333_333_333_333_333);
        vm.warp(t0 + 40 days + 1);
        vm.prank(bob);
        gauge.withdraw(7_777_777_777_777_777_777);
        vm.warp(t0 + 100 days + 59);
        uint256 released = gauge.released();
        uint256 paid = _claim(alice) + _claim(bob) + _claim(carol);
        assertLe(paid, released);
        assertApproxEqAbs(paid, released, 3);
        // Everyone has withdrawn or claimed; the last claimer (carol, still staked) keeps earning alone.
        vm.prank(alice);
        gauge.withdraw(1);
        vm.warp(t0 + 200 days);
        uint256 last = _claim(carol);
        assertEq(last, gauge.released() - released);
        assertEq(item.balanceOf(address(gauge)), ALLOCATION - paid - last);
    }

    function test_roundingOneWeiAndOneE27() public {
        _start();
        _stake(alice, 1);
        _stake(bob, 1e27);
        vm.warp(block.timestamp + 365 days);
        uint256 released = gauge.released();
        uint256 a = _claim(alice);
        uint256 b = _claim(bob);
        assertLe(a + b, released);
        assertGe(a + b, released - 2);
        assertApproxEqAbs(a, released / (1e27 + 1), 1);
    }

    function test_loneOneWeiStakerEarnsEverything() public {
        _start();
        _stake(alice, 1);
        vm.warp(block.timestamp + 777 days);
        assertEq(gauge.earned(alice), gauge.released());
        assertEq(_claim(alice), _released(777 days));
    }

    function test_carryAccumulatesAcrossClaims() public {
        _start();
        _stake(alice, 3);
        _stake(bob, 7);
        uint256 t0 = block.timestamp;
        uint256 paid;
        for (uint256 i = 1; i <= 20; ++i) {
            vm.warp(t0 + i * 1 hours + i);
            paid += _claim(alice) + _claim(bob);
        }
        uint256 released = gauge.released();
        assertLe(paid, released);
        assertGe(paid, released - 2);
    }

    function test_fuzz_paidNeverExceedsReleased(uint256[4] memory amounts, uint32[4] memory waits) public {
        _start();
        address[3] memory users = [alice, bob, carol];
        uint256 t = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            address u = users[i % 3];
            uint256 amount = bound(amounts[i], 1, 1e26);
            _stake(u, amount);
            t += bound(waits[i], 0, 400 days);
            vm.warp(t);
            if (i % 2 == 1) {
                vm.prank(u);
                gauge.withdraw(amount);
            }
        }
        uint256 released = gauge.released();
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            paid += _claim(users[i]);
        }
        assertLe(paid, released);
        assertGe(paid + 3, released);
        assertLe(released, ALLOCATION);
    }

    // ─────────────────────────────── reentrancy ──────────────────────────────

    function test_reentrancyBlocked() public {
        ReentrantLp evil = new ReentrantLp();
        factory.setPair(expectedTokenA, expectedTokenB, address(evil));
        vm.prank(funder);
        gauge.start();
        evil.mint(alice, 10e18);
        vm.prank(alice);
        evil.approve(address(gauge), type(uint256).max);
        _stake(alice, 1e18);

        bytes[3] memory calls = [
            abi.encodeCall(LpGauge.stake, (1e18)),
            abi.encodeCall(LpGauge.withdraw, (1e18)),
            abi.encodeCall(LpGauge.claim, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            evil.arm(address(gauge), calls[i]);
            _stake(alice, 1e18);
            assertEq(evil.lastError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
            evil.arm(address(gauge), calls[i]);
            vm.prank(alice);
            gauge.withdraw(1e18);
            assertEq(evil.lastError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        }
        assertEq(gauge.staked(alice), 1e18);
    }
}

contract BaskUsdgGaugeTest is LpGaugeTestBase {
    function _deployGauge(address item_) internal override returns (LpGauge) {
        return new BaskUsdgGauge(item_);
    }

    function test_constants() public view {
        assertEq(gauge.tokenA(), 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B);
        assertEq(gauge.tokenB(), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
        assertEq(BaskUsdgGauge(address(gauge)).BASK(), gauge.tokenA());
        assertEq(BaskUsdgGauge(address(gauge)).USDG(), gauge.tokenB());
        assertEq(gauge.ALLOCATION(), 490_000_000e18);
    }
}

contract ItemEthGaugeTest is LpGaugeTestBase {
    function _deployGauge(address item_) internal override returns (LpGauge) {
        return new ItemEthGauge(item_);
    }

    function test_constants() public view {
        assertEq(gauge.tokenA(), address(item));
        assertEq(gauge.tokenB(), 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
        assertEq(ItemEthGauge(address(gauge)).WETH(), gauge.tokenB());
        assertEq(gauge.ALLOCATION(), 210_000_000e18);
    }
}
