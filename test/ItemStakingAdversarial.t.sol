// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ItemStaking} from "src/ItemStaking.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ReentrancyGuard} from "src/ReentrancyGuard.sol";
import {TokenTransfer} from "src/libraries/TokenTransfer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HostileToken} from "./mocks/HostileToken.sol";

/// @dev The callback actually moves principal after probing every guarded entry point.
contract StakingCallbackItem is MockERC20 {
    ItemStaking public target;
    bool public failPull;
    bool public failPush;
    uint256 public blockedCallbacks;

    function configure(ItemStaking target_, bool failPull_, bool failPush_) external {
        target = target_;
        failPull = failPull_;
        failPush = failPush_;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _probe();
        if (failPull) return false;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _probe();
        if (failPush) return false;
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _probe() private {
        bytes[4] memory calls = [
            abi.encodeCall(ItemStaking.stake, (1)),
            abi.encodeCall(ItemStaking.unstake, (1)),
            abi.encodeCall(ItemStaking.sync, (target.BASK())),
            abi.encodeCall(ItemStaking.claim, (target.BASK()))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(target).call(calls[i]);
            require(
                !ok && keccak256(reason) == keccak256(abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector)),
                "unguarded callback"
            );
            ++blockedCallbacks;
        }
    }
}

/// @dev Return-size cases include empty data and oversized *successful* reads.
contract StakingBalanceShape {
    uint256 public responseLength;
    uint256 public reported;

    function configure(uint256 length, uint256 value) external {
        responseLength = length;
        reported = value;
    }

    function balanceOf(address) external view returns (uint256) {
        uint256 length = responseLength;
        uint256 value = reported;
        assembly {
            mstore(0, value)
            return(0, length)
        }
    }
}

/// @dev A reward callback that behaves like a transferring ERC-20 after reentry is rejected.
contract StakingCallbackReward {
    mapping(address => uint256) public balanceOf;
    ItemStaking public target;
    uint256 public rejectedCallbacks;

    function configure(ItemStaking target_) external {
        target = target_;
    }

    function mint(address user, uint256 amount) external {
        balanceOf[user] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        bytes[4] memory calls = [
            abi.encodeCall(ItemStaking.stake, (1)),
            abi.encodeCall(ItemStaking.unstake, (1)),
            abi.encodeCall(ItemStaking.sync, (target.USDG())),
            abi.encodeCall(ItemStaking.claim, (target.USDG()))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(target).call(calls[i]);
            require(
                !ok && keccak256(reason) == keccak256(abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector)),
                "unguarded reward callback"
            );
            ++rejectedCallbacks;
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingTransferBomb {
    mapping(address => uint256) public balanceOf;
    bool public burnGas;

    function setBurnGas(bool value) external {
        burnGas = value;
    }

    function mint(address user, uint256 amount) external {
        balanceOf[user] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (burnGas) {
            assembly {
                for {} 1 {} {}
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        assembly {
            mstore(0, 1)
            return(0, 0x10000)
        }
    }
}

contract ItemStakingAdversarialTest is Test {
    address constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint256 constant D = 7 days;

    LaunchToken internal item;
    ItemStaking internal staking;
    address internal alice = makeAddr("staking-adversarial-alice");
    address internal bob = makeAddr("staking-adversarial-bob");
    address[3] internal tokens = [BASK, USDG, WETH];

    function setUp() public {
        vm.warp(1_800_000_000);
        item = new LaunchToken();
        staking = new ItemStaking(address(item));
        bytes memory code = address(new HostileToken()).code;
        for (uint256 i; i < tokens.length; ++i) {
            vm.etch(tokens[i], code);
        }
        item.transfer(alice, 4e26);
        item.transfer(bob, 4e26);
        vm.prank(alice);
        item.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        item.approve(address(staking), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        staking.stake(amount);
    }

    function _unstake(address user, uint256 amount) internal {
        vm.prank(user);
        staking.unstake(amount);
    }

    function _claim(address user, address token) internal returns (uint256 paid) {
        uint256 beforeBalance = HostileToken(token).balances(user);
        vm.prank(user);
        staking.claim(token);
        paid = HostileToken(token).balances(user) - beforeBalance;
    }

    function _state(ItemStaking target, address token) internal view returns (bytes32) {
        (uint256 a, uint256 i, uint256 f, uint256 s, uint256 t) = target.rewardInfo(token);
        return keccak256(abi.encode(a, i, f, s, t));
    }

    function test_carrySurvivesFullExitAndRestake() public {
        _stake(alice, 1);
        _stake(bob, 1);
        HostileToken(BASK).mint(address(staking), 1);
        staking.sync(BASK);
        vm.warp(vm.getBlockTimestamp() + D);
        assertEq(_claim(alice, BASK), 0);
        assertEq(_claim(bob, BASK), 0);
        _unstake(alice, 1);
        _unstake(bob, 1);
        assertEq(staking.totalStaked(), 0);
        vm.warp(vm.getBlockTimestamp() + 90 days);
        HostileToken(BASK).mint(address(staking), 1);
        staking.sync(BASK);
        _stake(alice, 1);
        _stake(bob, 1);
        vm.warp(vm.getBlockTimestamp() + D);
        assertEq(_claim(alice, BASK), 1, "two fractional entitlements combine across an exit");
        assertEq(_claim(bob, BASK), 1);
        assertEq(HostileToken(BASK).balances(address(staking)), 0);
    }

    function test_sameTimestampLargeStakeCannotCaptureEarlierOrFutureRewards() public {
        _stake(alice, 1);
        HostileToken(BASK).mint(address(staking), 70e18);
        staking.sync(BASK);
        vm.warp(vm.getBlockTimestamp() + D / 2);
        uint256 principalBefore = item.balanceOf(bob);
        _stake(bob, principalBefore);
        assertEq(_claim(bob, BASK), 0, "no retroactive rewards on entry");
        _unstake(bob, principalBefore);
        assertEq(_claim(bob, BASK), 0, "same-timestamp round trip has no yield");
        assertEq(item.balanceOf(bob), principalBefore);
        assertEq(staking.earned(alice, BASK), 35e18);
        vm.warp(vm.getBlockTimestamp() + D / 2);
        assertEq(_claim(alice, BASK), 70e18);
    }

    function test_newlyArrivingStakerCannotTakeCompletedStream() public {
        _stake(alice, 11);
        HostileToken(USDG).mint(address(staking), 7_000_003);
        staking.sync(USDG);
        vm.warp(vm.getBlockTimestamp() + D + 30 days);
        _stake(bob, 4e26);
        assertEq(staking.earned(bob, USDG), 0);
        _unstake(alice, 11);
        assertEq(_claim(bob, USDG), 0);
        uint256 entitlement = staking.earned(alice, USDG);
        assertEq(entitlement, 7_000_002, "one wei of index rounding dust for eleven stake units");
        assertEq(_claim(alice, USDG), entitlement, "the exiting staker still receives its full debt");
    }

    function test_failedTransferRollsBackFinishedStreamAndFreshStreamRecognition() public {
        _stake(alice, 1);
        HostileToken token = HostileToken(BASK);
        token.mint(address(staking), 7);
        staking.sync(BASK);
        vm.warp(vm.getBlockTimestamp() + D);
        token.mint(address(staking), 13);
        bytes32 beforeState = _state(staking, BASK);
        for (uint256 mode = 1; mode <= 2; ++mode) {
            token.setTransferMode(HostileToken.TransferMode(mode));
            vm.prank(alice);
            vm.expectRevert(TokenTransfer.TransferFailed.selector);
            staking.claim(BASK);
            assertEq(_state(staking, BASK), beforeState, "a failed claim must undo both sync and user update");
            assertEq(staking.earned(alice, BASK), 7);
            assertEq(token.balances(alice), 0);
            assertEq(token.balances(address(staking)), 20);
        }
        token.setTransferMode(HostileToken.TransferMode.Normal);
        assertEq(_claim(alice, BASK), 7);
        (uint256 accounted,, uint256 amount, uint256 seconds_,) = staking.rewardInfo(BASK);
        assertEq(accounted, 13);
        assertEq(amount, 13);
        assertEq(seconds_, 0);
        vm.warp(vm.getBlockTimestamp() + D);
        assertEq(_claim(alice, BASK), 13);
    }

    function test_invalidReadRollsBackTimeButPublicSyncStillAdvancesStream() public {
        _stake(alice, 1);
        HostileToken token = HostileToken(BASK);
        token.mint(address(staking), D);
        staking.sync(BASK);
        bytes32 beforeState = _state(staking, BASK);
        vm.warp(vm.getBlockTimestamp() + 123);
        token.setBalanceMode(HostileToken.BalanceMode.Revert);
        vm.prank(alice);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(BASK);
        assertEq(_state(staking, BASK), beforeState);
        staking.sync(BASK);
        (uint256 accounted,, uint256 amount, uint256 seconds_, uint256 last) = staking.rewardInfo(BASK);
        assertEq(accounted, D);
        assertEq(amount, D);
        assertEq(seconds_, 123);
        assertEq(last, vm.getBlockTimestamp());
        assertEq(staking.earned(alice, BASK), 123, "invalid reads must not stop existing rewards");
        token.setBalanceMode(HostileToken.BalanceMode.Normal);
        assertEq(_claim(alice, BASK), 123);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_allThreeHostileRewardsCannotBlockPrincipal(uint8[3] memory rawModes) public {
        _stake(alice, 13);
        for (uint256 i; i < tokens.length; ++i) {
            HostileToken token = HostileToken(tokens[i]);
            token.mint(address(staking), 7e18);
            staking.sync(tokens[i]);
            token.setBalanceMode(HostileToken.BalanceMode(bound(rawModes[i], 1, 6)));
            token.setTransferMode(HostileToken.TransferMode.ReturnFalse);
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 aliceBefore = item.balanceOf(alice);
        uint256 bobBefore = item.balanceOf(bob);
        _stake(bob, 17);
        _unstake(alice, 13);
        _unstake(bob, 17);
        assertEq(item.balanceOf(alice), aliceBefore + 13);
        assertEq(item.balanceOf(bob), bobBefore);
        assertEq(staking.totalStaked(), 0);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(HostileToken(tokens[i]).balances(alice), 0);
            assertEq(HostileToken(tokens[i]).balances(bob), 0);
        }
    }

    function test_exactly32BytesRequiredIncludingSuccessfulOversizedBalanceReads() public {
        vm.etch(WETH, address(new StakingBalanceShape()).code);
        StakingBalanceShape shape = StakingBalanceShape(WETH);
        uint256[5] memory sizes = [uint256(0), 1, 31, 33, 65_536];
        for (uint256 i; i < sizes.length; ++i) {
            shape.configure(sizes[i], 123);
            staking.sync(WETH);
            (uint256 invalidAccounted,,,,) = staking.rewardInfo(WETH);
            assertEq(invalidAccounted, 0, "invalid return size cannot create a stream");
            _stake(alice, 1);
            _unstake(alice, 1);
            vm.prank(alice);
            vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
            staking.claim(WETH);
        }
        shape.configure(32, 123);
        staking.sync(WETH);
        (uint256 accounted,,,,) = staking.rewardInfo(WETH);
        assertEq(accounted, 123, "exactly 32 bytes is a valid balance read");
    }

    function test_zeroReportedBalancePreservesDebtAndCannotRestartLiveStream() public {
        _stake(alice, 1);
        HostileToken token = HostileToken(USDG);
        token.mint(address(staking), 7_000_000);
        staking.sync(USDG);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        token.setBalanceMode(HostileToken.BalanceMode.ReportZero);
        assertEq(_claim(alice, USDG), 0);
        assertEq(staking.earned(alice, USDG), 2_000_000);
        token.mint(address(staking), 11_000_000);
        staking.sync(USDG);
        (uint256 accounted,, uint256 amount, uint256 seconds_,) = staking.rewardInfo(USDG);
        assertEq(accounted, 7_000_000);
        assertEq(amount, 7_000_000);
        assertEq(seconds_, 2 days);
        token.setBalanceMode(HostileToken.BalanceMode.Normal);
        assertEq(_claim(alice, USDG), 2_000_000);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        assertEq(_claim(alice, USDG), 5_000_000);
        (accounted,, amount, seconds_,) = staking.rewardInfo(USDG);
        assertEq(accounted, 11_000_000);
        assertEq(amount, 11_000_000);
        assertEq(seconds_, 0);
    }

    function test_itemCallbacksGuardAllEntriesAndFailedPullPushAreAtomic() public {
        StakingCallbackItem callbackItem = new StakingCallbackItem();
        ItemStaking target = new ItemStaking(address(callbackItem));
        callbackItem.configure(target, false, false);
        callbackItem.mint(alice, 100);
        vm.prank(alice);
        callbackItem.approve(address(target), type(uint256).max);
        for (uint256 i; i < tokens.length; ++i) {
            HostileToken(tokens[i]).mint(address(target), 7);
        }
        vm.prank(alice);
        target.stake(10);
        assertEq(callbackItem.blockedCallbacks(), 4);
        vm.warp(vm.getBlockTimestamp() + D);
        bytes32[3] memory beforeState;
        for (uint256 i; i < tokens.length; ++i) {
            beforeState[i] = _state(target, tokens[i]);
        }
        callbackItem.configure(target, true, false);
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        target.stake(1);
        callbackItem.configure(target, false, true);
        vm.prank(alice);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        target.unstake(10);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(_state(target, tokens[i]), beforeState[i], "failed ITEM transfer rolls back all reward state");
            assertEq(target.earned(alice, tokens[i]), 7);
        }
        assertEq(target.staked(alice), 10);
        assertEq(target.totalStaked(), 10);
        assertEq(callbackItem.balanceOf(alice), 90);
        assertEq(callbackItem.balanceOf(address(target)), 10);
        assertEq(callbackItem.blockedCallbacks(), 4, "nested callback writes also roll back");
        callbackItem.configure(target, false, false);
        vm.prank(alice);
        target.unstake(10);
        assertEq(callbackItem.blockedCallbacks(), 8);
        assertEq(callbackItem.balanceOf(alice), 100);
        assertEq(target.totalStaked(), 0);
    }

    function test_rewardCallbackCannotEnterAnyFunctionAndOuterClaimPaysExactlyOnce() public {
        vm.etch(WETH, address(new StakingCallbackReward()).code);
        StakingCallbackReward reward = StakingCallbackReward(WETH);
        reward.configure(staking);
        _stake(alice, 1);
        reward.mint(address(staking), 7e18);
        HostileToken(USDG).mint(address(staking), 7_000_000);
        staking.sync(WETH);
        staking.sync(USDG);
        vm.warp(vm.getBlockTimestamp() + D);
        vm.prank(alice);
        staking.claim(WETH);
        assertEq(reward.rejectedCallbacks(), 4);
        assertEq(reward.balanceOf(alice), 7e18);
        assertEq(reward.balanceOf(address(staking)), 0);
        assertEq(staking.earned(alice, WETH), 0);
        assertEq(staking.staked(alice), 1);
        assertEq(staking.earned(alice, USDG), 7_000_000);
        assertEq(_claim(alice, USDG), 7_000_000);
        vm.prank(alice);
        staking.claim(WETH);
        assertEq(reward.rejectedCallbacks(), 8);
        assertEq(reward.balanceOf(alice), 7e18, "repeat claim cannot double-pay");
    }

    function test_rewardTransferGasBombAndHugeDataCannotBlockExitsOrOtherClaims() public {
        vm.etch(WETH, address(new StakingTransferBomb()).code);
        StakingTransferBomb bomb = StakingTransferBomb(WETH);
        _stake(alice, 1);
        bomb.mint(address(staking), 7e18);
        HostileToken(BASK).mint(address(staking), 14e18);
        staking.sync(WETH);
        staking.sync(BASK);
        vm.warp(vm.getBlockTimestamp() + D);
        bytes32 beforeState = _state(staking, WETH);
        bomb.setBurnGas(true);
        vm.prank(alice);
        (bool ok,) = address(staking).call{gas: 300_000}(abi.encodeCall(ItemStaking.claim, (WETH)));
        assertFalse(ok);
        assertEq(_state(staking, WETH), beforeState, "out-of-gas token transfer must roll back the claim");
        assertEq(staking.earned(alice, WETH), 7e18);
        _stake(bob, 1);
        _unstake(bob, 1);
        _unstake(alice, 1);
        assertEq(_claim(alice, BASK), 14e18, "unrelated reward remains claimable");
        bomb.setBurnGas(false);
        vm.prank(alice);
        staking.claim(WETH);
        assertEq(bomb.balanceOf(alice), 7e18, "large return data does not change the actual payout");
        assertEq(staking.earned(alice, WETH), 0);
        assertEq(staking.totalStaked(), 0);
    }
}
