// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockFreezableERC20} from "./MockFreezableERC20.sol";

/// @dev Hostile memecoin that lies in `balanceOf`: once `arm(who)` is called, any
/// balance of `who` above the snapshot taken then is reported as type(uint256).max,
/// so a balance-delta measurement yields an absurd amount. Inherits freeze/blacklist.
contract MockLyingERC20 is MockFreezableERC20 {
    address public lieFor;
    uint256 public snap;

    constructor() MockFreezableERC20("Liar", "LIAR") {}

    function arm(address who) external {
        lieFor = who;
        snap = super.balanceOf(who);
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 real = super.balanceOf(account);
        if (account == lieFor && real > snap) return type(uint256).max;
        return real;
    }
}
