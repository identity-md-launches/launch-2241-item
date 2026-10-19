// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Minimal ERC-20 transfer helpers
/// @notice A transfer succeeds only if the call succeeds and returns either nothing or `true`.
library TokenTransfer {
    error TransferFailed();

    function pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        if (!ok || !(data.length == 0 || abi.decode(data, (bool)))) revert TransferFailed();
    }

    function push(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || !(data.length == 0 || abi.decode(data, (bool)))) revert TransferFailed();
    }
}
