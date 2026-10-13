// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @dev Stands in for the vault: holds the library state, the NFTs and the tokens.
contract V3PositionsHarness {
    V3Positions.State internal s;
    INPM public immutable npm;

    constructor(INPM npm_) {
        npm = npm_;
    }

    function open(V3Positions.OpenParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return V3Positions.open(s, npm, p);
    }

    function withdraw(uint256 tokenId, uint128 liquidity, address recipient)
        external
        returns (uint256, uint256)
    {
        return V3Positions.withdraw(s, npm, tokenId, liquidity, 0, 0, block.timestamp, recipient);
    }

    function withdrawWithMins(uint256 tokenId, uint128 liquidity, uint256 min0, uint256 min1)
        external
        returns (uint256, uint256)
    {
        return V3Positions.withdraw(s, npm, tokenId, liquidity, min0, min1, block.timestamp, address(this));
    }

    function collectFees(uint256 tokenId, address recipient) external returns (uint256, uint256) {
        return V3Positions.collectFees(s, npm, tokenId, recipient);
    }

    function close(uint256 tokenId) external {
        V3Positions.close(s, npm, tokenId);
    }

    function withdrawProRata(uint256 shares, uint256 supply, address recipient) external {
        V3Positions.withdrawProRata(s, npm, shares, supply, recipient, block.timestamp);
    }

    function count() external view returns (uint256) {
        return V3Positions.count(s);
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return V3Positions.tokenIdAt(s, i);
    }

    function positionAmounts(uint256 tokenId) external view returns (uint256, uint256) {
        return V3Positions.positionAmounts(npm, tokenId);
    }
}
