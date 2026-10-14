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
    /// @dev Hard cap on how far the live share price may sit from the keeper's expected price.
    uint256 public constant MAX_SETTLE_TOLERANCE_BPS = 200; // 2%
    /// @dev Hard cap on the minimum time between keeper settlements.
    uint256 public constant MAX_MIN_SETTLE_INTERVAL = 1 hours;
    /// @dev Fee hard caps: performance fee on gains above the high-water mark, and the
    /// yearly management fee.
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 3_000; // 30%
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 200; // 2% / year
    /// @dev Bounds of the performance-fee period.
    uint256 public constant MIN_FEE_PERIOD = 1 days;
    uint256 public constant MAX_FEE_PERIOD = 90 days;
    /// @dev How long a batch lock lasts at most, and how long a batch must have been open
    /// before the keeper may lock it.
    uint256 public constant BATCH_LOCK = 15 minutes;
    uint256 internal constant YEAR = 365 days;

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

    /// @notice USDC that is part of NAV and not deployed. Tracked internally (never read
    /// from balanceOf), so donations cannot move the share price; see sweepSurplus.
    uint256 public idleAssets;
    /// @notice USDC held for the open batch's deposit requests — not yet part of NAV.
    uint256 public pendingDepositAssets;
    /// @notice USDC owed to settled-but-unclaimed redemptions — no longer part of NAV.
    uint256 public claimableAssets;

    uint256 public minDeposit;
    uint256 public maxTotalAssets;
    uint256 public maxCycleMoveBps;
    /// @notice Share price (assets per 10**decimals() shares) at the last settlement; 0 before the first.
    uint256 public lastSharePrice;
    /// @notice The keeper's `settle(expectedPrice)` reverts unless the live share price is
    /// within this many bps of `expectedPrice`.
    uint256 public settleToleranceBps = 50;
    /// @notice Minimum seconds between two keeper settlements, so a compromised keeper can't
    /// walk `lastSharePrice` by maxCycleMoveBps many times in quick succession.
    uint256 public minSettleInterval = 60;
    /// @notice Timestamp of the last settlement (0 before the first).
    uint256 public lastSettleTime;
    /// @notice Receives fees, as newly minted shares, at each settlement.
    address public treasury;
    /// @notice Share of share-price gains above the high-water mark taken as a fee.
    uint256 public performanceFeeBps = 1_500;
    /// @notice Yearly management fee, accrued per second between settlements.
    uint256 public managementFeeBps;
    /// @notice Post-fee share price up to which gains have been charged (0 before the first
    /// settlement). Moves only when a fee period closes above it, or when the vault empties.
    uint256 public highWaterMark;
    /// @notice The performance fee is charged at most once per period, at the first
    /// settlement after it ends, on the period's LOWEST settlement price above the mark: only
    /// a gain that held through the whole period is charged, so a short spike never is.
    uint256 public feePeriod = 7 days;
    /// @notice When the current fee period started.
    uint256 public feePeriodStart;
    /// @notice Lowest share price (after the management fee) at a settlement in the current
    /// fee period; 0 before its first.
    uint256 public feePeriodLow;
    /// @notice When fees were last accrued (0 before the first settlement).
    uint256 public lastFeeAccrual;
    /// @notice Until then, the open batch is locked: no redeem requests and no
    /// cancellations, so the batch the keeper sized its idle USDC for is the one it settles.
    uint256 public batchLockedUntil;
    /// @notice The last batch the keeper locked (each batch can be locked once).
    uint256 public lastLockedBatch;
    /// @notice ERC-7540 operators: `operator` may cancel and claim on behalf of `controller`
    /// (and choose the receiver), so approving one is full trust over those requests.
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    event DepositRequested(address indexed user, uint256 indexed batchId, uint256 assets);
    event DepositRequestCancelled(
        address indexed controller,
        uint256 indexed batchId,
        address operator,
        address receiver,
        uint256 assets
    );
    event RedeemRequested(address indexed user, uint256 indexed batchId, uint256 shares);
    event RedeemRequestCancelled(
        address indexed controller,
        uint256 indexed batchId,
        address operator,
        address receiver,
        uint256 shares
    );
    event BatchLocked(uint256 indexed batchId, uint256 until);
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
    event SettleToleranceBpsSet(uint256 value);
    event MinSettleIntervalSet(uint256 value);
    event FeesSet(uint256 performanceFeeBps, uint256 managementFeeBps);
    event TreasurySet(address treasury);
    event FeePeriodSet(uint256 value);
    event ManagementFeeAccrued(uint256 shares);
    event FeePeriodClosed(uint256 performanceShares, uint256 periodLow, uint256 highWaterMark);
    event SurplusSwept(address indexed to, uint256 surplus);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

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
    error PriceNotAsExpected(uint256 expectedPrice, uint256 livePrice);
    error SharesToVaultNotAllowed();
    error NotOperator(address controller, address caller);
    error InvalidOperator();
    error SettledTooRecently(uint256 nextAllowed);
    error BatchIsLocked(uint256 until);
    error CannotLock();

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
        treasury = admin;
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
        return idleAssets + _deployedValue();
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

    /// @notice Withdraw your whole deposit request from the open (unsettled) batch. Not
    /// while the batch is locked (see lockBatch).
    function cancelDepositRequest() external nonReentrant {
        _cancelDeposit(msg.sender, msg.sender);
    }

    /// @notice Operator version: cancel `controller`'s open deposit request, refunding to `receiver`.
    function cancelDepositRequestFor(address controller, address receiver) external nonReentrant {
        _requireOperator(controller);
        _cancelDeposit(controller, receiver);
    }

    function _cancelDeposit(address controller, address receiver) private {
        _checkUsdcReceiver(receiver);
        _requireUnlocked();
        uint256 id = currentBatchId;
        uint256 assets = depositRequestOf[id][controller];
        if (assets == 0) revert NothingToCancel();
        depositRequestOf[id][controller] = 0;
        batches[id].depositAssets -= assets.toUint128();
        pendingDepositAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit DepositRequestCancelled(controller, id, msg.sender, receiver, assets);
    }

    function requestRedeem(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroAmount();
        _requireUnlocked();
        uint256 id = currentBatchId;
        // Escrow until settlement. Calls ERC20._update directly: the vault's own
        // escrow is the only path allowed to move shares into the vault (see _update).
        ERC20._update(msg.sender, address(this), shares);
        redeemRequestOf[id][msg.sender] += shares;
        batches[id].redeemShares += shares.toUint128();
        emit RedeemRequested(msg.sender, id, shares);
    }

    /// @notice Take back your whole redeem request from the open (unsettled) batch. Not
    /// while the batch is locked (see lockBatch).
    function cancelRedeemRequest() external nonReentrant {
        _cancelRedeem(msg.sender, msg.sender);
    }

    /// @notice Operator version: cancel `controller`'s open redeem request, returning the
    /// escrowed shares to `receiver`.
    function cancelRedeemRequestFor(address controller, address receiver) external nonReentrant {
        _requireOperator(controller);
        _cancelRedeem(controller, receiver);
    }

    function _cancelRedeem(address controller, address receiver) private {
        _requireUnlocked();
        uint256 id = currentBatchId;
        uint256 shares = redeemRequestOf[id][controller];
        if (shares == 0) revert NothingToCancel();
        redeemRequestOf[id][controller] = 0;
        batches[id].redeemShares -= shares.toUint128();
        _transfer(address(this), receiver, shares);
        emit RedeemRequestCancelled(controller, id, msg.sender, receiver, shares);
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Settle the open batch at the current share price. Reverts unless the live
    /// price is within settleToleranceBps of `expectedPrice` (the keeper's off-chain fair
    /// price: NAV from fair token prices, including LP fees about to be harvested, and
    /// BEFORE this settlement's performance/management fees are minted), so a
    /// sandwich that moves pool prices around this call makes it revert instead of settling
    /// at a manipulated NAV. Also reverts if the price moved more than maxCycleMoveBps since
    /// the last settlement (skipped on the first settlement and whenever the supply is zero).
    /// @dev Unless the keeper locked the batch first (lockBatch), requests in it can be
    /// cancelled, and redeem requests added, until this lands.
    function settle(uint256 expectedPrice) external onlyRole(KEEPER_ROLE) {
        if (expectedPrice == 0) revert ParamOutOfBounds();
        uint256 next = lastSettleTime + minSettleInterval;
        if (lastSettleTime != 0 && block.timestamp < next) revert SettledTooRecently(next);
        _settle(false, expectedPrice, settleToleranceBps);
    }

    /// @notice Settle even though the price moved more than maxCycleMoveBps — for a
    /// genuine market move (e.g. a crash) the guardian has reviewed. Bounded: reverts
    /// unless the live price is within `toleranceBps` of the `expectedPrice` the guardian
    /// reviewed, so the override cannot accept whatever price exists when the tx lands.
    function settleAcceptingPriceMove(uint256 expectedPrice, uint256 toleranceBps)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        if (expectedPrice == 0 || toleranceBps > maxCycleMoveBps || toleranceBps > MAX_SETTLE_TOLERANCE_BPS) {
            revert ParamOutOfBounds();
        }
        _settle(true, expectedPrice, toleranceBps);
    }

    /// @notice Keeper: lock the open batch before settling it, for at most BATCH_LOCK, so a
    /// last-moment redeem request or cancellation cannot change what it settles (a redeem
    /// request after the keeper freed idle USDC would make settlement revert). Each batch
    /// can be locked once, and only after it has been open for BATCH_LOCK, so requests are
    /// always possible for at least that long per batch. Deposit requests and in-kind exits
    /// stay open.
    function lockBatch() external onlyRole(KEEPER_ROLE) whenNotPaused {
        uint256 id = currentBatchId;
        if (lastLockedBatch == id || block.timestamp < lastSettleTime + BATCH_LOCK) revert CannotLock();
        lastLockedBatch = id;
        uint256 until = block.timestamp + BATCH_LOCK;
        batchLockedUntil = until;
        emit BatchLocked(id, until);
    }

    function _requireUnlocked() private view {
        uint256 until = batchLockedUntil;
        if (block.timestamp < until) revert BatchIsLocked(until);
    }

    function _settle(bool guardianOverride, uint256 expectedPrice, uint256 toleranceBps)
        private
        nonReentrant
        whenNotPaused
    {
        _beforeSettle();

        uint256 id = currentBatchId;
        Batch storage b = batches[id];

        uint256 price = _sharePrice();
        uint256 diff = price > expectedPrice ? price - expectedPrice : expectedPrice - price;
        if (diff * BPS > expectedPrice * toleranceBps) revert PriceNotAsExpected(expectedPrice, price);
        if (!guardianOverride) {
            uint256 last = lastSharePrice;
            // No guard on the first settlement, nor once the vault has emptied (supply 0):
            // the last price no longer describes any outstanding shares.
            if (last != 0 && totalSupply() != 0) {
                uint256 move = price > last ? price - last : last - price;
                if (move * BPS > last * maxCycleMoveBps) revert PriceMoveTooLarge(last, price);
            }
        }
        // The guards check the pre-fee price; the batch converts at the post-fee price.
        price = _accrueFees();

        // Both sides convert at the same pre-batch NAV / supply, i.e. one price.
        uint256 depositShares = _convertToShares(b.depositAssets, Math.Rounding.Floor);
        uint256 redeemAssets = _convertToAssets(b.redeemShares, Math.Rounding.Floor);

        // Deposits join NAV; their shares wait in the vault until claimed.
        pendingDepositAssets -= b.depositAssets;
        idleAssets += b.depositAssets;
        if (depositShares > 0) _mint(address(this), depositShares);

        if (b.redeemShares > 0) {
            _ensureIdle(redeemAssets);
            uint256 idle = idleAssets;
            if (redeemAssets > idle) revert InsufficientIdle(redeemAssets, idle);
            idleAssets = idle - redeemAssets;
            _burn(address(this), b.redeemShares);
            claimableAssets += redeemAssets;
        }

        b.depositShares = depositShares.toUint128();
        b.redeemAssets = redeemAssets.toUint128();
        b.settled = true;
        lastSharePrice = price;
        lastSettleTime = block.timestamp;
        batchLockedUntil = 0;
        currentBatchId = id + 1;

        emit BatchSettled(id, price, b.depositAssets, depositShares, b.redeemShares, redeemAssets);
    }

    // ---------------------------------------------------------------------
    // Claims (always available, even when paused)
    // ---------------------------------------------------------------------

    function claimDeposit(uint256 batchId, address receiver) external nonReentrant returns (uint256) {
        return _claimDeposit(batchId, msg.sender, receiver);
    }

    /// @notice Operator version: claim `controller`'s deposit shares to `receiver`.
    function claimDepositFor(uint256 batchId, address controller, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        _requireOperator(controller);
        return _claimDeposit(batchId, controller, receiver);
    }

    function claimRedeem(uint256 batchId, address receiver) external nonReentrant returns (uint256) {
        return _claimRedeem(batchId, msg.sender, receiver);
    }

    /// @notice Operator version: claim `controller`'s redemption USDC to `receiver`.
    function claimRedeemFor(uint256 batchId, address controller, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        _requireOperator(controller);
        return _claimRedeem(batchId, controller, receiver);
    }

    function _claimDeposit(uint256 batchId, address controller, address receiver)
        private
        returns (uint256 shares)
    {
        Batch storage b = batches[batchId];
        if (!b.settled) revert BatchNotSettled(batchId);
        uint256 assets = depositRequestOf[batchId][controller];
        if (assets == 0) revert NothingToClaim();
        depositRequestOf[batchId][controller] = 0;
        shares = assets.mulDiv(b.depositShares, b.depositAssets, Math.Rounding.Floor);
        _transfer(address(this), receiver, shares);
        emit DepositClaimed(controller, batchId, receiver, shares);
    }

    function _claimRedeem(uint256 batchId, address controller, address receiver)
        private
        returns (uint256 assets)
    {
        _checkUsdcReceiver(receiver);
        Batch storage b = batches[batchId];
        if (!b.settled) revert BatchNotSettled(batchId);
        uint256 shares = redeemRequestOf[batchId][controller];
        if (shares == 0) revert NothingToClaim();
        redeemRequestOf[batchId][controller] = 0;
        assets = shares.mulDiv(b.redeemAssets, b.redeemShares, Math.Rounding.Floor);
        claimableAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit RedeemClaimed(controller, batchId, receiver, assets);
    }

    // ---------------------------------------------------------------------
    // Operators (ERC-7540)
    // ---------------------------------------------------------------------

    /// @notice Approve or revoke `operator` to cancel and claim your requests, to any receiver.
    function setOperator(address operator, bool approved) external returns (bool) {
        if (operator == msg.sender || operator == address(0)) revert InvalidOperator();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @dev USDC paid to the vault itself would turn into sweepable surplus.
    function _checkUsdcReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert ZeroAddress();
    }

    function _requireOperator(address controller) private view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) {
            revert NotOperator(controller, msg.sender);
        }
    }

    // ---------------------------------------------------------------------
    // Instant in-kind exit (always available, even when paused)
    // ---------------------------------------------------------------------

    /// @notice Burn `shares` and receive the same fraction of everything the vault
    /// holds: idle USDC now, plus each position's share via the subclass hook.
    /// Needs no price, so there is nothing to manipulate.
    /// @dev Read-only reentrancy: while `_redeemPositionsInKind` makes its external calls,
    /// shares are already burned and idle reduced but positions not yet transferred, so
    /// views (`totalAssets`, `sharePrice`) can read high. Integrators must not price off
    /// this vault mid-call.
    function redeemInKind(uint256 shares, address receiver) external nonReentrant returns (uint256 idleOut) {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        idleOut = idleAssets.mulDiv(shares, supply, Math.Rounding.Floor);
        idleAssets -= idleOut;
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

    function setSettleToleranceBps(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value == 0 || value > MAX_SETTLE_TOLERANCE_BPS) revert ParamOutOfBounds();
        settleToleranceBps = value;
        emit SettleToleranceBpsSet(value);
    }

    /// @notice Admin (timelocked): set the fees within their hard caps. The management fee
    /// owed so far is accrued at the old rate first; the new rate applies from now.
    function setFees(uint256 performanceBps, uint256 managementBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (performanceBps > MAX_PERFORMANCE_FEE_BPS || managementBps > MAX_MANAGEMENT_FEE_BPS) {
            revert ParamOutOfBounds();
        }
        _setFees(performanceBps, managementBps);
    }

    /// @notice Guardian may only lower fees, instantly.
    function lowerFees(uint256 performanceBps, uint256 managementBps) external onlyRole(GUARDIAN_ROLE) {
        if (performanceBps > performanceFeeBps || managementBps > managementFeeBps) revert NotLower();
        _setFees(performanceBps, managementBps);
    }

    /// @notice Admin (timelocked): the performance-fee period. Applies from the current
    /// period's next close.
    function setFeePeriod(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value < MIN_FEE_PERIOD || value > MAX_FEE_PERIOD) revert ParamOutOfBounds();
        feePeriod = value;
        emit FeePeriodSet(value);
    }

    function setTreasury(address value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value == address(0) || value == address(this)) revert ZeroAddress();
        treasury = value;
        emit TreasurySet(value);
    }

    function setMinSettleInterval(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value > MAX_MIN_SETTLE_INTERVAL) revert ParamOutOfBounds();
        minSettleInterval = value;
        emit MinSettleIntervalSet(value);
    }

    /// @notice Guardian may only tighten the keeper's settle tolerance, instantly.
    function lowerSettleToleranceBps(uint256 value) external onlyRole(GUARDIAN_ROLE) {
        if (value >= settleToleranceBps || value == 0) revert NotLower();
        settleToleranceBps = value;
        emit SettleToleranceBpsSet(value);
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

    /// @notice Admin-only (timelocked), so a guardian pause halts requests and settlement
    /// for at least the timelock delay. Claims, cancels and in-kind exits stay open.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Send out USDC the vault holds beyond its accounting (donations, stray
    /// transfers): balance − idleAssets − pendingDepositAssets − claimableAssets − USDC the
    /// subclass holds for others (`_reservedAssets`, e.g. in-kind exit IOUs).
    function sweepSurplus(address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 surplus)
    {
        if (to == address(0)) revert ZeroAddress();
        surplus = IERC20(asset()).balanceOf(address(this)) - idleAssets - pendingDepositAssets
            - claimableAssets - _reservedAssets();
        IERC20(asset()).safeTransfer(to, surplus);
        emit SurplusSwept(to, surplus);
    }

    function _setFees(uint256 performanceBps, uint256 managementBps) private {
        _accrueManagementFee();
        (performanceFeeBps, managementFeeBps) = (performanceBps, managementBps);
        emit FeesSet(performanceBps, managementBps);
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

    /// @dev Mint fee shares to the treasury and return the post-fee share price. The
    /// management fee accrues every settlement. The performance fee is charged only when the
    /// fee period has ended, on the gain of the period's lowest settlement price above the
    /// high-water mark; the mark then becomes that low in post-fee terms, so any gain above
    /// it is charged in a later period only if it holds. The first settlement, and the first
    /// after the vault empties, only sets the mark.
    function _accrueFees() private returns (uint256 price) {
        bool fresh = totalSupply() == 0 || highWaterMark == 0;
        _accrueManagementFee();
        price = _sharePrice();
        if (fresh) {
            highWaterMark = price;
            _startFeePeriod();
            return price;
        }
        uint256 low = _periodLow(price);
        if (!_feePeriodOver()) {
            feePeriodLow = low;
            return price;
        }
        uint256 perfShares = _performanceFeeShares(low, totalAssets(), totalSupply());
        if (low > highWaterMark) {
            if (perfShares != 0) _mint(treasury, perfShares);
            uint256 post = _sharePrice();
            // Charged up to `low`; in post-fee terms that level is lower by the fee per share.
            highWaterMark = low - (price - post);
            price = post;
        }
        _startFeePeriod();
        emit FeePeriodClosed(perfShares, low, highWaterMark);
    }

    /// @dev Mint the management fee for the time since the last accrual (dilution of
    /// bps * dt / year) and restart the clock.
    function _accrueManagementFee() private {
        uint256 shares = _managementFeeShares(totalSupply());
        lastFeeAccrual = block.timestamp;
        if (shares != 0) {
            _mint(treasury, shares);
            emit ManagementFeeAccrued(shares);
        }
    }

    function _startFeePeriod() private {
        feePeriodStart = block.timestamp;
        feePeriodLow = 0;
    }

    function _managementFeeShares(uint256 supply) private view returns (uint256) {
        uint256 last = lastFeeAccrual;
        if (supply == 0 || last == 0) return 0;
        uint256 rate = managementFeeBps * (block.timestamp - last); // bps * seconds
        uint256 whole = BPS * YEAR;
        return rate < whole ? supply.mulDiv(rate, whole - rate) : 0;
    }

    /// @dev Shares worth `performanceFeeBps` of the gain from the mark to `low` on every
    /// share, once minted: a / (A - a) of the supply.
    function _performanceFeeShares(uint256 low, uint256 assets, uint256 supply)
        private
        view
        returns (uint256)
    {
        uint256 hwm = highWaterMark;
        if (low <= hwm || performanceFeeBps == 0) return 0;
        uint256 feeAssets = (low - hwm).mulDiv(supply, 10 ** decimals()) * performanceFeeBps / BPS;
        return feeAssets.mulDiv(supply + 10 ** _decimalsOffset(), assets + 1 - feeAssets);
    }

    function _periodLow(uint256 price) private view returns (uint256 low) {
        low = feePeriodLow;
        if (low == 0 || price < low) low = price;
    }

    function _feePeriodOver() private view returns (bool) {
        return block.timestamp >= feePeriodStart + feePeriod;
    }

    /// @notice For the keeper: the share price `settle` checks its expected price against
    /// (pre-fee) and the one the batch converts at (post-fee), from NAV as it stands now.
    /// Settlement harvests LP fees first, so both read higher at settlement by those fees.
    function previewSettlePrice() external view returns (uint256 preFee, uint256 postFee) {
        preFee = _sharePrice();
        uint256 supply = totalSupply();
        if (supply == 0 || highWaterMark == 0) return (preFee, preFee);
        uint256 assets = totalAssets();
        supply += _managementFeeShares(supply);
        postFee = _priceAt(assets, supply);
        if (_feePeriodOver()) {
            supply += _performanceFeeShares(_periodLow(postFee), assets, supply);
            postFee = _priceAt(assets, supply);
        }
    }

    /// @notice Assets per 10**decimals() shares, at the current NAV.
    function sharePrice() external view returns (uint256) {
        return _sharePrice();
    }

    function _sharePrice() internal view returns (uint256) {
        return _convertToAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    /// @dev `_sharePrice` at a given NAV and supply (same virtual offset and rounding).
    function _priceAt(uint256 assets, uint256 supply) private view returns (uint256) {
        return (10 ** decimals()).mulDiv(assets + 1, supply + 10 ** _decimalsOffset());
    }

    /// @dev Credit USDC that became idle through vault accounting (positions unwound,
    /// fees collected into USDC). The USDC must already be held by the vault.
    function _increaseIdle(uint256 assets) internal {
        idleAssets += assets;
    }

    /// @dev Debit idle USDC leaving NAV-idle (e.g. deployed into LP). Subclasses must
    /// route every such outflow through here.
    function _decreaseIdle(uint256 assets) internal {
        uint256 idle = idleAssets;
        if (assets > idle) revert InsufficientIdle(assets, idle);
        idleAssets = idle - assets;
    }

    /// @dev Shares may only enter the vault through its own paths: minting at settlement
    /// (`from == 0`) and the requestRedeem escrow (which calls ERC20._update directly).
    /// Any other transfer to the vault would orphan the shares forever.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this) && from != address(0)) revert SharesToVaultNotAllowed();
        super._update(from, to, value);
    }

    // ---------------------------------------------------------------------
    // Subclass hooks (LP positions, fees)
    // ---------------------------------------------------------------------

    /// @dev USDC value of everything deployed outside the idle balance (LP positions, token inventory).
    function _deployedValue() internal view virtual returns (uint256);

    /// @dev Make at least `assets` idle USDC available (unwind positions, crediting the
    /// proceeds via `_increaseIdle`). Called before paying redemptions. If it does not free
    /// enough idle the whole batch reverts, so adapters must always be able to fully unwind.
    function _ensureIdle(uint256 assets) internal virtual;

    /// @dev Transfer `shares / supply` of every deployed position to `receiver`.
    /// `supply` is the total supply BEFORE `shares` were burned.
    function _redeemPositionsInKind(uint256 shares, uint256 supply, address receiver) internal virtual;

    /// @dev Runs at the start of every settlement (fee accrual goes here).
    function _beforeSettle() internal virtual;

    /// @dev USDC held by the vault that belongs to neither NAV nor the request queues
    /// (e.g. in-kind exit IOUs). Excluded from `sweepSurplus`.
    function _reservedAssets() internal view virtual returns (uint256) {
        return 0;
    }
}
