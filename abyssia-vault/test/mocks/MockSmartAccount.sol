// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal smart account (the shape of a Safe / ERC-4337 / EIP-7702 account): its
/// owner makes it execute calls, one at a time or as an atomic batch.
contract MockSmartAccount {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable owner;

    error NotOwner();
    error CallFailed(uint256 index, bytes reason);

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(target, data);
        return _run(calls)[0];
    }

    function executeBatch(Call[] calldata calls) external returns (bytes[] memory) {
        return _run(calls);
    }

    function _run(Call[] memory calls) private returns (bytes[] memory results) {
        if (msg.sender != owner) revert NotOwner();
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
            results[i] = ret;
        }
    }
}
