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
    address internal guardian = makeAddr("guardian");
    bytes internal code = type(MockERC20).creationCode;
    bytes internal args = abi.encode("Vault", "V");

    function setUp() public {
        factory = new AbyssiaVaultFactory(admin, deployer);
        bytes32 guardianRole = factory.GUARDIAN_ROLE();
        vm.prank(admin);
        factory.grantRole(guardianRole, guardian);
    }

    function test_deploysOnlyApprovedCodeAndArgs() public {
        bytes32 hash = factory.initHash(code, args);
        assertEq(hash, keccak256(abi.encodePacked(code, args)));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.InitNotApproved.selector, hash));
        factory.deploy(code, args, bytes32(0));

        _approve(args);
        address predicted = factory.predict(code, args, bytes32("s"));
        vm.prank(deployer);
        address vault = factory.deploy(code, args, bytes32("s"));
        assertEq(vault, predicted);
        assertTrue(factory.isVault(vault));
        assertTrue(factory.deployedHere(vault));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), vault);
        assertEq(MockERC20(vault).symbol(), "V");
    }

    /// M-1: approving the code does not let anyone deploy it with other arguments.
    function test_rejectsApprovedCodeWithOtherArgs() public {
        _approve(args);
        bytes memory other = abi.encode("Evil", "E");
        bytes32 otherHash = factory.initHash(code, other);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.InitNotApproved.selector, otherHash));
        factory.deploy(code, other, bytes32(0));
    }

    /// One approval, one vault: a second deployment (another salt) needs a new approval.
    function test_approvalIsUsedUp() public {
        _approve(args);
        bytes32 hash = factory.initHash(code, args);
        vm.startPrank(deployer);
        factory.deploy(code, args, bytes32("a"));
        assertFalse(factory.approvedInit(hash));
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.InitNotApproved.selector, hash));
        factory.deploy(code, args, bytes32("b"));
        vm.stopPrank();
    }

    function test_revokedApprovalCannotDeploy() public {
        _approve(args);
        bytes32 hash = factory.initHash(code, args);
        vm.prank(admin);
        factory.setInitApproved(hash, false);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.InitNotApproved.selector, hash));
        factory.deploy(code, args, bytes32(0));
    }

    function test_rolesAreEnforced() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 deployerRole = factory.DEPLOYER_ROLE();
        bytes32 hash = factory.initHash(code, args);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, adminRole
            )
        );
        factory.setInitApproved(hash, true);
        _approve(args);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, deployerRole
            )
        );
        factory.deploy(code, args, bytes32(0));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(AbyssiaVaultFactory.ZeroAddress.selector);
        new AbyssiaVaultFactory(address(0), deployer);
    }

    /// A vault listed by mistake can be delisted by the admin or the guardian.
    function test_delist() public {
        address a = _deploy("a");
        address b = _deploy("b");
        vm.prank(deployer);
        vm.expectRevert(AbyssiaVaultFactory.Unauthorized.selector);
        factory.delist(a);
        vm.prank(guardian);
        factory.delist(a);
        vm.prank(admin);
        factory.delist(b);
        assertFalse(factory.isVault(a));
        assertFalse(factory.isVault(b));
        assertEq(factory.vaultCount(), 2);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.NotListed.selector, a));
        factory.delist(a);
    }

    /// Only the admin relists, and only a delisted vault this factory deployed.
    function test_relist() public {
        address a = _deploy("a");
        vm.prank(guardian);
        factory.delist(a);

        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole
            )
        );
        factory.relist(a);

        vm.prank(admin);
        factory.relist(a);
        assertTrue(factory.isVault(a));

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.NotDelisted.selector, a));
        factory.relist(a); // already listed
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(AbyssiaVaultFactory.NotDelisted.selector, stranger));
        factory.relist(stranger); // never deployed here
        vm.stopPrank();
    }

    function _approve(bytes memory constructorArgs) internal {
        bytes32 hash = factory.initHash(code, constructorArgs);
        vm.prank(admin);
        factory.setInitApproved(hash, true);
    }

    /// @dev Distinct args per vault (each needs its own approval).
    function _deploy(string memory symbol) internal returns (address) {
        bytes memory a = abi.encode("Vault", symbol);
        _approve(a);
        vm.prank(deployer);
        return factory.deploy(code, a, bytes32(0));
    }
}
