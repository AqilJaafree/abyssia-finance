// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {AsyncBatchVault} from "./AsyncBatchVault.sol";
import {VaultRegistry} from "./registry/VaultRegistry.sol";
import {V3Positions} from "./v3/V3Positions.sol";
import {V4Positions} from "./v4/V4Positions.sol";
import {VaultSwaps} from "./libraries/VaultSwaps.sol";
import {VaultBook} from "./libraries/VaultBook.sol";
import {VaultOps} from "./libraries/VaultOps.sol";
import {INonfungiblePositionManager as INPM} from "./interfaces/INonfungiblePositionManager.sol";
import {IV4PositionManager} from "./interfaces/IV4PositionManager.sol";
import {IV4PoolManager} from "./interfaces/IV4PoolManager.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IStateView} from "./interfaces/IStateView.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";

/// @title AbyssiaVault
/// @notice USDC vault that provides Uniswap v3 and v4 liquidity to registry-allowlisted
/// USDC pools. Deposits/redemptions settle in batches (AsyncBatchVault); an in-kind exit
/// is always available. The keeper opens, withdraws and closes positions, collects fees
/// and swaps between USDC and a pool's token, always within the registry's class limits,
/// only in hookless v4 pools, and never sending assets anywhere but the vault.
/// TRUST: the keeper is trusted within these bounds, not beyond them. Spot-price checks
/// bound price impact, not manipulation: a compromised keeper colluding with someone who
/// moves a pool's price can open, withdraw or swap at that price (up to the pool's
/// allocation), and the keeper picks the expected price each settlement is checked against.
/// Run the keeper with private transaction submission and off-chain fair prices (its
/// expected settlement price must come from those, never from this vault's own
/// `sharePrice()` read just before settling, which would undo the protection); a later
/// plan adds TWAP bounds and a minimum interval between settlements.
/// @dev Accounting never takes token balances as truth: idle USDC (`idleAssets`) and token
/// inventory (`tokenBalance`) are tracked internally, and every credit is the smaller of
/// the balance delta and the amount Uniswap's own math reports. The book, its checks and
/// the operations live in the VaultBook / VaultOps libraries; this contract owns idle
/// USDC, access control and the in-kind exit's gas and fallback logic.
contract AbyssiaVault is AsyncBatchVault {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Bytes32Slot;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @notice Hard cap on open positions across v3 AND v4. Sized from the measured worst
    /// case of an in-kind exit (20 hostile positions that also sit in inventory: ~16.2M
    /// gas), so a full exit stays well under Arc's 30M block gas limit.
    uint256 public constant MAX_POSITIONS = VaultBook.MAX_POSITIONS;
    /// @notice Hard cap on distinct non-USDC tokens held as inventory.
    uint256 public constant MAX_TOKENS = VaultOps.MAX_TOKENS;
    /// @notice Hard cap on the keeper's swap slippage bound (vs the pool's price).
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS_CAP = 1_000;
    /// @notice Gas budget of ONE in-kind slice attempt (a normal slice uses ~170-200k).
    uint256 public constant SLICE_GAS = 500_000;
    /// @notice Gas budget of ONE inventory-token transfer in an in-kind exit.
    uint256 public constant TOKEN_GAS = 100_000;
    /// @notice Gas budget of ONE fee harvest at settlement.
    uint256 public constant HARVEST_GAS = 400_000;
    /// @notice Kept back on top of a capped call's budget * 64/63.
    uint256 public constant GAS_RESERVE = 50_000;
    /// @notice Retry an in-kind slice with the vault as recipient only if the failed
    /// attempt used at most this share of SLICE_GAS: an honest refusal fails early, a gas
    /// burner uses nearly everything at any call depth.
    uint256 public constant FALLBACK_MAX_BPS = 6_000;

    /// @dev keccak256(abi.encode(shares, supply, receiver)) during an in-kind exit.
    bytes32 internal constant EXIT_BINDING = keccak256("abyssia.AbyssiaVault.exitBinding");
    /// @dev Set while `_beforeSettle` harvests.
    bytes32 internal constant HARVESTING = keccak256("abyssia.AbyssiaVault.harvesting");

    struct Config {
        IERC20 usdc;
        string name;
        string symbol;
        address admin;
        address keeper;
        address guardian;
        uint256 minDeposit;
        uint256 maxTotalAssets;
        uint256 maxCycleMoveBps;
        uint256 maxSwapSlippageBps;
        VaultRegistry registry;
        INPM npm;
        ISwapRouter02 swapRouter02;
        IV4PositionManager posm;
        IStateView stateView;
    }

    VaultRegistry public immutable registry;
    INPM public immutable npm;
    ISwapRouter02 public immutable swapRouter02;
    IV4PositionManager public immutable posm;
    IPermit2 public immutable permit2;
    IStateView public immutable stateView;
    IV4PoolManager public immutable poolManager;
    address internal immutable usdcToken;

    VaultBook.Book internal _book;
    uint256 public maxSwapSlippageBps;

    event SliceSkipped(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);
    event HarvestSkipped(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);
    event OwedClaimed(address indexed receiver, address indexed token, address to, uint256 amount);
    event MaxSwapSlippageBpsSet(uint256 value);
    event TokenSurplusSwept(address indexed token, address indexed to, uint256 surplus);
    // Library events and errors, re-declared so indexers and clients can decode them from
    // the vault's ABI.
    event PositionOpened(
        VaultBook.Protocol indexed protocol, uint256 indexed tokenId, bytes32 indexed poolId
    );
    event PositionClosed(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);
    event TokenOwed(address indexed owner, address indexed token, uint256 amount);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event V3PositionOpened(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V3LiquidityWithdrawn(
        uint256 indexed tokenId, uint128 liquidity, address recipient, uint256 amount0, uint256 amount1
    );
    event V3FeesCollected(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);
    event V3PositionClosed(uint256 indexed tokenId);
    event V4PositionOpened(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V4LiquidityWithdrawn(
        uint256 indexed tokenId, uint128 liquidity, address recipient, uint256 amount0, uint256 amount1
    );
    event V4FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event V4PositionClosed(uint256 indexed tokenId);

    error PoolNotUsable(bytes32 poolId);
    error HookedPoolNotAllowed(bytes32 poolId);
    error TooManyPositions();
    error TooManyRanges(bytes32 poolId);
    error WidthOutOfBounds(int24 width);
    error PoolTooThin(uint128 liquidity, uint128 minLiquidity);
    error AllocationExceeded(uint256 value, uint256 limit);
    error InsufficientInventory(address token, uint256 needed, uint256 available);
    error MinOutTooLow(uint256 minOut, uint256 floor);
    error TooManyTokens();
    error UnknownPosition(VaultBook.Protocol protocol, uint256 tokenId);
    error OnlySelf();
    error UnboundSlice();
    error ExitInProgress();
    error InsufficientGas();
    error InvalidReceiver();
    error OnlyPoolManager();
    // Adapter and swap library errors.
    error Slippage(uint256 spent0, uint256 spent1);
    error PositionNotEmpty(uint256 tokenId);
    error InvalidSlice();
    error InvalidRecipient();
    error NativeCurrencyNotSupported();
    error PoolNotInitialized();
    error ZeroLiquidity();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error UnexpectedCallback();

    constructor(Config memory c)
        AsyncBatchVault(
            c.usdc,
            c.name,
            c.symbol,
            c.admin,
            c.keeper,
            c.guardian,
            c.minDeposit,
            c.maxTotalAssets,
            c.maxCycleMoveBps
        )
    {
        if (
            address(c.registry) == address(0) || address(c.npm) == address(0)
                || address(c.swapRouter02) == address(0) || address(c.posm) == address(0)
                || address(c.stateView) == address(0) || c.registry.usdc() != address(c.usdc)
        ) revert ZeroAddress();
        registry = c.registry;
        npm = c.npm;
        swapRouter02 = c.swapRouter02;
        posm = c.posm;
        permit2 = IPermit2(c.posm.permit2());
        poolManager = IV4PoolManager(c.posm.poolManager());
        stateView = c.stateView;
        usdcToken = address(c.usdc);
        _setMaxSwapSlippageBps(c.maxSwapSlippageBps);
    }

    // ---------------------------------------------------------------------
    // Keeper
    // ---------------------------------------------------------------------

    /// @notice Open one range position in a registry-usable, hookless pool from idle USDC
    /// and token inventory, within the pool's class limits.
    function openPosition(VaultOps.OpenArgs calldata p)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
        returns (uint256 tokenId)
    {
        uint256 usdcSpent;
        VaultOps.Exposure memory x;
        (tokenId, usdcSpent, x) = VaultOps.open(_book, _env(), p, idleAssets);
        _decreaseIdle(usdcSpent);
        VaultBook.checkAllocation(_book, _env(), p.poolId, x.cls, x.params, totalAssets());
    }

    /// @notice Remove `liquidity` from a position into the vault (v4 also harvests fees).
    /// Allowed while paused: it only reduces risk.
    function withdrawPosition(VaultBook.Protocol protocol, VaultOps.Removal calldata r)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        _increaseIdle(VaultOps.withdraw(_book, _env(), protocol, r));
    }

    /// @notice Collect a position's fees into the vault.
    function collectPositionFees(VaultBook.Protocol protocol, uint256 tokenId)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        _increaseIdle(VaultOps.harvest(_book, _env(), protocol, tokenId));
    }

    /// @notice Burn an empty position (v3: its fees must have been collected).
    function closePosition(VaultBook.Protocol protocol, uint256 tokenId)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        VaultOps.close(_book, _env(), protocol, tokenId);
    }

    /// @notice Exact-input swap between USDC and a pool's token, in that pool. `minOut`
    /// must be at least the amount at the pool's current price minus maxSwapSlippageBps,
    /// which bounds price impact; the keeper's own `minOut` (from an off-chain fair price)
    /// is the protection against a manipulated pool price. USDC -> token is blocked while
    /// paused and must respect the class limits; token -> USDC is always allowed.
    function swap(bytes32 poolId, bool usdcIn, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 out)
    {
        if (usdcIn) _requireNotPaused();
        uint256 paid;
        VaultOps.Exposure memory x;
        (paid, out, x) = VaultOps.swap(
            _book, _env(), VaultOps.SwapArgs(poolId, usdcIn, amountIn, minOut, maxSwapSlippageBps), idleAssets
        );
        if (usdcIn) {
            _decreaseIdle(paid);
            VaultBook.checkAllocation(_book, _env(), poolId, x.cls, x.params, totalAssets());
        } else {
            _increaseIdle(out);
        }
    }

    /// @notice PoolManager callback for v4 swaps (only while `VaultSwaps.swapV4` waits).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        return VaultSwaps.onUnlock(poolManager, data);
    }

    // ---------------------------------------------------------------------
    // IOUs
    // ---------------------------------------------------------------------

    /// @notice Claim tokens owed to you (the holder who exited in kind) because your
    /// receiver could not take them, to any address.
    function claimOwed(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert InvalidReceiver();
        amount = _book.owed[msg.sender][token];
        _book.owed[msg.sender][token] = 0;
        _book.owedTotal[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit OwedClaimed(msg.sender, token, to, amount);
    }

    /// @notice Send out non-USDC tokens the vault holds beyond its books (donations, rounding
    /// dust): balance - inventory - IOUs. USDC surplus goes through `sweepSurplus`.
    function sweepTokenSurplus(address token, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 surplus)
    {
        // Not USDC (sweepSurplus), and never the vault's own shares (escrowed requests).
        if (token == usdcToken || token == address(this) || to == address(0)) revert ZeroAddress();
        surplus = IERC20(token).balanceOf(address(this)) - _book.tokenBalance[token] - _book.owedTotal[token];
        IERC20(token).safeTransfer(to, surplus);
        emit TokenSurplusSwept(token, to, surplus);
    }

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------

    function setMaxSwapSlippageBps(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxSwapSlippageBps(value);
    }

    /// @notice Guardian may only tighten the swap slippage bound, instantly.
    function lowerMaxSwapSlippageBps(uint256 value) external onlyRole(GUARDIAN_ROLE) {
        if (value >= maxSwapSlippageBps) revert NotLower();
        _setMaxSwapSlippageBps(value);
    }

    function _setMaxSwapSlippageBps(uint256 value) private {
        if (value > MAX_SWAP_SLIPPAGE_BPS_CAP) revert ParamOutOfBounds();
        maxSwapSlippageBps = value;
        emit MaxSwapSlippageBpsSet(value);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function positionCount() public view returns (uint256 v3Count, uint256 v4Count) {
        return (V3Positions.count(_book.v3), V4Positions.count(_book.v4));
    }

    function positionAt(VaultBook.Protocol protocol, uint256 i) public view returns (uint256) {
        return protocol == VaultBook.Protocol.V3
            ? V3Positions.tokenIdAt(_book.v3, i)
            : V4Positions.tokenIdAt(_book.v4, i);
    }

    /// @notice Registry pool id of an open position (zero if unknown).
    function positionPool(VaultBook.Protocol protocol, uint256 tokenId) external view returns (bytes32) {
        return _book.positionPool[protocol][tokenId];
    }

    /// @notice USDC value of one position's principal at its pool's current price.
    function positionValue(VaultBook.Protocol protocol, uint256 tokenId) external view returns (uint256) {
        return VaultBook.positionValue(_book, _env(), protocol, tokenId);
    }

    function inventoryTokens() external view returns (address[] memory) {
        return _book.tokens;
    }

    /// @notice Non-USDC tokens held as part of NAV (from withdrawals, fees, swaps).
    function tokenBalance(address token) external view returns (uint256) {
        return _book.tokenBalance[token];
    }

    /// @notice Pool used to price an inventory token.
    function tokenPool(address token) external view returns (bytes32) {
        return _book.tokenPool[token];
    }

    /// @notice In-kind exit IOU of `receiver` in `token` (not part of NAV).
    function owed(address receiver, address token) external view returns (uint256) {
        return _book.owed[receiver][token];
    }

    function owedTotal(address token) external view returns (uint256) {
        return _book.owedTotal[token];
    }

    // ---------------------------------------------------------------------
    // AsyncBatchVault hooks
    // ---------------------------------------------------------------------

    /// @dev Positions' principal + token inventory, at each pool's current price.
    /// Unharvested fees are excluded (settlement harvests first). The spot price is
    /// manipulable within a block; settlement's maxCycleMoveBps guard bounds the effect.
    function _deployedValue() internal view override returns (uint256) {
        return VaultBook.deployedValue(_book, _env());
    }

    /// @dev Settlement never swaps: the keeper unwinds into idle USDC beforehand, and the
    /// batch reverts (InsufficientIdle) if it did not.
    function _ensureIdle(uint256) internal override {}

    /// @dev Harvest every position's fees before NAV is computed. Each harvest runs in a
    /// gas-capped self-call, so a frozen or hostile token can only skip its own harvest.
    function _beforeSettle() internal override {
        HARVESTING.asBoolean().tstore(true);
        (uint256 n3, uint256 n4) = positionCount();
        for (uint256 i = 0; i < n3 + n4; i++) {
            VaultBook.Protocol protocol = i < n3 ? VaultBook.Protocol.V3 : VaultBook.Protocol.V4;
            uint256 tokenId = positionAt(protocol, i < n3 ? i : i - n3);
            _requireGas(HARVEST_GAS);
            try this.harvestFor{gas: HARVEST_GAS}(protocol, tokenId) {}
            catch {
                emit HarvestSkipped(protocol, tokenId);
            }
        }
        HARVESTING.asBoolean().tstore(false);
    }

    /// @notice Self-call target of the settlement harvest only.
    function harvestFor(VaultBook.Protocol protocol, uint256 tokenId) external {
        if (msg.sender != address(this) || !HARVESTING.asBoolean().tload()) revert OnlySelf();
        _increaseIdle(VaultOps.harvest(_book, _env(), protocol, tokenId));
    }

    /// @dev USDC owed to exited holders is neither NAV nor surplus.
    function _reservedAssets() internal view override returns (uint256) {
        return _book.owedTotal[usdcToken];
    }

    // ---------------------------------------------------------------------
    // In-kind exit
    // ---------------------------------------------------------------------

    /// @notice One in-kind exit: `shares` of `supply` (before the burn), paid to `receiver`,
    /// IOUs owed to `owner` (the holder whose shares were burned).
    struct Exit {
        uint256 shares;
        uint256 supply;
        address receiver;
        address owner;
    }

    /// @dev Per position and per inventory token: deliver the slice to `receiver`; if that
    /// failed cheaply, take it into the vault and record an IOU for the owner; if even that
    /// fails (or the first attempt burned its gas), leave it to the remaining holders.
    /// Bookkeeping runs inside the gas-capped self-call frames and every credit is capped by
    /// Uniswap's math, so a hostile token can only affect its own slice.
    function _redeemPositionsInKind(uint256 shares, uint256 supply, address receiver) internal override {
        _checkReceiver(receiver);
        if (_exitBinding() != bytes32(0)) revert ExitInProgress();
        // AsyncBatchVault.redeemInKind burned the shares from msg.sender: IOUs go to them,
        // not to a receiver that may be unable to claim.
        Exit memory x = Exit(shares, supply, receiver, msg.sender);
        EXIT_BINDING.asBytes32().tstore(keccak256(abi.encode(x)));
        (uint256 n3, uint256 n4) = positionCount();
        for (uint256 i = 0; i < n3 + n4; i++) {
            VaultBook.Protocol protocol = i < n3 ? VaultBook.Protocol.V3 : VaultBook.Protocol.V4;
            _exitPosition(protocol, positionAt(protocol, i < n3 ? i : i - n3), x);
        }
        uint256 nt = _book.tokens.length;
        for (uint256 i = 0; i < nt; i++) {
            _exitToken(_book.tokens[i], x);
        }
        EXIT_BINDING.asBytes32().tstore(bytes32(0));
    }

    function _exitPosition(VaultBook.Protocol protocol, uint256 tokenId, Exit memory x) private {
        _requireGas(SLICE_GAS);
        uint256 gasBefore = gasleft();
        try this.exitSlice{gas: SLICE_GAS}(protocol, tokenId, x, x.receiver) {
            return;
        } catch {}
        if (gasBefore - gasleft() > SLICE_GAS * FALLBACK_MAX_BPS / BPS) {
            emit SliceSkipped(protocol, tokenId);
            return;
        }
        _requireGas(SLICE_GAS);
        try this.exitSlice{gas: SLICE_GAS}(protocol, tokenId, x, address(this)) {}
        catch {
            emit SliceSkipped(protocol, tokenId);
        }
    }

    /// @dev Inventory share: debited first; if the transfer fails it is owed instead (the
    /// tokens never left, so the IOU is exact).
    function _exitToken(address token, Exit memory x) private {
        uint256 amount = Math.mulDiv(_book.tokenBalance[token], x.shares, x.supply);
        if (amount == 0) return;
        _book.tokenBalance[token] -= amount;
        _requireGas(TOKEN_GAS);
        try this.exitTransfer{gas: TOKEN_GAS}(token, amount, x) {}
        catch {
            VaultOps.recordOwed(_book, x.owner, token, amount);
        }
    }

    /// @notice Self-call target of the in-kind exit: one position's slice. Bound to the
    /// exit in progress; pays the receiver or, as the fallback, the vault (recording an IOU
    /// for the owner).
    function exitSlice(VaultBook.Protocol protocol, uint256 tokenId, Exit calldata x, address recipient)
        external
    {
        _requireBound(x);
        if (recipient != x.receiver && recipient != address(this)) revert UnboundSlice();
        _increaseIdle(
            VaultOps.slice(_book, _env(), protocol, tokenId, x.shares, x.supply, x.owner, recipient)
        );
    }

    /// @notice Self-call target of the in-kind exit: one inventory token transfer.
    function exitTransfer(address token, uint256 amount, Exit calldata x) external {
        _requireBound(x);
        IERC20(token).safeTransfer(x.receiver, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _env() private view returns (VaultBook.Env memory) {
        return VaultBook.Env(registry, npm, posm, stateView, permit2, poolManager, swapRouter02, usdcToken);
    }

    /// @dev A receiver that would swallow a slice: the vault (no IOU), the position
    /// managers (anyone can sweep), the PoolManager (stranded), Permit2, or 0..2 (v4
    /// PositionManager aliases).
    function _checkReceiver(address receiver) private view {
        if (
            uint160(receiver) <= 2 || receiver == address(this) || receiver == address(posm)
                || receiver == address(npm) || receiver == address(poolManager)
                || receiver == address(permit2)
        ) revert InvalidReceiver();
    }

    function _requireBound(Exit calldata x) private view {
        if (msg.sender != address(this)) revert OnlySelf();
        if (_exitBinding() != keccak256(abi.encode(x))) revert UnboundSlice();
    }

    function _exitBinding() private view returns (bytes32) {
        return EXIT_BINDING.asBytes32().tload();
    }

    /// @dev EIP-150: a CALL forwards at most 63/64 of the remaining gas. Revert rather than
    /// let a capped call fail for lack of gas (which would silently skip a slice).
    function _requireGas(uint256 budget) private view {
        if (gasleft() < budget * 64 / 63 + GAS_RESERVE) revert InsufficientGas();
    }
}
