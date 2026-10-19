// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Single-entry guard for every state-changing function
abstract contract ReentrancyGuard {
    error Reentrancy();

    uint256 private _entered = 1;

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }
}
