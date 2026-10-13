// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 18-decimal griefing token: once `setBurn(true)`, every `transfer` /
/// `transferFrom` writes storage in an endless loop until it runs out of gas, burning
/// everything forwarded to it. Minting is never affected.
contract MockGasBurnerERC20 is ERC20 {
    bool public burn;
    mapping(uint256 => uint256) private junk;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurn(bool on) external {
        burn = on;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _burnGas();
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _burnGas();
        return super.transferFrom(from, to, value);
    }

    function _burnGas() private {
        if (!burn) return;
        for (uint256 i = 1;; i++) {
            junk[i] = i;
        }
    }
}
