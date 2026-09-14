// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MEMECore} from "../src/MEMECore.sol";
import {MEMEFactory} from "../src/MEMEFactory.sol";
import {MEMEHelper} from "../src/MEMEHelper.sol";
import {MEMEToken} from "../src/MEMEToken.sol";

contract Step04BondingCurveTradingTest is Test {
    uint256 private constant SIGNER_PRIVATE_KEY = 0xA11CE;

    struct CurveState {
        uint256 virtualBNB;
        uint256 virtualTokens;
        uint256 availableTokens;
        uint256 collectedBNB;
    }

    MEMEFactory private factory;
    MEMEHelper private helper;
    MEMECore private core;
    MEMEToken private token;

    address private admin = makeAddr("admin");
    address private signer;
    address private platform = makeAddr("platform");
    address private creator = makeAddr("creator");
    address private buyer = makeAddr("buyer");

    function setUp() public {
        vm.warp(1_717_171_717);
        signer = vm.addr(SIGNER_PRIVATE_KEY);

        factory = new MEMEFactory(admin);
        helper = new MEMEHelper();
        core = new MEMECore();
        core.initialize(
            address(factory), address(helper), signer, platform, makeAddr("margin"), makeAddr("graduate"), admin
        );

        vm.prank(admin);
        factory.setCore(address(core));

        vm.deal(buyer, 100 ether);
        token = MEMEToken(_createToken(0));
    }

    function testCreationInitializesBondingCurve() public view {
        (
            uint256 virtualBNBReserve,
            uint256 virtualTokenReserve,
            uint256 k,
            uint256 availableTokens,
            uint256 collectedBNB
        ) = core.bondingCurve(address(token));

        assertEq(virtualBNBReserve, 10 ether);
        assertEq(virtualTokenReserve, 1_000_000 ether);
        assertEq(k, uint256(10 ether) * uint256(1_000_000 ether));
        assertEq(availableTokens, 800_000 ether);
        assertEq(collectedBNB, 0);
    }

    function testBuyUsesQuoteAndUpdatesVirtualAndRealReserves() public {
        uint256 payment = 1 ether;
        (uint256 expectedTokens, uint256 expectedNetBNB, uint256 expectedFee) =
            core.calculateBuyAmountWithFee(address(token), payment);
        uint256 platformBefore = platform.balance;

        vm.prank(buyer);
        core.buy{value: payment}(address(token), expectedTokens, block.timestamp + 5 minutes);

        (uint256 virtualBNBReserve, uint256 virtualTokenReserve,, uint256 availableTokens, uint256 collectedBNB) =
            core.bondingCurve(address(token));

        assertEq(token.balanceOf(buyer), expectedTokens);
        assertEq(virtualBNBReserve, 10 ether + expectedNetBNB);
        assertEq(virtualTokenReserve, 1_000_000 ether - expectedTokens);
        assertEq(availableTokens, 800_000 ether - expectedTokens);
        assertEq(collectedBNB, expectedNetBNB);
        assertEq(address(core).balance, expectedNetBNB);
        assertEq(platform.balance, platformBefore + expectedFee);
    }

    function testBuyerCanSellTokensBackToCurve() public {
        (uint256 purchased,,) = core.calculateBuyAmountWithFee(address(token), 1 ether);

        vm.prank(buyer);
        core.buy{value: 1 ether}(address(token), purchased, block.timestamp + 5 minutes);

        uint256 tokenAmount = purchased / 2;
        (uint256 expectedNetBNB, uint256 expectedFee) = core.calculateSellReturnWithFee(address(token), tokenAmount);
        uint256 grossBNB = expectedNetBNB + expectedFee;
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 platformBefore = platform.balance;
        CurveState memory beforeState = _curveState(token);

        vm.prank(buyer);
        token.approve(address(core), tokenAmount);

        vm.prank(buyer);
        core.sell(address(token), tokenAmount, expectedNetBNB, block.timestamp + 5 minutes);

        CurveState memory afterState = _curveState(token);

        assertEq(token.balanceOf(buyer), purchased - tokenAmount);
        assertEq(buyer.balance, buyerBalanceBefore + expectedNetBNB);
        assertEq(platform.balance, platformBefore + expectedFee);
        assertEq(afterState.virtualBNB, beforeState.virtualBNB - grossBNB);
        assertEq(afterState.virtualTokens, beforeState.virtualTokens + tokenAmount);
        assertEq(afterState.availableTokens, beforeState.availableTokens + tokenAmount);
        assertEq(afterState.collectedBNB, beforeState.collectedBNB - grossBNB);
        assertEq(address(core).balance, afterState.collectedBNB);
    }

    function testBuyCapsAtAvailableInventoryAndRefundsExcess() public {
        uint256 payment = 90 ether;
        (uint256 expectedTokens, uint256 expectedNetBNB, uint256 expectedFee) =
            core.calculateBuyAmountWithFee(address(token), payment);
        uint256 buyerBalanceBefore = buyer.balance;

        assertEq(expectedTokens, 800_000 ether);

        vm.prank(buyer);
        core.buy{value: payment}(address(token), expectedTokens, block.timestamp + 5 minutes);

        CurveState memory state = _curveState(token);
        assertEq(token.balanceOf(buyer), expectedTokens);
        assertEq(buyer.balance, buyerBalanceBefore - expectedNetBNB - expectedFee);
        assertEq(state.availableTokens, 0);
        assertEq(state.collectedBNB, expectedNetBNB);
        assertEq(address(core).balance, expectedNetBNB);
    }

    function testBuyRejectsSlippage() public {
        (uint256 quotedTokens,,) = core.calculateBuyAmountWithFee(address(token), 1 ether);

        vm.prank(buyer);
        vm.expectRevert(MEMECore.SlippageExceeded.selector);
        core.buy{value: 1 ether}(address(token), quotedTokens + 1, block.timestamp + 5 minutes);
    }

    function testTradingRejectsFutureLaunchAndExpiredDeadline() public {
        MEMEToken futureToken = MEMEToken(_createToken(block.timestamp + 1 hours));
        uint256 deadline = block.timestamp + 5 minutes;

        vm.prank(buyer);
        vm.expectRevert(MEMECore.TokenNotLaunchedYet.selector);
        core.buy{value: 1 ether}(address(futureToken), 0, deadline);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(buyer);
        vm.expectRevert(MEMECore.TransactionExpired.selector);
        core.buy{value: 1 ether}(address(token), 0, deadline);
    }

    function testSellRejectsWhenCurveHasNoRealBNBLiquidity() public {
        uint256 tokenAmount = 1_000 ether;

        vm.prank(address(core));
        token.transfer(buyer, tokenAmount);

        vm.prank(buyer);
        token.approve(address(core), tokenAmount);

        vm.prank(buyer);
        vm.expectRevert(MEMECore.InsufficientLiquidity.selector);
        core.sell(address(token), tokenAmount, 0, block.timestamp + 5 minutes);
    }

    function _createToken(uint256 launchTime) private returns (address tokenAddress) {
        MEMECore.CreateTokenParams memory params = MEMECore.CreateTokenParams({
            name: "Curve Meme",
            symbol: "CURVE",
            totalSupply: 1_000_000 ether,
            saleAmount: 800_000 ether,
            virtualBNBReserve: 10 ether,
            virtualTokenReserve: 1_000_000 ether,
            launchTime: launchTime,
            creator: creator,
            timestamp: block.timestamp,
            requestId: keccak256(abi.encode("step-04-request", launchTime)),
            nonce: launchTime + 4,
            initialBuyPercentage: 0,
            vestingAllocations: new MEMECore.VestingAllocation[](0)
        });
        bytes memory data = abi.encode(params);
        bytes32 digest = keccak256(abi.encodePacked(data, core.chainId(), address(core)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);

        tokenAddress = core.createToken{value: core.creationFee()}(data, abi.encodePacked(r, s, v));
    }

    function _curveState(MEMEToken curveToken) private view returns (CurveState memory state) {
        (state.virtualBNB, state.virtualTokens,, state.availableTokens, state.collectedBNB) =
            core.bondingCurve(address(curveToken));
    }
}
