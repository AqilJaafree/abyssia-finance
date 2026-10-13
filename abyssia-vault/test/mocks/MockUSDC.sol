// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 6-decimal stand-in for Arc's USDC ERC-20 interface (0x3600…).
contract MockUSDC is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 dec) ERC20("USD Coin", "USDC") {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
