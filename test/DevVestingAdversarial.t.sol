// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DevVesting} from "src/DevVesting.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ReentrancyGuard} from "src/ReentrancyGuard.sol";
import {TokenTransfer} from "src/libraries/TokenTransfer.sol";

/// @dev Models failures after balances have changed, so the tests exercise transaction rollback.
contract VestingCallbackToken {
    enum Reply {
        True,
        False,
        Revert,
        Empty,
        Short,
        InvalidBool
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Reply public reply;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackArmed;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    uint256 public callbacks;

    error TokenRejected();

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setReply(Reply mode) external {
        reply = mode;
    }

    function arm(address target, bytes memory data) external {
        callbackTarget = target;
        callbackData = data;
        callbackArmed = true;
        callbackSucceeded = false;
        callbackError = bytes4(0);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return _answer();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _answer();
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (callbackArmed) {
            callbackArmed = false;
            ++callbacks;
            (bool success, bytes memory result) = callbackTarget.call(callbackData);
            callbackSucceeded = success;
            if (result.length >= 4) callbackError = bytes4(result);
        }
    }

    function _answer() private view returns (bool) {
        if (reply == Reply.Revert) revert TokenRejected();
        if (reply == Reply.False) return false;
        if (reply == Reply.Empty) {
            assembly { return(0, 0) }
        }
        if (reply == Reply.Short) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (reply == Reply.InvalidBool) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract VestingConstructorTrap {
    fallback() external {
        revert("constructor must not call ITEM");
    }
}

contract DevVestingAdversarialTest is Test {
    address private constant BENEFICIARY = 0xc5e21e7A89F1fBDc5554e31702e627dD6262C856;
    uint256 private constant ALLOCATION = 40_000_000e18;
    uint256 private constant DURATION = 1460 days;
    LaunchToken private item;
    DevVesting private vesting;
    address private sponsor;
    address private caller;
    uint256 private deployedAt;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_123);
        sponsor = makeAddr("vesting sponsor");
        caller = makeAddr("permissionless vesting releaser");
        item = new LaunchToken();
        vesting = new DevVesting(address(item), BENEFICIARY);
        deployedAt = vm.getBlockTimestamp();
    }

    function test_constructorDoesNotCallItemOrMoveSupply() public {
        VestingConstructorTrap trap = new VestingConstructorTrap();
        DevVesting withTrap = new DevVesting(address(trap), BENEFICIARY);
        assertEq(withTrap.item(), address(trap));
        assertEq(item.balanceOf(address(this)), item.totalSupply());
        assertEq(item.balanceOf(address(vesting)), 0);
    }

    function test_anySponsorCanFundAndAnyCallerCanReleaseOnlyToLiteralBeneficiary() public {
        item.transfer(sponsor, ALLOCATION);
        vm.prank(sponsor);
        item.approve(address(vesting), ALLOCATION);
        vm.expectEmit(true, false, false, true, address(vesting));
        emit DevVesting.Funded(sponsor, ALLOCATION);
        vm.prank(sponsor);
        vesting.fund();
        assertEq(item.allowance(sponsor, address(vesting)), 0);
        vm.warp(deployedAt + 365 days);
        vm.expectEmit(true, false, false, true, address(vesting));
        emit DevVesting.Released(BENEFICIARY, ALLOCATION / 4);
        vm.prank(caller);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION / 4);
        assertEq(item.balanceOf(caller), 0);
        assertEq(item.balanceOf(sponsor), 0);
        vm.prank(caller);
        vm.expectRevert(DevVesting.AlreadyFunded.selector);
        vesting.fund();
    }

    function test_fundWithOneWeiTooLittleAllowanceIsAtomicAndRetryable() public {
        item.approve(address(vesting), ALLOCATION - 1);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vesting.fund();
        assertFalse(vesting.funded());
        assertEq(item.balanceOf(address(vesting)), 0);
        assertEq(item.balanceOf(address(this)), 1e27);
        assertEq(item.allowance(address(this), address(vesting)), ALLOCATION - 1);
        item.approve(address(vesting), ALLOCATION);
        vesting.fund();
        assertTrue(vesting.funded());
    }

    function test_fundWithOneWeiTooLittleBalanceDoesNotConsumeAllowance() public {
        item.transfer(sponsor, ALLOCATION - 1);
        vm.prank(sponsor);
        item.approve(address(vesting), ALLOCATION);
        vm.prank(sponsor);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vesting.fund();
        assertFalse(vesting.funded());
        assertEq(item.allowance(sponsor, address(vesting)), ALLOCATION);
        assertEq(item.balanceOf(sponsor), ALLOCATION - 1);
        item.transfer(sponsor, 1);
        vm.prank(sponsor);
        vesting.fund();
        assertEq(item.balanceOf(address(vesting)), ALLOCATION);
    }

    function test_donationsNeitherFundNorIncreaseVestedAllocation() public {
        item.transfer(address(vesting), 1e18 + 1);
        vm.warp(deployedAt + DURATION + 1);
        vm.expectRevert(DevVesting.NotFunded.selector);
        vesting.release();
        item.approve(address(vesting), ALLOCATION);
        vesting.fund();
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(item.balanceOf(address(vesting)), 1e18 + 1);
        assertEq(vesting.released(), ALLOCATION);
        vm.warp(deployedAt + DURATION * 100);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
    }

    function test_exactDay364AndCliffAdjacentSeconds() public {
        item.approve(address(vesting), ALLOCATION);
        vesting.fund();
        vm.warp(deployedAt + 364 days);
        vesting.release();
        assertEq(vesting.vested(), 0);
        assertEq(item.balanceOf(BENEFICIARY), 0);
        vm.warp(deployedAt + 365 days - 1);
        assertEq(vesting.vested(), 0);
        vm.warp(deployedAt + 365 days);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION / 4);
        vm.warp(deployedAt + 365 days + 1);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION / 4 + ALLOCATION / DURATION);
    }

    function test_completionAdjacentSecondsPayTheLastWeiOnlyOnce() public {
        item.approve(address(vesting), ALLOCATION);
        vesting.fund();
        vm.warp(deployedAt + DURATION - 1);
        vesting.release();
        uint256 before = item.balanceOf(BENEFICIARY);
        assertLt(before, ALLOCATION);
        assertGt(item.balanceOf(address(vesting)), 0);
        vm.warp(deployedAt + DURATION);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(item.balanceOf(address(vesting)), 0);
        vm.warp(deployedAt + DURATION + 1);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(vesting.released(), ALLOCATION);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_releasePartitionDoesNotLoseDust(uint256 elapsedSeed, uint256 splitSeed) public {
        uint256 elapsed = bound(elapsedSeed, 365 days, DURATION);
        uint256 split = bound(splitSeed, 365 days, elapsed);
        item.approve(address(vesting), ALLOCATION);
        vesting.fund();
        vm.warp(deployedAt + split);
        vesting.release();
        vm.warp(deployedAt + elapsed);
        vesting.release();
        uint256 paid = item.balanceOf(BENEFICIARY);
        assertLe(paid * DURATION, ALLOCATION * elapsed);
        assertGt((paid + 1) * DURATION, ALLOCATION * elapsed);
        uint256 before = paid;
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), before);
        vm.warp(deployedAt + DURATION);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(item.balanceOf(address(vesting)), 0);
    }

    function test_failedAndMalformedFundTransfersRollbackAllChanges() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            if (mode == uint256(VestingCallbackToken.Reply.Empty)) continue;
            (VestingCallbackToken hostile, DevVesting target) = _hostileFixture();
            hostile.setReply(VestingCallbackToken.Reply(mode));
            if (mode <= uint256(VestingCallbackToken.Reply.Revert)) {
                vm.expectRevert(TokenTransfer.TransferFailed.selector);
            } else {
                vm.expectRevert();
            }
            target.fund();
            assertFalse(target.funded());
            assertEq(hostile.balanceOf(address(target)), 0);
            assertEq(hostile.balanceOf(address(this)), ALLOCATION);
            assertEq(hostile.allowance(address(this), address(target)), ALLOCATION);
            hostile.setReply(VestingCallbackToken.Reply.True);
            target.fund();
            assertTrue(target.funded());
        }
    }

    function test_failedAndMalformedReleaseTransfersLeaveTheWholeDebtOwed() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            if (mode == uint256(VestingCallbackToken.Reply.Empty)) continue;
            (VestingCallbackToken hostile, DevVesting target) = _hostileFixture();
            target.fund();
            vm.warp(vm.getBlockTimestamp() + 365 days);
            hostile.setReply(VestingCallbackToken.Reply(mode));
            if (mode <= uint256(VestingCallbackToken.Reply.Revert)) {
                vm.expectRevert(TokenTransfer.TransferFailed.selector);
            } else {
                vm.expectRevert();
            }
            target.release();
            assertEq(target.released(), 0);
            assertEq(hostile.balanceOf(BENEFICIARY), 0);
            assertEq(hostile.balanceOf(address(target)), ALLOCATION);
            hostile.setReply(VestingCallbackToken.Reply.True);
            target.release();
            assertEq(target.released(), ALLOCATION / 4);
            assertEq(hostile.balanceOf(BENEFICIARY), ALLOCATION / 4);
        }
    }

    function test_noReturnTransfersStillMoveExactlyTheAllocation() public {
        (VestingCallbackToken hostile, DevVesting target) = _hostileFixture();
        hostile.setReply(VestingCallbackToken.Reply.Empty);
        target.fund();
        vm.warp(target.deployedAt() + DURATION);
        target.release();
        assertEq(hostile.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(hostile.balanceOf(address(target)), 0);
    }

    function test_fundBlocksBothReentrantMutators() public {
        _checkCallback(false, DevVesting.fund.selector);
        _checkCallback(false, DevVesting.release.selector);
    }

    function test_releaseBlocksBothReentrantMutators() public {
        _checkCallback(true, DevVesting.fund.selector);
        _checkCallback(true, DevVesting.release.selector);
    }

    function _checkCallback(bool onRelease, bytes4 selector) private {
        (VestingCallbackToken hostile, DevVesting target) = _hostileFixture();
        vm.warp(target.deployedAt() + DURATION);
        if (onRelease) target.fund();
        hostile.arm(address(target), abi.encodeWithSelector(selector));
        if (onRelease) target.release();
        else target.fund();
        assertEq(hostile.callbacks(), 1);
        assertFalse(hostile.callbackSucceeded());
        assertEq(hostile.callbackError(), ReentrancyGuard.Reentrancy.selector);
        assertEq(target.released(), onRelease ? ALLOCATION : 0);
        if (!onRelease) target.release();
        // A blocked callback must not leave the outer guard locked.
        target.release();
        assertEq(hostile.balanceOf(BENEFICIARY), ALLOCATION);
    }

    function _hostileFixture() private returns (VestingCallbackToken hostile, DevVesting target) {
        hostile = new VestingCallbackToken();
        target = new DevVesting(address(hostile), BENEFICIARY);
        hostile.mint(address(this), ALLOCATION);
        hostile.approve(address(target), ALLOCATION);
    }
}
