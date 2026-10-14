// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AbyssiaVaultFactory
/// @notice Deploys Abyssia vaults (CREATE2) from creation code the admin has approved by
/// hash, and keeps the list of vaults it deployed, so integrators can tell an official
/// vault from a look-alike. New vault versions are new approved hashes; existing vaults are
/// never upgraded. The constructor arguments are not checked here, so DEPLOYER_ROLE must be
/// held by the timelock (every deployment is then a delayed, cancellable proposal); the
/// admin or guardian can delist a vault.
/// @dev The vault's creation code (~26 KB with its libraries linked) is passed in the call
/// rather than embedded here: embedding it would push this contract past the 24 KB limit.
/// No seed deposit is made: a vault's NAV counts only idle USDC, positions and inventory it
/// tracks internally, never token balances, so a donation cannot move its share price and
/// the classic first-depositor inflation attack does not apply (shares also carry a
/// 6-decimal virtual offset).
contract AbyssiaVaultFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    mapping(bytes32 codeHash => bool) public approvedCode;
    mapping(address vault => bool) public isVault;
    address[] internal _vaults;

    event CodeApproved(bytes32 indexed codeHash, bool approved);
    event VaultDeployed(address indexed vault, bytes32 indexed codeHash, bytes32 salt);
    event VaultDelisted(address indexed vault);

    error ZeroAddress();
    error CodeNotApproved(bytes32 codeHash);
    error DeployFailed();
    error NotListed(address vault);
    error Unauthorized();

    constructor(address admin, address deployer) {
        if (admin == address(0) || deployer == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYER_ROLE, deployer);
    }

    /// @notice Admin (timelocked): approve or revoke a vault creation code hash.
    function setCodeApproved(bytes32 codeHash, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        approvedCode[codeHash] = approved;
        emit CodeApproved(codeHash, approved);
    }

    /// @notice Deploy a vault from approved `creationCode` with ABI-encoded `constructorArgs`.
    function deploy(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address vault)
    {
        bytes32 codeHash = keccak256(creationCode);
        if (!approvedCode[codeHash]) revert CodeNotApproved(codeHash);
        bytes memory init = abi.encodePacked(creationCode, constructorArgs);
        assembly ("memory-safe") {
            vault := create2(0, add(init, 0x20), mload(init), salt)
        }
        if (vault == address(0)) revert DeployFailed();
        isVault[vault] = true;
        _vaults.push(vault);
        emit VaultDeployed(vault, codeHash, salt);
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

    /// @notice The address `deploy` would return for these inputs.
    function predict(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return _vaults[i];
    }
}
