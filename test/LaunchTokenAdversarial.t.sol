// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenAdversarialTest is Test {
    LaunchToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        vm.chainId(4663);
        token = new LaunchToken();
        alice = makeAddr("launch token alice");
        bob = makeAddr("launch token bob");
    }

    function test_constructorEmitsTheOnlyMintAndMintsOnlyToDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Transfer(address(0), alice, 1e27);
        vm.prank(alice);
        LaunchToken deployed = new LaunchToken();
        assertEq(deployed.balanceOf(alice), 1e27);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_zeroTransferFromWithoutApprovalSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit LaunchToken.Transfer(alice, bob, 0);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, address(this)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransfersPreserveBalanceButConsumeFiniteAllowance() public {
        token.transfer(alice, 17);
        vm.startPrank(alice);
        token.transfer(alice, 17);
        token.approve(bob, 17);
        vm.stopPrank();
        vm.prank(bob);
        token.transferFrom(alice, alice, 17);
        assertEq(token.balanceOf(alice), 17);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_insufficientBalanceRevertsAllowanceConsumption() public {
        vm.prank(alice);
        token.approve(bob, 23);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(alice, bob, 23);
        assertEq(token.allowance(alice, bob), 23);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approvalReplacementAndRevocationEmitExactValues() public {
        token.approve(alice, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit LaunchToken.Approval(address(this), alice, 1);
        token.approve(alice, 1);
        assertEq(token.allowance(address(this), alice), 1);
        token.approve(alice, 0);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_maximumTransferCannotWrapBalanceOrAllowance() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(address(this), bob, type(uint256).max);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fullBalanceRoundTripHasNoFeeOrSupplyChange(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 0, 1e27);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        token.transferFrom(alice, address(this), amount);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), 1e27);
    }
}
