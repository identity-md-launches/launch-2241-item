// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenSequenceHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("launch invariant actor ", vm.toString(i)));
            modelBalance[actors[i]] = 1e27 / actors.length;
            token.transfer(actors[i], modelBalance[actors[i]]);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, modelBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Preserve arbitrary allowances, including zero and uint256.max.
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        modelAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = modelAllowance[from][spender];
        uint256 maximum = modelBalance[from] < allowed ? modelBalance[from] : allowed;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowed != type(uint256).max) modelAllowance[from][spender] -= amount;
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
    }

    function rejectOverspend(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = modelBalance[from] + bound(excessSeed, 1, 1e27);
        vm.prank(from);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(to, amount);
    }

    function rejectUnauthorizedTransfer(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        vm.prank(from);
        token.approve(spender, 0);
        modelAllowance[from][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(from, to, 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchTokenSequenceHandler private handler;
    LaunchToken private token;

    function setUp() public {
        vm.chainId(4663);
        handler = new LaunchTokenSequenceHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectUnauthorizedTransfer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_everyBalanceMatchesTransfersAndNoSupplyAppearsOrDisappears() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.modelBalance(actor));
            sum += balance;
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_onlyAuthorizedSpendingConsumesAllowance() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.modelAllowance(owner, spender));
            }
        }
    }
}
