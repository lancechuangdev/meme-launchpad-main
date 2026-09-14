// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MEMECore} from "../src/MEMECore.sol";
import {MEMEFactory} from "../src/MEMEFactory.sol";
import {MEMEHelper} from "../src/MEMEHelper.sol";
import {MEMEToken} from "../src/MEMEToken.sol";

contract Step07AdminAndEmergencyControlsTest is Test {
    uint256 private constant SIGNER_PRIVATE_KEY = 0xA11CE;

    MEMEFactory private factory;
    MEMEHelper private helper;
    MEMECore private core;
    MEMEToken private token;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private signer;
    address private platform = makeAddr("platform");
    address private creator = makeAddr("creator");
    address private buyer = makeAddr("buyer");
    address private user = makeAddr("user");

    function setUp() public {
        vm.warp(1_717_171_717);
        signer = vm.addr(SIGNER_PRIVATE_KEY);
        factory = new MEMEFactory(admin);
        helper = new MEMEHelper();
        core = new MEMECore();
        core.initialize(
            address(factory), address(helper), signer, platform, makeAddr("margin"), makeAddr("graduate"), admin
        );

        vm.startPrank(admin);
        factory.setCore(address(core));
        core.grantRole(core.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        vm.deal(buyer, 10 ether);
        token = MEMEToken(_createToken());
    }

    function testGlobalPauseStopsTradingAndOnlyAdminCanResume() public {
        vm.prank(pauser);
        core.pause();
        assertTrue(core.paused());

        vm.prank(buyer);
        vm.expectRevert(bytes("Pausable: paused"));
        core.buy{value: 1 ether}(address(token), 0, block.timestamp + 5 minutes);

        vm.prank(pauser);
        vm.expectRevert();
        core.unpause();

        vm.prank(admin);
        core.unpause();
        assertFalse(core.paused());

        vm.prank(buyer);
        core.buy{value: 1 ether}(address(token), 0, block.timestamp + 5 minutes);
        assertGt(token.balanceOf(buyer), 0);
    }

    function testTokenPauseFreezesAndRestoresTrading() public {
        vm.prank(buyer);
        core.buy{value: 1 ether}(address(token), 0, block.timestamp + 5 minutes);

        vm.prank(pauser);
        core.pauseToken(address(token));

        (,,, MEMECore.TokenStatus pausedStatus,) = core.tokenInfo(address(token));
        assertEq(uint8(pausedStatus), uint8(MEMECore.TokenStatus.PAUSED));
        assertEq(uint8(token.transferMode()), uint8(MEMEToken.TransferMode.RESTRICTED));

        vm.prank(buyer);
        vm.expectRevert(MEMECore.TokenNotTrading.selector);
        core.buy{value: 0.1 ether}(address(token), 0, block.timestamp + 5 minutes);

        vm.prank(pauser);
        core.unpauseToken(address(token));

        (,,, MEMECore.TokenStatus tradingStatus,) = core.tokenInfo(address(token));
        assertEq(uint8(tradingStatus), uint8(MEMECore.TokenStatus.TRADING));
        assertEq(uint8(token.transferMode()), uint8(MEMEToken.TransferMode.CONTROLLED));
    }

    function testBlacklistRestoresPreviousTokenState() public {
        vm.prank(pauser);
        core.pauseToken(address(token));

        vm.prank(admin);
        core.blacklistToken(address(token));
        (,,, MEMECore.TokenStatus blacklistedStatus,) = core.tokenInfo(address(token));
        assertEq(uint8(blacklistedStatus), uint8(MEMECore.TokenStatus.BLACKLISTED));

        vm.prank(admin);
        core.removeFromBlacklist(address(token));
        (,,, MEMECore.TokenStatus restoredStatus,) = core.tokenInfo(address(token));
        assertEq(uint8(restoredStatus), uint8(MEMECore.TokenStatus.PAUSED));
        assertEq(uint8(token.transferMode()), uint8(MEMEToken.TransferMode.RESTRICTED));
    }

    function testBlacklistBlocksTransfersUntilRemoved() public {
        vm.prank(buyer);
        core.buy{value: 1 ether}(address(token), 0, block.timestamp + 5 minutes);

        vm.prank(admin);
        core.blacklistToken(address(token));

        vm.prank(buyer);
        vm.expectRevert(MEMEToken.TransferRestricted.selector);
        token.transfer(user, 1 ether);

        vm.prank(admin);
        core.removeFromBlacklist(address(token));

        vm.prank(buyer);
        token.transfer(user, 1 ether);
        assertEq(token.balanceOf(user), 1 ether);
    }

    function testAdminCanUpdateFeesReceiversAndLockTime() public {
        address newPlatform = makeAddr("newPlatform");
        address newGraduate = makeAddr("newGraduate");
        address newMargin = makeAddr("newMargin");

        vm.startPrank(admin);
        core.setPlatformFeeReceiver(newPlatform);
        core.setGraduateFeeReceiver(newGraduate);
        core.setMarginReceiver(newMargin);
        core.setCreationFee(0.08 ether);
        core.setPreBuyFeeRate(500);
        core.setTradingFeeRate(150);
        core.setGraduationFeeRates(1_000, 400);
        core.setMinLockTime(2 days);
        vm.stopPrank();

        assertEq(core.platformFeeReceiver(), newPlatform);
        assertEq(core.graduateFeeReceiver(), newGraduate);
        assertEq(core.marginReceiver(), newMargin);
        assertEq(core.creationFee(), 0.08 ether);
        assertEq(core.preBuyFeeRate(), 500);
        assertEq(core.tradingFeeRate(), 150);
        assertEq(core.graduationPlatformFeeRate(), 1_000);
        assertEq(core.graduationCreatorFeeRate(), 400);
        assertEq(core.minLockTime(), 2 days);
    }

    function testFeeLimitsAndAdminRoleAreEnforced() public {
        vm.prank(user);
        vm.expectRevert();
        core.setTradingFeeRate(100);

        vm.startPrank(admin);
        vm.expectRevert(MEMECore.InvalidAdminValue.selector);
        core.setCreationFee(0.1 ether + 1);

        vm.expectRevert(MEMECore.InvalidAdminValue.selector);
        core.setPreBuyFeeRate(601);

        vm.expectRevert(MEMECore.InvalidAdminValue.selector);
        core.setTradingFeeRate(201);

        vm.expectRevert(MEMECore.InvalidAdminValue.selector);
        core.setGraduationFeeRates(1_101, 500);

        vm.expectRevert(MEMECore.InvalidAdminValue.selector);
        core.setGraduationFeeRates(1_100, 501);
        vm.stopPrank();
    }

    function _createToken() private returns (address tokenAddress) {
        MEMECore.CreateTokenParams memory params = MEMECore.CreateTokenParams({
            name: "Controlled Meme",
            symbol: "CTRL",
            totalSupply: 1_000_000 ether,
            saleAmount: 800_000 ether,
            virtualBNBReserve: 10 ether,
            virtualTokenReserve: 1_000_000 ether,
            launchTime: 0,
            creator: creator,
            timestamp: block.timestamp,
            requestId: keccak256("step-07-request"),
            nonce: 7,
            initialBuyPercentage: 0,
            vestingAllocations: new MEMECore.VestingAllocation[](0)
        });
        bytes memory data = abi.encode(params);
        bytes32 digest = keccak256(abi.encodePacked(data, core.chainId(), address(core)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);

        tokenAddress = core.createToken{value: core.creationFee()}(data, abi.encodePacked(r, s, v));
    }
}
