// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Item");
        assertEq(token.symbol(), "ITEM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_transfer() public {
        assertTrue(token.transfer(alice, 1e18));
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(address(this)), 1e27 - 1e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
    }

    function test_transferFromWithAllowance() public {
        token.approve(alice, 5e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 3e18));
        assertEq(token.balanceOf(bob), 3e18);
        assertEq(token.allowance(address(this), alice), 2e18);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 3e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1e18);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
