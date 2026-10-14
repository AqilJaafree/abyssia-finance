// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";

/// @dev Minimal v4 PoolManager surface for tests (ABI-identical to v4-core 1.0.2).
interface IPoolManagerTest {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev Test-only exact-input swapper: unlocks the PoolManager, swaps, pays the input
/// from its own balance and sends the output to the trader. Fund it before swapping.
contract V4SwapHelper {
    IPoolManagerTest public immutable manager;

    struct Swap {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 limit;
        address to;
    }

    constructor(IPoolManagerTest manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, address to) external {
        manager.unlock(abi.encode(Swap(key, zeroForOne, amountIn, limit, to)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Swap memory sw = abi.decode(data, (Swap));
        int256 delta = manager.swap(
            sw.key,
            IPoolManagerTest.SwapParams({
                zeroForOne: sw.zeroForOne, amountSpecified: -int256(sw.amountIn), sqrtPriceLimitX96: sw.limit
            }),
            ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        _resolve(sw.key.currency0, d0, sw.to);
        _resolve(sw.key.currency1, d1, sw.to);
        return "";
    }

    function _resolve(address currency, int128 d, address to) private {
        if (d < 0) {
            manager.sync(currency);
            IERC20(currency).transfer(address(manager), uint256(uint128(-d)));
            manager.settle();
        } else if (d > 0) {
            manager.take(currency, to, uint256(uint128(d)));
        }
    }
}
