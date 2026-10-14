// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AbyssiaVaultFactory
/// @notice Deploys Abyssia vaults (CREATE2) and keeps the list of official ones, so
/// integrators can tell an official vault from a look-alike. Each deployment must match an
/// init hash the admin (the timelock) approved: keccak256 of the creation code AND its
/// constructor arguments, so the approval fixes the vault's code, roles, registry and
/// Uniswap addresses alike. An approval is used up by its deployment. New vault versions
/// are new approvals; existing vaults are never upgraded. The admin or guardian can delist
/// a vault and only the admin can relist it.
/// @dev The vault's creation code (~26 KB with its libraries linked) is passed in the call
/// rather than embedded here: embedding it would push this contract past the 24 KB limit.
/// No seed deposit is made: a vault's NAV counts only idle USDC, positions and inventory it
/// tracks internally, never token balances, so a donation cannot move its share price and
/// the classic first-depositor inflation attack does not apply (shares also carry a
/// 6-decimal virtual offset).
contract AbyssiaVaultFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    mapping(bytes32 initHash => bool) public approvedInit;
    /// @notice Listed as official (deployed here and not delisted).
    mapping(address vault => bool) public isVault;
    /// @notice Deployed by this factory, whether listed or not.
    mapping(address vault => bool) public deployedHere;
    address[] internal _vaults;

    event InitApproved(bytes32 indexed initHash, bool approved);
    event VaultDeployed(address indexed vault, bytes32 indexed initHash, bytes32 salt);
    event VaultDelisted(address indexed vault);
    event VaultRelisted(address indexed vault);

    error ZeroAddress();
    error InitNotApproved(bytes32 initHash);
    error DeployFailed();
    error NotListed(address vault);
    error NotDelisted(address vault);
    error Unauthorized();

    constructor(address admin, address deployer) {
        if (admin == address(0) || deployer == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYER_ROLE, deployer);
    }

    /// @notice Admin (timelocked): approve or revoke one deployment's init hash (see
    /// `initHash`).
    function setInitApproved(bytes32 hash, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        approvedInit[hash] = approved;
        emit InitApproved(hash, approved);
    }

    /// @notice Deploy a vault from `creationCode` and ABI-encoded `constructorArgs` whose
    /// init hash is approved, using up the approval.
    function deploy(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address vault)
    {
        bytes memory init = abi.encodePacked(creationCode, constructorArgs);
        bytes32 hash = keccak256(init);
        if (!approvedInit[hash]) revert InitNotApproved(hash);
        approvedInit[hash] = false;
        assembly ("memory-safe") {
            vault := create2(0, add(init, 0x20), mload(init), salt)
        }
        if (vault == address(0)) revert DeployFailed();
        isVault[vault] = true;
        deployedHere[vault] = true;
        _vaults.push(vault);
        emit VaultDeployed(vault, hash, salt);
    }

    /// @notice Admin or guardian: remove a vault from the official list (e.g. one deployed
    /// with wrong constructor arguments). It stays in `vaultAt` history but `isVault` is false.
    function delist(address vault) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        if (!isVault[vault]) revert NotListed(vault);
        isVault[vault] = false;
        emit VaultDelisted(vault);
    }

    /// @notice Admin (timelocked): list a delisted vault again, e.g. after a mistaken or
    /// hostile guardian delisting.
    function relist(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!deployedHere[vault] || isVault[vault]) revert NotDelisted(vault);
        isVault[vault] = true;
        emit VaultRelisted(vault);
    }

    /// @notice The hash `setInitApproved` takes for these inputs.
    function initHash(bytes calldata creationCode, bytes calldata constructorArgs)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(creationCode, constructorArgs));
    }

    /// @notice The address `deploy` would return for these inputs.
    function predict(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 hash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return _vaults[i];
    }
}
