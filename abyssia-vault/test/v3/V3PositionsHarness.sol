// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @dev Stands in for the vault: holds the library state, the NFTs and the tokens.
/// `inKindExit` / `sliceTo` / `claimOwed` are the REFERENCE implementation of the
/// in-kind exit pattern required by V3Positions (see its NatSpec) for Plan 5.
contract V3PositionsHarness {
    using SafeERC20 for IERC20;

    V3Positions.State internal s;
    INPM public immutable npm;

    /// @dev Slices collected to the vault because they could not be delivered to the
    /// receiver; claimable via `claimOwed`. Not part of the vault's own assets.
    mapping(address receiver => mapping(address token => uint256)) public owed;

    event SliceSkipped(uint256 indexed tokenId);

    error OnlySelf();

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

    /// @notice In-kind exit across every position. Per position: deliver the slice to
    /// `receiver`; if a token transfer fails, collect it to this contract and record an
    /// IOU; if even that fails, leave the slice in the position and emit SliceSkipped.
    /// @param supply total share supply BEFORE the exiting shares were burned.
    function inKindExit(uint256 shares, uint256 supply, address receiver) external {
        uint256 n = V3Positions.count(s);
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = V3Positions.tokenIdAt(s, i);
            try this.sliceTo(tokenId, shares, supply, receiver) {}
            catch {
                try this.sliceTo(tokenId, shares, supply, address(this)) returns (uint256 a0, uint256 a1) {
                    (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);
                    owed[receiver][token0] += a0;
                    owed[receiver][token1] += a1;
                } catch {
                    emit SliceSkipped(tokenId);
                }
            }
        }
    }

    /// @dev Self-call only: its own call frame makes decrease+collect revert atomically
    /// when a token transfer fails.
    function sliceTo(uint256 tokenId, uint256 shares, uint256 supply, address recipient)
        external
        returns (uint256, uint256)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        return V3Positions.withdrawSlice(s, npm, tokenId, shares, supply, recipient, block.timestamp);
    }

    function claimOwed(address token) external {
        uint256 amount = owed[msg.sender][token];
        owed[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
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
