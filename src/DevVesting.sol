// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {TokenTransfer} from "./libraries/TokenTransfer.sol";

/// @title Developer vesting of 40,000,000 ITEM
/// @notice Nothing vests for the first 365 days after deployment; then ALLOCATION * min(elapsed, 1460 days) /
/// 1460 days is vested. fund() pulls the allocation once; release() sends whatever has vested and is unpaid to
/// the fixed beneficiary. Not revocable, no owner.
contract DevVesting is ReentrancyGuard {
    uint256 public constant ALLOCATION = 40_000_000e18;
    uint256 public constant CLIFF = 365 days;
    uint256 public constant DURATION = 1460 days;

    address public immutable item;
    address public immutable beneficiary;
    uint256 public immutable deployedAt;

    bool public funded;
    uint256 public released;

    event Funded(address indexed from, uint256 amount);
    event Released(address indexed beneficiary, uint256 amount);

    error ZeroBeneficiary();
    error AlreadyFunded();
    error NotFunded();

    constructor(address item_, address beneficiary_) {
        if (beneficiary_ == address(0)) revert ZeroBeneficiary();
        item = item_;
        beneficiary = beneficiary_;
        deployedAt = block.timestamp;
    }

    /// @notice Once: pulls exactly ALLOCATION of ITEM from the caller.
    function fund() external nonReentrant {
        if (funded) revert AlreadyFunded();
        funded = true;
        TokenTransfer.pull(item, msg.sender, ALLOCATION);
        emit Funded(msg.sender, ALLOCATION);
    }

    /// @notice Anyone, after fund(): sends vested - released to the beneficiary.
    function release() external nonReentrant {
        if (!funded) revert NotFunded();
        uint256 amount = vested() - released;
        released += amount;
        TokenTransfer.push(item, beneficiary, amount);
        emit Released(beneficiary, amount);
    }

    /// @notice 0 before 365 days since deployment, then linear to ALLOCATION at 1460 days.
    function vested() public view returns (uint256) {
        uint256 elapsed = block.timestamp - deployedAt;
        if (elapsed < CLIFF) return 0;
        if (elapsed > DURATION) elapsed = DURATION;
        return ALLOCATION * elapsed / DURATION;
    }
}
