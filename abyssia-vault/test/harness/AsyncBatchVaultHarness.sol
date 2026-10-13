// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";

/// @dev Concrete vault for unit tests: "deployed value" is a settable number,
/// standing in for LP positions until the adapters exist.
contract AsyncBatchVaultHarness is AsyncBatchVault {
    uint256 public deployedValue;
    uint256 public beforeSettleCalls;

    constructor(IERC20 usdc, address admin, address keeper, address guardian)
        AsyncBatchVault(
            usdc, "Abyssia Test Vault", "abTEST", admin, keeper, guardian, 1e6, 1_000_000e6, 2_000
        )
    {}

    function setDeployedValue(uint256 v) external {
        deployedValue = v;
    }

    function harnessIncreaseIdle(uint256 a) external {
        _increaseIdle(a);
    }

    function harnessDecreaseIdle(uint256 a) external {
        _decreaseIdle(a);
    }

    function _deployedValue() internal view override returns (uint256) {
        return deployedValue;
    }

    function _ensureIdle(uint256) internal override {}

    function _redeemPositionsInKind(uint256, uint256, address) internal override {}

    function _beforeSettle() internal override {
        beforeSettleCalls++;
    }
}
