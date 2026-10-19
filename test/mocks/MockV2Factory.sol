// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stand-in for V2_FACTORY.getPair, etched at the constant factory address in tests.
contract MockV2Factory {
    mapping(address => mapping(address => address)) private pairs;

    function setPair(address a, address b, address pair) external {
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}
