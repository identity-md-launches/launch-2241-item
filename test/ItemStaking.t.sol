// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ItemStaking} from "../src/ItemStaking.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ReentrancyGuard} from "../src/ReentrancyGuard.sol";
import {TokenTransfer} from "../src/libraries/TokenTransfer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HostileToken} from "./mocks/HostileToken.sol";

contract ItemStakingTest is Test {
    address constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint256 constant D = 7 days;

    LaunchToken item;
    ItemStaking staking;
    MockERC20 bask = MockERC20(BASK);
    MockERC20 usdg = MockERC20(USDG);
    MockERC20 weth = MockERC20(WETH);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_700_000_000);
        item = new LaunchToken();
        staking = new ItemStaking(address(item));
        bytes memory code = address(new MockERC20()).code;
        vm.etch(BASK, code);
        vm.etch(USDG, code);
        vm.etch(WETH, code);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            item.transfer(users[i], 333_333_333e18);
            vm.prank(users[i]);
            item.approve(address(staking), type(uint256).max);
        }
    }

    function _stake(address u, uint256 amount) internal {
        vm.prank(u);
        staking.stake(amount);
    }

    function _unstake(address u, uint256 amount) internal {
        vm.prank(u);
        staking.unstake(amount);
    }

    function _claim(address u, address token) internal returns (uint256 paid) {
        uint256 before = MockERC20(token).balanceOf(u);
        vm.prank(u);
        staking.claim(token);
        paid = MockERC20(token).balanceOf(u) - before;
    }

    function _accounted(address token) internal view returns (uint256 a) {
        (a,,,,) = staking.rewardInfo(token);
    }

    function _stream(address token) internal view returns (uint256 amount, uint256 secs) {
        (,, amount, secs,) = staking.rewardInfo(token);
    }

    // ─────────────────────────────── views & reverts ──────────────────────────

    function test_views() public view {
        assertEq(staking.item(), address(item));
        assertEq(staking.BASK(), BASK);
        assertEq(staking.USDG(), USDG);
        assertEq(staking.WETH(), WETH);
        assertEq(staking.STREAM_DURATION(), 7 days);
        assertEq(staking.MAX_FRESH(), 1e30);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.staked(alice), 0);
        assertEq(staking.earned(alice, BASK), 0);
    }

    function test_zeroAndInsufficientRevert() public {
        vm.prank(alice);
        vm.expectRevert(ItemStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.prank(alice);
        vm.expectRevert(ItemStaking.ZeroAmount.selector);
        staking.unstake(0);
        _stake(alice, 10);
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InsufficientStake.selector);
        staking.unstake(11);
        vm.prank(bob);
        vm.expectRevert(ItemStaking.InsufficientStake.selector);
        staking.unstake(1);
    }

    function test_unknownTokenReverts() public {
        vm.expectRevert(ItemStaking.InvalidToken.selector);
        staking.claim(address(item));
        vm.expectRevert(ItemStaking.InvalidToken.selector);
        staking.sync(address(0xBEEF));
    }

    function test_stakeWithoutApprovalReverts() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        staking.stake(1);
    }

    // ───────────────────────────── stake / unstake ───────────────────────────

    function test_stakeAndUnstakeMoveItemOnly() public {
        bask.mint(address(staking), 70e18);
        vm.expectEmit(true, false, false, true);
        emit ItemStaking.Staked(alice, 100e18);
        _stake(alice, 100e18);
        assertEq(staking.staked(alice), 100e18);
        assertEq(staking.totalStaked(), 100e18);
        assertEq(item.balanceOf(address(staking)), 100e18);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true);
        emit ItemStaking.Unstaked(alice, 40e18);
        _unstake(alice, 40e18);
        assertEq(staking.staked(alice), 60e18);
        assertEq(item.balanceOf(alice), 333_333_333e18 - 60e18);
        assertEq(bask.balanceOf(alice), 0);
        assertEq(bask.balanceOf(address(staking)), 70e18);
        assertEq(staking.earned(alice, BASK), 10e18);
    }

    // ───────────────────────────────── streams ───────────────────────────────

    function test_streamReleasesLinearlyOverSevenStakedDays() public {
        _stake(alice, 100e18);
        bask.mint(address(staking), 7e18);
        vm.expectEmit(true, false, false, true);
        emit ItemStaking.StreamStarted(BASK, 7e18);
        vm.expectEmit(true, false, false, true);
        emit ItemStaking.Synced(BASK, true, 7e18);
        staking.sync(BASK);
        assertEq(_accounted(BASK), 7e18);
        (uint256 amount, uint256 secs) = _stream(BASK);
        assertEq(amount, 7e18);
        assertEq(secs, 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice, BASK), 1e18);
        vm.warp(block.timestamp + 2 days + 12 hours);
        assertEq(staking.earned(alice, BASK), 3.5e18);
        vm.warp(block.timestamp + 30 days);
        assertEq(staking.earned(alice, BASK), 7e18);
        vm.expectEmit(true, true, false, true);
        emit ItemStaking.Claimed(alice, BASK, 7e18);
        assertEq(_claim(alice, BASK), 7e18);
        assertEq(staking.earned(alice, BASK), 0);
        assertEq(_accounted(BASK), 0);
    }

    function test_directTransferIsPickedUpByStakeWithoutSync() public {
        _stake(alice, 1e18);
        vm.prank(alice);
        bask.mint(address(staking), 14e18);
        _stake(bob, 1e18);
        (uint256 amount,) = _stream(BASK);
        assertEq(amount, 14e18);
        vm.warp(block.timestamp + 7 days);
        assertEq(staking.earned(alice, BASK), 7e18);
        assertEq(staking.earned(bob, BASK), 7e18);
    }

    function test_noStreamTimePassesWhileNothingStaked() public {
        usdg.mint(address(staking), 7_000_000);
        staking.sync(USDG);
        (uint256 amount, uint256 secs) = _stream(USDG);
        assertEq(amount, 7_000_000);
        assertEq(secs, 0);
        vm.warp(block.timestamp + 3 days);
        staking.sync(USDG);
        (, secs) = _stream(USDG);
        assertEq(secs, 0);
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice, USDG), 1_000_000);
        _unstake(alice, 1);
        vm.warp(block.timestamp + 10 days);
        assertEq(staking.earned(alice, USDG), 1_000_000);
        (, secs) = _stream(USDG);
        assertEq(secs, 1 days);
        _stake(bob, 1);
        vm.warp(block.timestamp + 6 days);
        assertEq(staking.earned(bob, USDG), 6_000_000);
        assertEq(_claim(alice, USDG) + _claim(bob, USDG), 7_000_000);
    }

    function test_laterAmountsWaitUntilTheStreamFinishes() public {
        _stake(alice, 1e18);
        weth.mint(address(staking), 7e18);
        staking.sync(WETH);
        vm.warp(block.timestamp + 2 days);
        weth.mint(address(staking), 100e18);
        staking.sync(WETH);
        (uint256 amount, uint256 secs) = _stream(WETH);
        assertEq(amount, 7e18, "live stream must not change");
        assertEq(secs, 2 days);
        assertEq(_accounted(WETH), 7e18);
        vm.warp(block.timestamp + 5 days - 1);
        staking.sync(WETH);
        (amount,) = _stream(WETH);
        assertEq(amount, 7e18, "one second before the end it is still unfinished");
        vm.warp(block.timestamp + 1);
        weth.mint(address(staking), 5e18);
        staking.sync(WETH);
        (amount, secs) = _stream(WETH);
        assertEq(amount, 105e18, "everything waiting starts as one stream");
        assertEq(secs, 0);
        assertEq(_accounted(WETH), 112e18);
        vm.warp(block.timestamp + 7 days);
        assertEq(staking.earned(alice, WETH), 112e18);
        assertEq(_claim(alice, WETH), 112e18);
    }

    function test_streamIsNeverBackdated() public {
        _stake(alice, 1e18);
        vm.warp(block.timestamp + 30 days);
        bask.mint(address(staking), 7e18);
        vm.warp(block.timestamp + 30 days);
        staking.sync(BASK);
        assertEq(staking.earned(alice, BASK), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice, BASK), 1e18);
    }

    function test_freshAboveCapStartsNoStream() public {
        _stake(alice, 1e18);
        bask.mint(address(staking), 1e30 + 1);
        staking.sync(BASK);
        (uint256 amount,) = _stream(BASK);
        assertEq(amount, 0);
        assertEq(_accounted(BASK), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(staking.earned(alice, BASK), 0);
        // exactly the cap is accepted
        usdg.mint(address(staking), 1e30);
        staking.sync(USDG);
        (amount,) = _stream(USDG);
        assertEq(amount, 1e30);
    }

    function test_partialIssuerBurnClaimsAreFirstComeFirstServed() public {
        _stake(alice, 5e18);
        _stake(bob, 5e18);
        usdg.mint(address(staking), 10_000_000);
        staking.sync(USDG);
        vm.warp(block.timestamp + 7 days);
        usdg.burn(address(staking), 6_000_000);
        staking.sync(USDG);
        (uint256 amount,) = _stream(USDG);
        assertEq(amount, 10_000_000);
        assertEq(_accounted(USDG), 10_000_000, "balance below accounted starts nothing");
        assertEq(staking.earned(alice, USDG), 5_000_000);
        assertEq(_claim(alice, USDG), 4_000_000, "paid min(accrued, balance)");
        assertEq(staking.earned(alice, USDG), 1_000_000, "the rest stays owed");
        assertEq(_accounted(USDG), 6_000_000);
        assertEq(_claim(bob, USDG), 0);
        assertEq(staking.earned(bob, USDG), 5_000_000);
        // unstake is never blocked by the shortfall
        _unstake(bob, 5e18);
        // the issuer makes the contract whole: balance equals accounted, so no new stream, and claims resume
        usdg.mint(address(staking), 6_000_000);
        staking.sync(USDG);
        (amount,) = _stream(USDG);
        assertEq(amount, 10_000_000);
        assertEq(_claim(bob, USDG), 5_000_000);
        assertEq(_claim(alice, USDG), 1_000_000);
        assertEq(_accounted(USDG), 0);
        assertEq(usdg.balanceOf(address(staking)), 0);
    }

    function test_paymentsReduceAccountedSoNewDepositsStream() public {
        _stake(alice, 1e18);
        bask.mint(address(staking), 7e18);
        staking.sync(BASK);
        vm.warp(block.timestamp + 7 days);
        _claim(alice, BASK);
        assertEq(_accounted(BASK), 0);
        bask.mint(address(staking), 14e18);
        staking.sync(BASK);
        (uint256 amount,) = _stream(BASK);
        assertEq(amount, 14e18);
        assertEq(_accounted(BASK), 14e18);
    }

    function test_claimDoesNotTouchOtherTokens() public {
        _stake(alice, 1e18);
        bask.mint(address(staking), 7e18);
        usdg.mint(address(staking), 7_000_000);
        _stake(alice, 1);
        vm.warp(block.timestamp + 7 days);
        uint256 paid = _claim(alice, BASK);
        assertLe(paid, 7e18);
        assertApproxEqAbs(paid, 7e18, 1);
        assertEq(usdg.balanceOf(alice), 0);
        assertApproxEqAbs(staking.earned(alice, USDG), 7_000_000, 1);
    }

    // ───────────────────────────── hostile tokens ────────────────────────────

    function _hostileWeth() internal returns (HostileToken h) {
        vm.etch(WETH, address(new HostileToken()).code);
        h = HostileToken(WETH);
    }

    function _assertStakeUnstakeAndOtherTokensWork() internal {
        bask.mint(address(staking), 7e18);
        _stake(alice, 1e18);
        _stake(bob, 3e18);
        uint256 sa = staking.staked(alice);
        uint256 sb = staking.staked(bob);
        vm.warp(block.timestamp + 7 days);
        _unstake(bob, 3e18);
        _unstake(alice, 5e17);
        uint256 expectedA = 7e18 * sa / (sa + sb);
        uint256 expectedB = 7e18 * sb / (sa + sb);
        assertApproxEqAbs(staking.earned(alice, BASK), expectedA, 1);
        assertApproxEqAbs(_claim(alice, BASK), expectedA, 1);
        assertApproxEqAbs(_claim(bob, BASK), expectedB, 1);
        staking.sync(WETH);
    }

    function test_hostileRevertingBalance() public {
        HostileToken h = _hostileWeth();
        h.setBalanceMode(HostileToken.BalanceMode.Revert);
        _assertStakeUnstakeAndOtherTokensWork();
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(WETH);
    }

    function test_hostileGasBurningBalance() public {
        HostileToken h = _hostileWeth();
        h.setBalanceMode(HostileToken.BalanceMode.BurnGas);
        uint256 gasBefore = gasleft();
        _stake(alice, 1e18);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 450_000, "the balance read is capped at 50,000 gas");
        _assertStakeUnstakeAndOtherTokensWork();
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(WETH);
    }

    function test_hostileHugeReturnData() public {
        HostileToken h = _hostileWeth();
        h.setBalanceMode(HostileToken.BalanceMode.HugeData);
        _assertStakeUnstakeAndOtherTokensWork();
        (bool ok, uint256 streamed,,,) = _info(WETH);
        assertTrue(ok);
        assertEq(streamed, 0);
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(WETH);
    }

    function test_hostileShortReturnData() public {
        HostileToken h = _hostileWeth();
        h.setBalanceMode(HostileToken.BalanceMode.ShortData);
        _assertStakeUnstakeAndOtherTokensWork();
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(WETH);
    }

    function test_hostileReportsZero() public {
        HostileToken h = _hostileWeth();
        h.mint(address(staking), 7e18);
        _stake(alice, 1e18);
        assertEq(_accounted(WETH), 7e18);
        vm.warp(block.timestamp + 7 days);
        h.setBalanceMode(HostileToken.BalanceMode.ReportZero);
        _assertStakeUnstakeAndOtherTokensWork();
        assertEq(staking.earned(alice, WETH), 7e18);
        // a valid read of 0 pays min(owed, 0) = 0 and keeps the rest owed
        vm.prank(alice);
        staking.claim(WETH);
        assertEq(staking.earned(alice, WETH), 7e18);
        assertEq(_accounted(WETH), 7e18);
    }

    function test_hostileReportsMax() public {
        HostileToken h = _hostileWeth();
        h.setBalanceMode(HostileToken.BalanceMode.ReportMax);
        _assertStakeUnstakeAndOtherTokensWork();
        (uint256 amount,) = _stream(WETH);
        assertEq(amount, 0, "fresh above 1e30 starts no stream");
        assertEq(staking.earned(alice, WETH), 0);
    }

    function test_hostileTransferRevertsOrReturnsFalseOnlyBlocksItsOwnClaim() public {
        HostileToken h = _hostileWeth();
        h.mint(address(staking), 7e18);
        _stake(alice, 1e18);
        vm.warp(block.timestamp + 7 days);
        h.setTransferMode(HostileToken.TransferMode.Revert);
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        staking.claim(WETH);
        h.setTransferMode(HostileToken.TransferMode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        staking.claim(WETH);
        assertEq(staking.earned(alice, WETH), 7e18);
        assertEq(_accounted(WETH), 7e18);
        _assertStakeUnstakeAndOtherTokensWork();
        h.setTransferMode(HostileToken.TransferMode.Normal);
        vm.prank(alice);
        staking.claim(WETH);
        assertEq(h.balances(alice), 7e18);
    }

    function test_reentrancyThroughRewardTokenIsBlocked() public {
        HostileToken h = _hostileWeth();
        h.mint(address(staking), 7e18);
        _stake(alice, 1e18);
        vm.warp(block.timestamp + 7 days);
        h.setTransferMode(HostileToken.TransferMode.Reenter);
        bytes[4] memory calls = [
            abi.encodeCall(ItemStaking.claim, (WETH)),
            abi.encodeCall(ItemStaking.unstake, (1e18)),
            abi.encodeCall(ItemStaking.stake, (1)),
            abi.encodeCall(ItemStaking.sync, (BASK))
        ];
        for (uint256 i; i < calls.length; ++i) {
            h.setReenter(address(staking), calls[i]);
            vm.prank(alice);
            staking.claim(WETH);
            assertEq(h.lastReenterError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        }
        assertEq(staking.staked(alice), 1e18);
    }

    function _info(address token) internal view returns (bool, uint256, uint256, uint256, uint256) {
        (uint256 a, uint256 i, uint256 s, uint256 ss, uint256 l) = staking.rewardInfo(token);
        return (true, s, a, i, ss + l);
    }

    // ──────────────────────────── rounding and dust ──────────────────────────

    function test_oddSizedStakersPaidAtMostStreamedAndLastClaimerInFull() public {
        uint256 t0 = block.timestamp;
        _stake(alice, 1);
        usdg.mint(address(staking), 9_999_999);
        _stake(bob, 7_777_777_777_777_777_777);
        vm.warp(t0 + 1 days + 7);
        _stake(carol, 299_999_999_999_999_999_999_999_999);
        vm.warp(t0 + 3 days + 1234);
        _unstake(bob, 7_777_777_777_777_777_777);
        vm.warp(t0 + 7 days + 1);
        uint256 streamed = 9_999_999;
        uint256 paid = _claim(alice, USDG) + _claim(bob, USDG) + _claim(carol, USDG);
        assertLe(paid, streamed);
        assertGe(paid + 3, streamed);
        // new deposit, only carol staked: she gets it all
        usdg.mint(address(staking), 1_000_001);
        staking.sync(USDG);
        vm.warp(t0 + 20 days);
        assertEq(_claim(carol, USDG), 1_000_001);
        assertEq(usdg.balanceOf(address(staking)), streamed - paid);
    }

    function test_roundingOneWeiAndOneE27() public {
        vm.prank(alice);
        item.transfer(bob, 333_333_333e18 - 1);
        vm.prank(carol);
        item.transfer(bob, 333_333_333e18);
        _stake(alice, 1);
        _stake(bob, 999_999_999e18 - 1);
        weth.mint(address(staking), 1e27);
        staking.sync(WETH);
        vm.warp(block.timestamp + 7 days);
        uint256 a = _claim(alice, WETH);
        uint256 b = _claim(bob, WETH);
        assertEq(a, 1);
        assertLe(a + b, 1e27);
        assertGe(a + b, 1e27 - 2);
        assertEq(staking.earned(alice, WETH), 0);
    }

    function test_loneOneWeiStakerGetsEverything() public {
        _stake(alice, 1);
        usdg.mint(address(staking), 123_456_789);
        staking.sync(USDG);
        vm.warp(block.timestamp + 7 days);
        assertEq(staking.earned(alice, USDG), 123_456_789);
        assertEq(_claim(alice, USDG), 123_456_789);
    }

    function test_carryKeepsRemainderAcrossClaims() public {
        _stake(alice, 3);
        _stake(bob, 7);
        usdg.mint(address(staking), 1_000_003);
        staking.sync(USDG);
        uint256 t0 = block.timestamp;
        uint256 paid;
        for (uint256 i = 1; i <= 14; ++i) {
            vm.warp(t0 + i * 12 hours + i);
            paid += _claim(alice, USDG) + _claim(bob, USDG);
        }
        assertLe(paid, 1_000_003);
        assertGe(paid + 2, 1_000_003);
    }

    function test_fuzz_paidNeverExceedsStreamed(uint256[3] memory stakes, uint64[3] memory rewards, uint32 wait)
        public
    {
        address[3] memory users = [alice, bob, carol];
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            _stake(users[i], bound(stakes[i], 1, 1e26));
            uint256 r = bound(rewards[i], 0, 1e18);
            bask.mint(address(staking), r);
            total += r;
            staking.sync(BASK);
            vm.warp(block.timestamp + bound(wait, 0, 10 days));
        }
        vm.warp(block.timestamp + 7 days);
        staking.sync(BASK);
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            paid += _claim(users[i], BASK);
        }
        assertLe(paid, total);
        assertEq(bask.balanceOf(address(staking)), total - paid);
        assertLe(_accounted(BASK), total - paid);
    }
}
