// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LpGauge} from "./LpGauge.sol";

/// @title ITEM/WETH LP gauge: 210,000,000 ITEM over 4 years of staked time
contract ItemEthGauge is LpGauge {
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    constructor(address item_) LpGauge(item_, item_, WETH, 210_000_000e18) {}
}
