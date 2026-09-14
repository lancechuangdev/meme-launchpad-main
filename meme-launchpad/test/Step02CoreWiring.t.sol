// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MEMECore} from "../src/MEMECore.sol";
import {MEMEFactory} from "../src/MEMEFactory.sol";
import {MEMEToken} from "../src/MEMEToken.sol";

contract Step02CoreWiringTest is Test {
    MEMEFactory private factory;
    MEMECore private core;

    address private admin = makeAddr("admin");
    address private signer = makeAddr("signer");
    address private helper = makeAddr("helper");
    address private vesting = makeAddr("vesting");
    address private platform = makeAddr("platform");
    address private margin = makeAddr("margin");
    address private graduate = makeAddr("graduate");
    address private user = makeAddr("user");

    function setUp() public {
        factory = new MEMEFactory(admin);
        core = new MEMECore();

        core.initialize(address(factory), helper, signer, platform, margin, graduate, admin);

        vm.prank(admin);
        factory.setCore(address(core));
    }

    function testInitializeStoresDependenciesRolesAndDefaults() public view {
        assertTrue(core.initialized());
        assertEq(address(core.factory()), address(factory));
        assertEq(core.helper(), helper);
        assertEq(core.platformFeeReceiver(), platform);
        assertEq(core.marginReceiver(), margin);
        assertEq(core.graduateFeeReceiver(), graduate);
        assertEq(core.chainId(), block.chainid);

        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.SIGNER_ROLE(), signer));
        assertTrue(core.hasRole(core.DEPLOYER_ROLE(), admin));
        assertTrue(core.hasRole(core.PAUSER_ROLE(), admin));

        assertEq(core.creationFee(), 0.05 ether);
        assertEq(core.preBuyFeeRate(), 300);
        assertEq(core.tradingFeeRate(), 100);
        assertEq(core.graduationPlatformFeeRate(), 550);
        assertEq(core.graduationCreatorFeeRate(), 250);
        assertEq(core.minLockTime(), 1 days);
    }

    function testInitializeCanOnlyRunOnce() public {
        vm.expectRevert(MEMECore.AlreadyInitialized.selector);
        core.initialize(address(factory), helper, signer, platform, margin, graduate, admin);
    }

    function testFactoryDeploysOnlyWhenCoreCallsIt() public {
        uint256 totalSupply = 1_000_000 ether;
        uint256 timestamp = 1_717_171_717;
        uint256 nonce = 7;

        address predicted =
            factory.predictTokenAddress("Step Two", "STP2", totalSupply, address(core), timestamp, nonce);

        vm.prank(admin);
        address deployed = core.deployTokenFor("Step Two", "STP2", totalSupply, timestamp, nonce);

        assertEq(deployed, predicted);
        assertEq(MEMEToken(deployed).core(), address(core));
        assertEq(MEMEToken(deployed).balanceOf(address(core)), totalSupply);
    }

    function testAdminCannotBypassCoreAndDeployDirectlyFromFactory() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.deployToken("Direct", "DIR", 1 ether, block.timestamp, 1);
    }

    function testOnlyAdminCanUseDeployFunction() public {
        vm.prank(user);
        vm.expectRevert();
        core.deployTokenFor("Blocked", "BLK", 1 ether, block.timestamp, 1);
    }

    function testOnlyAdminCanUpdateCoreDependencies() public {
        address newHelper = makeAddr("newHelper");
        address newVesting = makeAddr("newVesting");

        vm.prank(user);
        vm.expectRevert();
        core.setHelper(newHelper);

        vm.prank(admin);
        core.setHelper(newHelper);
        assertEq(core.helper(), newHelper);

        vm.prank(user);
        vm.expectRevert();
        core.setVesting(newVesting);

        vm.prank(admin);
        core.setVesting(newVesting);
        assertEq(core.vesting(), newVesting);
    }
}
