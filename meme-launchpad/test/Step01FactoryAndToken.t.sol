// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MEMEFactory} from "../src/MEMEFactory.sol";
import {MEMEToken} from "../src/MEMEToken.sol";

contract Step01FactoryAndTokenTest is Test {
    MEMEFactory private factory;

    address private admin = address(this);
    address private pair = makeAddr("pair");
    address private user = makeAddr("user");

    function setUp() public {
        factory = new MEMEFactory(admin);
        factory.setCore(address(this));
    }

    function testFactoryDeploysTokenAtPredictedAddress() public {
        uint256 totalSupply = 1_000_000 ether;
        uint256 timestamp = 1_717_171_717;
        uint256 nonce = 42;

        address predicted = factory.predictTokenAddress("Meme", "LMEME", totalSupply, address(this), timestamp, nonce);

        address deployed = factory.deployToken("Meme", "LMEME", totalSupply, timestamp, nonce);

        assertEq(deployed, predicted);
        assertEq(MEMEToken(deployed).balanceOf(address(this)), totalSupply);
        assertEq(uint8(MEMEToken(deployed).transferMode()), uint8(MEMEToken.TransferMode.RESTRICTED));
    }

    function testOnlyCoreCanChangeTokenControls() public {
        MEMEToken token = _deployToken();

        vm.prank(user);
        vm.expectRevert(MEMEToken.OnlyCore.selector);
        token.setTransferMode(MEMEToken.TransferMode.NORMAL);

        token.setTransferMode(MEMEToken.TransferMode.NORMAL);
        assertEq(uint8(token.transferMode()), uint8(MEMEToken.TransferMode.NORMAL));
    }

    function testTransferModesProtectLaunchLifecycle() public {
        MEMEToken token = _deployToken();

        vm.expectRevert(MEMEToken.TransferRestricted.selector);
        token.transfer(user, 1 ether);

        token.setTransferMode(MEMEToken.TransferMode.CONTROLLED);
        token.transfer(user, 1 ether);
        assertEq(token.balanceOf(user), 1 ether);

        token.setPair(pair);
        vm.expectRevert(MEMEToken.TransferNotAllowedToPair.selector);
        token.transfer(pair, 1 ether);

        token.setTransferMode(MEMEToken.TransferMode.NORMAL);
        token.transfer(pair, 1 ether);
        assertEq(token.balanceOf(pair), 1 ether);
    }

    function testOnlyFactoryDeployerRoleCanDeploy() public {
        vm.prank(user);
        vm.expectRevert();
        factory.deployToken("Bad", "BAD", 1 ether, block.timestamp, 1);
    }

    function _deployToken() private returns (MEMEToken) {
        address deployed = factory.deployToken("Meme", "LMEME", 1_000_000 ether, block.timestamp, 1);
        return MEMEToken(deployed);
    }
}
