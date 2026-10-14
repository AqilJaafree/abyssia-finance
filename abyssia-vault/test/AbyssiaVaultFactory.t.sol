// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AbyssiaVaultFactory} from "../src/AbyssiaVaultFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Factory mechanics, with a small contract standing in for the vault's creation code.
contract AbyssiaVaultFactoryTest is Test {
    AbyssiaVaultFactory internal factory;
    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer");
    bytes internal code = type(MockERC20).creationCode;
    bytes internal args = abi.encode("Vault", "V");

    function setUp() public {
        factory = new AbyssiaVaultFactory(admin, deployer);
    }

    function test_deploysOnlyApprovedCode() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.CodeNotApproved.selector, keccak256(code)));
        factory.deploy(code, args, bytes32(0));

        vm.prank(admin);
        factory.setCodeApproved(keccak256(code), true);
        address predicted = factory.predict(code, args, bytes32("s"));
        vm.prank(deployer);
        address vault = factory.deploy(code, args, bytes32("s"));
        assertEq(vault, predicted);
        assertTrue(factory.isVault(vault));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), vault);
        assertEq(MockERC20(vault).symbol(), "V");

        // Revoking a hash stops new deployments of it; existing vaults stay listed.
        vm.prank(admin);
        factory.setCodeApproved(keccak256(code), false);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.CodeNotApproved.selector, keccak256(code)));
        factory.deploy(code, args, bytes32("t"));
        assertTrue(factory.isVault(vault));
    }

    function test_rolesAreEnforced() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 deployerRole = factory.DEPLOYER_ROLE();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, adminRole
            )
        );
        factory.setCodeApproved(keccak256(code), true);
        vm.prank(admin);
        factory.setCodeApproved(keccak256(code), true);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, deployerRole
            )
        );
        factory.deploy(code, args, bytes32(0));
    }

    function test_sameSaltTwiceFails() public {
        vm.prank(admin);
        factory.setCodeApproved(keccak256(code), true);
        vm.startPrank(deployer);
        factory.deploy(code, args, bytes32(0));
        vm.expectRevert(AbyssiaVaultFactory.DeployFailed.selector);
        factory.deploy(code, args, bytes32(0));
        vm.stopPrank();
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(AbyssiaVaultFactory.ZeroAddress.selector);
        new AbyssiaVaultFactory(address(0), deployer);
    }
}
