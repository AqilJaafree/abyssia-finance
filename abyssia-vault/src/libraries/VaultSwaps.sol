// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IV4PoolManager} from "../interfaces/IV4PoolManager.sol";
import {PoolKey} from "../types/PoolKey.sol";

/// @title VaultSwaps
/// @notice Exact-input swaps for the vault, as an EXTERNAL library (delegatecalled):
/// v3 through Uniswap's SwapRouter02, v4 directly against the PoolManager via an unlock
/// callback that the vault forwards to `onUnlock`. The caller enforces its own price
/// bound on `minOut`; this library enforces `minOut` and reports what was received as
/// min(balance delta, the amount Uniswap reports), so a token lying in `balanceOf`
/// cannot over-credit the vault.
library VaultSwaps {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @dev Set only while `swapV4` waits for its unlock callback.
    bytes32 internal constant SWAP_PENDING = keccak256("abyssia.VaultSwaps.swapPending");

    struct V4Swap {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    error InsufficientOutput(uint256 out, uint256 minOut);
    error UnexpectedCallback();

    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @return paid amount of `tokenIn` spent (all of `amountIn`: no price limit)
    /// @return out amount of `tokenOut` received
    function swapV3(
        ISwapRouter02 router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 paid, uint256 out) {
        paid = amountIn;
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        uint256 reported = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        out = Math.min(IERC20(tokenOut).balanceOf(address(this)) - before, reported);
        if (out < minOut) revert InsufficientOutput(out, minOut);
        emit Swapped(tokenIn, tokenOut, amountIn, out);
    }

    /// @return paid amount of the input token the pool took (<= amountIn if the swap
    /// hit the price limit)
    /// @return out amount of the output token received
    function swapV4(
        IV4PoolManager manager,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 paid, uint256 out) {
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        SWAP_PENDING.asBoolean().tstore(true);
        uint256 reported;
        (paid, reported) =
            abi.decode(manager.unlock(abi.encode(V4Swap(key, zeroForOne, amountIn))), (uint256, uint256));
        SWAP_PENDING.asBoolean().tstore(false);
        out = Math.min(IERC20(tokenOut).balanceOf(address(this)) - before, reported);
        if (out < minOut) revert InsufficientOutput(out, minOut);
        emit Swapped(zeroForOne ? key.currency0 : key.currency1, tokenOut, paid, out);
    }

    /// @notice Body of the vault's `unlockCallback`. The vault must check that
    /// msg.sender is the PoolManager; this checks the call was requested by `swapV4`.
    function onUnlock(IV4PoolManager manager, bytes calldata data) external returns (bytes memory) {
        if (!SWAP_PENDING.asBoolean().tload()) revert UnexpectedCallback();
        SWAP_PENDING.asBoolean().tstore(false);
        V4Swap memory sw = abi.decode(data, (V4Swap));
        int256 delta = manager.swap(
            sw.key,
            IV4PoolManager.SwapParams({
                zeroForOne: sw.zeroForOne,
                amountSpecified: -int256(sw.amountIn),
                sqrtPriceLimitX96: sw.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (address tokenIn, address tokenOut) =
            sw.zeroForOne ? (sw.key.currency0, sw.key.currency1) : (sw.key.currency1, sw.key.currency0);
        int128 dIn = sw.zeroForOne ? int128(delta >> 128) : int128(delta);
        int128 dOut = sw.zeroForOne ? int128(delta) : int128(delta >> 128);
        // Exact input: pay what the pool says is owed (<= amountIn), take what it owes us.
        uint256 paid = dIn < 0 ? uint256(uint128(-dIn)) : 0;
        if (paid > 0) {
            manager.sync(tokenIn);
            IERC20(tokenIn).safeTransfer(address(manager), paid);
            manager.settle();
        }
        uint256 out = dOut > 0 ? uint256(uint128(dOut)) : 0;
        if (out > 0) manager.take(tokenOut, address(this), out);
        return abi.encode(paid, out);
    }
}
