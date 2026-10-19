// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An LP token that calls back into a target on every transfer and records the error it got.
contract ReentrantLp is MockERC20 {
    address public target;
    bytes public data;
    bytes public lastError;
    bool public armed;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) lastError = err;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _reenter();
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _reenter();
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }
}
