// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 18-decimal "hostile" memecoin: the owner-less test can freeze ALL transfers
/// (paused token) or block transfers TO a specific address (blacklist / max-wallet).
/// Minting is never blocked. `setFeeBps` turns it into a fee-on-transfer token: each
/// transfer burns `value * feeBps / 10_000` from the amount delivered.
contract MockFreezableERC20 is ERC20 {
    bool public frozen;
    mapping(address => bool) public blocked;
    uint256 public feeBps;

    error Frozen();
    error Blocked(address to);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze() external {
        frozen = true;
    }

    function unfreeze() external {
        frozen = false;
    }

    function setBlocked(address who, bool isBlocked) external {
        blocked[who] = isBlocked;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _check(to);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _check(to);
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (from == address(0) || to == address(0)) ? 0 : value * feeBps / 10_000;
        if (fee != 0) super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }

    function _check(address to) private view {
        if (frozen) revert Frozen();
        if (blocked[to]) revert Blocked(to);
    }
}
