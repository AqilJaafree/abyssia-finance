// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Worst case for the in-kind exit's fallback rule: once armed, a transfer to
/// `receiver` burns `cheap` gas and reverts (just under the "cheap failure" threshold,
/// so the vault retries), and a transfer to `vault` (the retry) burns ALL gas it is given.
contract MockTwoStageBurnerERC20 is ERC20 {
    address public receiver;
    address public vault;
    uint256 public cheap;
    mapping(uint256 => uint256) private junk;

    constructor() ERC20("Two-stage burner", "TSB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address receiver_, address vault_, uint256 cheap_) external {
        (receiver, vault, cheap) = (receiver_, vault_, cheap_);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (receiver != address(0) && to == receiver) {
            uint256 g = gasleft();
            while (g - gasleft() < cheap) {}
            revert("blocked");
        }
        if (vault != address(0) && to == vault) {
            for (uint256 i = 1;; i++) {
                junk[i] = i;
            }
        }
        return super.transfer(to, value);
    }
}
