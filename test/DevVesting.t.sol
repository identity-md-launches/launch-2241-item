// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DevVesting} from "../src/DevVesting.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenTransfer} from "../src/libraries/TokenTransfer.sol";

contract DevVestingTest is Test {
    address constant BENEFICIARY = 0xc5e21e7A89F1fBDc5554e31702e627dD6262C856;
    uint256 constant ALLOCATION = 40_000_000e18;

    LaunchToken item;
    DevVesting vesting;
    uint256 deployedAt;
    address anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(1_700_000_000);
        item = new LaunchToken();
        vesting = new DevVesting(address(item), BENEFICIARY);
        deployedAt = block.timestamp;
        item.approve(address(vesting), type(uint256).max);
    }

    function _fund() internal {
        vesting.fund();
    }

    function test_views() public view {
        assertEq(vesting.item(), address(item));
        assertEq(vesting.beneficiary(), BENEFICIARY);
        assertEq(vesting.ALLOCATION(), ALLOCATION);
        assertEq(vesting.deployedAt(), deployedAt);
        assertFalse(vesting.funded());
        assertEq(vesting.vested(), 0);
        assertEq(vesting.released(), 0);
    }

    function test_zeroBeneficiaryReverts() public {
        vm.expectRevert(DevVesting.ZeroBeneficiary.selector);
        new DevVesting(address(item), address(0));
    }

    function test_fundPullsExactlyAllocationOnce() public {
        uint256 before = item.balanceOf(address(this));
        vm.expectEmit(true, false, false, true);
        emit DevVesting.Funded(address(this), ALLOCATION);
        _fund();
        assertTrue(vesting.funded());
        assertEq(before - item.balanceOf(address(this)), ALLOCATION);
        assertEq(item.balanceOf(address(vesting)), ALLOCATION);
        vm.expectRevert(DevVesting.AlreadyFunded.selector);
        vesting.fund();
    }

    function test_fundRevertsWithoutAllowance() public {
        vm.prank(anyone);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vesting.fund();
        assertFalse(vesting.funded());
    }

    function test_releaseBeforeFundReverts() public {
        vm.warp(deployedAt + 1460 days);
        vm.expectRevert(DevVesting.NotFunded.selector);
        vesting.release();
    }

    function test_day364NothingVested() public {
        _fund();
        vm.warp(deployedAt + 365 days - 1);
        assertEq(vesting.vested(), 0);
        vm.prank(anyone);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), 0);
        assertEq(vesting.released(), 0);
    }

    function test_day365VestsOneQuarter() public {
        _fund();
        vm.warp(deployedAt + 365 days);
        assertEq(vesting.vested(), ALLOCATION * 365 / 1460);
        assertEq(vesting.vested(), 10_000_000e18);
        vm.expectEmit(true, false, false, true);
        emit DevVesting.Released(BENEFICIARY, 10_000_000e18);
        vm.prank(anyone);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), 10_000_000e18);
        assertEq(vesting.released(), 10_000_000e18);
    }

    function test_day1460VestsEverything() public {
        _fund();
        vm.warp(deployedAt + 1460 days);
        assertEq(vesting.vested(), ALLOCATION);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
        assertEq(item.balanceOf(address(vesting)), 0);
        vm.warp(deployedAt + 3000 days);
        assertEq(vesting.vested(), ALLOCATION);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION);
    }

    function test_releasesOnlyTheDifference() public {
        _fund();
        vm.warp(deployedAt + 500 days);
        vesting.release();
        uint256 first = ALLOCATION * 500 days / 1460 days;
        assertEq(item.balanceOf(BENEFICIARY), first);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), first);
        vm.warp(deployedAt + 1000 days);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION * 1000 days / 1460 days);
        assertEq(vesting.released(), ALLOCATION * 1000 days / 1460 days);
    }

    function test_fuzz_releasedNeverExceedsVested(uint256 a, uint256 b) public {
        _fund();
        a = bound(a, 0, 2000 days);
        b = bound(b, 0, 2000 days);
        vm.warp(deployedAt + a);
        vesting.release();
        vm.warp(deployedAt + a + b);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), vesting.vested());
        assertLe(vesting.vested(), ALLOCATION);
        assertEq(vesting.released() + item.balanceOf(address(vesting)), ALLOCATION);
    }

    function test_fundingLateDoesNotChangeTheSchedule() public {
        vm.warp(deployedAt + 1000 days);
        _fund();
        assertEq(vesting.vested(), ALLOCATION * 1000 days / 1460 days);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), ALLOCATION * 1000 days / 1460 days);
    }
}
