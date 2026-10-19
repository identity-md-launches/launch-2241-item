// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A reward token that misbehaves on demand. No constructor so it can be etched at a fixed address.
contract HostileToken {
    enum BalanceMode {
        Normal,
        Revert,
        BurnGas,
        HugeData,
        ReportZero,
        ReportMax,
        ShortData
    }

    enum TransferMode {
        Normal,
        Revert,
        ReturnFalse,
        Reenter
    }

    BalanceMode public balanceMode;
    TransferMode public transferMode;
    address public reenterTarget;
    bytes public reenterData;
    bytes public lastReenterError;

    mapping(address => uint256) public balances;

    function setBalanceMode(BalanceMode m) external {
        balanceMode = m;
    }

    function setTransferMode(TransferMode m) external {
        transferMode = m;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function balanceOf(address who) external view returns (uint256) {
        BalanceMode m = balanceMode;
        if (m == BalanceMode.Normal) return balances[who];
        if (m == BalanceMode.Revert) revert("hostile");
        if (m == BalanceMode.BurnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        if (m == BalanceMode.HugeData) {
            assembly {
                return(0, 0x10000)
            }
        }
        if (m == BalanceMode.ShortData) {
            assembly {
                return(0, 0x1f)
            }
        }
        if (m == BalanceMode.ReportZero) return 0;
        return type(uint256).max;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        TransferMode m = transferMode;
        if (m == TransferMode.Revert) revert("hostile transfer");
        if (m == TransferMode.ReturnFalse) return false;
        if (m == TransferMode.Reenter) {
            (bool ok, bytes memory err) = reenterTarget.call(reenterData);
            if (!ok) lastReenterError = err;
            return true;
        }
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }
}
