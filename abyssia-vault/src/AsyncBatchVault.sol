// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AsyncBatchVault
/// @notice ERC-4626 share token over a 6-decimal USDC asset, with ERC-7540-style
/// batched settlement: users queue deposit/redeem requests, a keeper settles the
/// whole batch at one checked share price, then users claim. Settlement is O(1)
/// in the number of users. An instant pro-rata in-kind exit is always available.
/// @dev Abstract: LP-position logic plugs in through the internal hooks at the bottom.
abstract contract AsyncBatchVault is ERC4626, AccessControl, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS = 10_000;
    /// @dev Hard caps, in asset base units (6 decimals) / bps. The admin can never exceed these.
    uint256 public constant MAX_MIN_DEPOSIT = 100e6; // 100 USDC
    uint256 public constant MAX_CYCLE_MOVE_BPS_CAP = 5_000; // 50%

    struct Batch {
        uint128 depositAssets; // USDC requested for deposit in this batch
        uint128 depositShares; // shares minted for those deposits at settlement
        uint128 redeemShares; // shares escrowed for redemption in this batch
        uint128 redeemAssets; // USDC owed for those shares at settlement
        bool settled;
    }

    uint256 public currentBatchId = 1;
    mapping(uint256 batchId => Batch) public batches;
    mapping(uint256 batchId => mapping(address user => uint256)) public depositRequestOf;
    mapping(uint256 batchId => mapping(address user => uint256)) public redeemRequestOf;

    /// @notice USDC held for the open batch's deposit requests — not yet part of NAV.
    uint256 public pendingDepositAssets;
    /// @notice USDC owed to settled-but-unclaimed redemptions — no longer part of NAV.
    uint256 public claimableAssets;

    uint256 public minDeposit;
    uint256 public maxTotalAssets;
    uint256 public maxCycleMoveBps;
    /// @notice Share price (assets per 10**decimals() shares) at the last settlement; 0 before the first.
    uint256 public lastSharePrice;

    event DepositRequested(address indexed user, uint256 indexed batchId, uint256 assets);
    event DepositRequestCancelled(address indexed user, uint256 indexed batchId, uint256 assets);
    event RedeemRequested(address indexed user, uint256 indexed batchId, uint256 shares);
    event RedeemRequestCancelled(address indexed user, uint256 indexed batchId, uint256 shares);
    event BatchSettled(
        uint256 indexed batchId,
        uint256 sharePrice,
        uint256 depositAssets,
        uint256 depositShares,
        uint256 redeemShares,
        uint256 redeemAssets
    );
    event DepositClaimed(address indexed user, uint256 indexed batchId, address receiver, uint256 shares);
    event RedeemClaimed(address indexed user, uint256 indexed batchId, address receiver, uint256 assets);
    event RedeemedInKind(address indexed user, address receiver, uint256 shares, uint256 idleAssets);
    event MinDepositSet(uint256 value);
    event MaxTotalAssetsSet(uint256 value);
    event MaxCycleMoveBpsSet(uint256 value);

    error AsyncOnly();
    error AssetNotSixDecimals();
    error ZeroAddress();
    error BelowMinDeposit(uint256 assets, uint256 minDeposit);
    error ExceedsMaxTotalAssets(uint256 wouldBe, uint256 maxTotalAssets);
    error ZeroAmount();
    error NothingToCancel();
    error BatchNotSettled(uint256 batchId);
    error NothingToClaim();
    error PriceMoveTooLarge(uint256 lastSharePrice, uint256 newSharePrice);
    error InsufficientIdle(uint256 needed, uint256 available);
    error ParamOutOfBounds();
    error NotLower();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        address keeper,
        address guardian,
        uint256 minDeposit_,
        uint256 maxTotalAssets_,
        uint256 maxCycleMoveBps_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        if (admin == address(0) || keeper == address(0) || guardian == address(0)) {
            revert ZeroAddress();
        }
        // Arc USDC has a 6-decimal ERC-20 interface and an 18-decimal native
        // representation over the same balance. Refusing anything but 6 decimals
        // stops the vault ever being pointed at the wrong one.
        if (IERC20Metadata(address(asset_)).decimals() != 6) revert AssetNotSixDecimals();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(GUARDIAN_ROLE, guardian);
        _setMinDeposit(minDeposit_);
        _setMaxCycleMoveBps(maxCycleMoveBps_);
        maxTotalAssets = maxTotalAssets_;
        emit MaxTotalAssetsSet(maxTotalAssets_);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 surface
    // ---------------------------------------------------------------------

    /// @dev 6-decimal USDC -> 12-decimal shares (OZ virtual-share inflation defense).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice NAV: idle USDC (excluding open deposit requests and settled-unclaimed
    /// redemptions) plus whatever the subclass has deployed.
    function totalAssets() public view override returns (uint256) {
        return _idleAssets() + _deployedValue();
    }

    // Synchronous ERC-4626 entry points are disabled; use the request/settle/claim flow.
    function deposit(uint256, address) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function previewDeposit(uint256) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function previewMint(uint256) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert AsyncOnly();
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ---------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------

    function requestDeposit(uint256 assets) external nonReentrant whenNotPaused {
        if (assets < minDeposit || assets == 0) revert BelowMinDeposit(assets, minDeposit);
        uint256 wouldBe = totalAssets() + pendingDepositAssets + assets;
        if (wouldBe > maxTotalAssets) revert ExceedsMaxTotalAssets(wouldBe, maxTotalAssets);

        uint256 id = currentBatchId;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        depositRequestOf[id][msg.sender] += assets;
        batches[id].depositAssets += assets.toUint128();
        pendingDepositAssets += assets;
        emit DepositRequested(msg.sender, id, assets);
    }

    /// @notice Withdraw your whole deposit request from the open (unsettled) batch.
    function cancelDepositRequest() external nonReentrant {
        uint256 id = currentBatchId;
        uint256 assets = depositRequestOf[id][msg.sender];
        if (assets == 0) revert NothingToCancel();
        depositRequestOf[id][msg.sender] = 0;
        batches[id].depositAssets -= assets.toUint128();
        pendingDepositAssets -= assets;
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit DepositRequestCancelled(msg.sender, id, assets);
    }

    function requestRedeem(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroAmount();
        uint256 id = currentBatchId;
        _transfer(msg.sender, address(this), shares); // escrow until settlement
        redeemRequestOf[id][msg.sender] += shares;
        batches[id].redeemShares += shares.toUint128();
        emit RedeemRequested(msg.sender, id, shares);
    }

    /// @notice Take back your whole redeem request from the open (unsettled) batch.
    function cancelRedeemRequest() external nonReentrant {
        uint256 id = currentBatchId;
        uint256 shares = redeemRequestOf[id][msg.sender];
        if (shares == 0) revert NothingToCancel();
        redeemRequestOf[id][msg.sender] = 0;
        batches[id].redeemShares -= shares.toUint128();
        _transfer(address(this), msg.sender, shares);
        emit RedeemRequestCancelled(msg.sender, id, shares);
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Settle the open batch at the current share price. Reverts if the price
    /// moved more than maxCycleMoveBps since the last settlement.
    function settle() external onlyRole(KEEPER_ROLE) {
        _settle(false);
    }

    /// @notice Settle even though the price moved more than maxCycleMoveBps — for a
    /// genuine market move (e.g. a crash) the guardian has reviewed.
    function settleAcceptingPriceMove() external onlyRole(GUARDIAN_ROLE) {
        _settle(true);
    }

    function _settle(bool acceptLargeMove) private nonReentrant whenNotPaused {
        _beforeSettle();

        uint256 id = currentBatchId;
        Batch storage b = batches[id];

        uint256 price = _sharePrice();
        uint256 last = lastSharePrice;
        if (last != 0 && !acceptLargeMove) {
            uint256 diff = price > last ? price - last : last - price;
            if (diff * BPS > last * maxCycleMoveBps) revert PriceMoveTooLarge(last, price);
        }

        // Both sides convert at the same pre-batch NAV / supply, i.e. one price.
        uint256 depositShares = _convertToShares(b.depositAssets, Math.Rounding.Floor);
        uint256 redeemAssets = _convertToAssets(b.redeemShares, Math.Rounding.Floor);

        // Deposits join NAV; their shares wait in the vault until claimed.
        pendingDepositAssets -= b.depositAssets;
        if (depositShares > 0) _mint(address(this), depositShares);

        if (b.redeemShares > 0) {
            _ensureIdle(redeemAssets);
            uint256 idle = _idleAssets();
            if (redeemAssets > idle) revert InsufficientIdle(redeemAssets, idle);
            _burn(address(this), b.redeemShares);
            claimableAssets += redeemAssets;
        }

        b.depositShares = depositShares.toUint128();
        b.redeemAssets = redeemAssets.toUint128();
        b.settled = true;
        lastSharePrice = price;
        currentBatchId = id + 1;

        emit BatchSettled(id, price, b.depositAssets, depositShares, b.redeemShares, redeemAssets);
    }

    // ---------------------------------------------------------------------
    // Claims (always available, even when paused)
    // ---------------------------------------------------------------------

    function claimDeposit(uint256 batchId, address receiver) external nonReentrant returns (uint256 shares) {
        Batch storage b = batches[batchId];
        if (!b.settled) revert BatchNotSettled(batchId);
        uint256 assets = depositRequestOf[batchId][msg.sender];
        if (assets == 0) revert NothingToClaim();
        depositRequestOf[batchId][msg.sender] = 0;
        shares = assets.mulDiv(b.depositShares, b.depositAssets, Math.Rounding.Floor);
        _transfer(address(this), receiver, shares);
        emit DepositClaimed(msg.sender, batchId, receiver, shares);
    }

    function claimRedeem(uint256 batchId, address receiver) external nonReentrant returns (uint256 assets) {
        Batch storage b = batches[batchId];
        if (!b.settled) revert BatchNotSettled(batchId);
        uint256 shares = redeemRequestOf[batchId][msg.sender];
        if (shares == 0) revert NothingToClaim();
        redeemRequestOf[batchId][msg.sender] = 0;
        assets = shares.mulDiv(b.redeemAssets, b.redeemShares, Math.Rounding.Floor);
        claimableAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit RedeemClaimed(msg.sender, batchId, receiver, assets);
    }

    // ---------------------------------------------------------------------
    // Instant in-kind exit (always available, even when paused)
    // ---------------------------------------------------------------------

    /// @notice Burn `shares` and receive the same fraction of everything the vault
    /// holds: idle USDC now, plus each position's share via the subclass hook.
    /// Needs no price, so there is nothing to manipulate.
    function redeemInKind(uint256 shares, address receiver) external nonReentrant returns (uint256 idleOut) {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        idleOut = _idleAssets().mulDiv(shares, supply, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        _redeemPositionsInKind(shares, supply, receiver);
        if (idleOut > 0) IERC20(asset()).safeTransfer(receiver, idleOut);
        emit RedeemedInKind(msg.sender, receiver, shares, idleOut);
    }

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------

    /// @dev Admin is expected to be a TimelockController (risk-increasing changes are delayed).
    function setMinDeposit(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinDeposit(value);
    }

    function setMaxTotalAssets(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTotalAssets = value;
        emit MaxTotalAssetsSet(value);
    }

    function setMaxCycleMoveBps(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxCycleMoveBps(value);
    }

    /// @notice Guardian may only tighten the deposit cap, instantly.
    function lowerMaxTotalAssets(uint256 value) external onlyRole(GUARDIAN_ROLE) {
        if (value >= maxTotalAssets) revert NotLower();
        maxTotalAssets = value;
        emit MaxTotalAssetsSet(value);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _setMinDeposit(uint256 value) private {
        if (value > MAX_MIN_DEPOSIT) revert ParamOutOfBounds();
        minDeposit = value;
        emit MinDepositSet(value);
    }

    function _setMaxCycleMoveBps(uint256 value) private {
        if (value == 0 || value > MAX_CYCLE_MOVE_BPS_CAP) revert ParamOutOfBounds();
        maxCycleMoveBps = value;
        emit MaxCycleMoveBpsSet(value);
    }

    // ---------------------------------------------------------------------
    // Views / internals
    // ---------------------------------------------------------------------

    /// @notice Assets per 10**decimals() shares, at the current NAV.
    function sharePrice() external view returns (uint256) {
        return _sharePrice();
    }

    function _sharePrice() internal view returns (uint256) {
        return _convertToAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    function _idleAssets() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - pendingDepositAssets - claimableAssets;
    }

    // ---------------------------------------------------------------------
    // Subclass hooks (LP positions, fees)
    // ---------------------------------------------------------------------

    /// @dev USDC value of everything deployed outside the idle balance (LP positions, token inventory).
    function _deployedValue() internal view virtual returns (uint256);

    /// @dev Make at least `assets` idle USDC available (unwind positions). Called before paying redemptions.
    function _ensureIdle(uint256 assets) internal virtual;

    /// @dev Transfer `shares / supply` of every deployed position to `receiver`.
    function _redeemPositionsInKind(uint256 shares, uint256 supply, address receiver) internal virtual;

    /// @dev Runs at the start of every settlement (fee accrual goes here).
    function _beforeSettle() internal virtual;
}
