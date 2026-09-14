// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MEMECore} from "../src/MEMECore.sol";
import {MEMEFactory} from "../src/MEMEFactory.sol";
import {MEMEHelper} from "../src/MEMEHelper.sol";
import {MEMEToken} from "../src/MEMEToken.sol";
import {MEMEVesting} from "../src/MEMEVesting.sol";
import {IMEMEVesting} from "../src/interfaces/IMEMEVesting.sol";

contract Step05InitialBuyAndVestingTest is Test {
    uint256 private constant SIGNER_PRIVATE_KEY = 0xA11CE;

    MEMEFactory private factory;
    MEMEHelper private helper;
    MEMECore private core;
    MEMEVesting private vesting;

    address private admin = makeAddr("admin");
    address private signer;
    address private platform = makeAddr("platform");
    address private creator = makeAddr("creator");
    address private payer = makeAddr("payer");

    function setUp() public {
        vm.warp(1_717_171_717);
        signer = vm.addr(SIGNER_PRIVATE_KEY);

        factory = new MEMEFactory(admin);
        helper = new MEMEHelper();
        core = new MEMECore();
        vesting = new MEMEVesting(admin, address(core));
        core.initialize(
            address(factory), address(helper), signer, platform, makeAddr("margin"), makeAddr("graduate"), admin
        );

        vm.prank(admin);
        core.setVesting(address(vesting));

        vm.prank(admin);
        factory.setCore(address(core));

        vm.deal(payer, 100 ether);
    }

    function testInitialBuyTransfersTokensAndStartsCurveAfterPurchase() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](0);
        MEMECore.CreateTokenParams memory params = _params(1_000, allocations);
        (uint256 initialTokens, uint256 initialBNB, uint256 initialFee) = core.calculateInitialBuyCost(
            params.totalSupply, params.virtualBNBReserve, params.virtualTokenReserve, params.initialBuyPercentage
        );
        uint256 totalPayment = core.creationFee() + initialBNB + initialFee;
        uint256 payerBalanceBefore = payer.balance;

        MEMEToken token = MEMEToken(_create(params, totalPayment));

        (uint256 virtualBNB, uint256 virtualTokens,, uint256 remainingTokens, uint256 collectedBNB) =
            core.bondingCurve(address(token));
        assertEq(token.balanceOf(creator), initialTokens);
        assertEq(virtualBNB, params.virtualBNBReserve + initialBNB);
        assertEq(virtualTokens, params.virtualTokenReserve - initialTokens);
        assertEq(remainingTokens, params.saleAmount - initialTokens);
        assertEq(collectedBNB, initialBNB);
        assertEq(address(core).balance, initialBNB);
        assertEq(platform.balance, core.creationFee() + initialFee);
        assertEq(payer.balance, payerBalanceBefore - totalPayment);
    }

    function testLinearVestingReleasesTokensOverTime() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](1);
        allocations[0] =
            MEMECore.VestingAllocation({percentageBP: 600, duration: 10 days, mode: IMEMEVesting.VestingMode.LINEAR});
        MEMECore.CreateTokenParams memory params = _params(1_000, allocations);
        MEMEToken token = MEMEToken(_create(params, _requiredPayment(params)));

        assertEq(token.balanceOf(creator), 40_000 ether);
        assertEq(token.balanceOf(address(vesting)), 60_000 ether);
        assertEq(vesting.scheduleCount(address(token), creator), 1);
        assertEq(vesting.totalTokenLocked(address(token)), 60_000 ether);

        (, uint256 startTime, uint256 endTime,, IMEMEVesting.VestingMode mode) =
            vesting.vestingSchedules(address(token), creator, 0);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, block.timestamp + 10 days);
        assertEq(uint8(mode), uint8(IMEMEVesting.VestingMode.LINEAR));

        vm.warp(block.timestamp + 5 days);
        assertEq(vesting.getClaimableAmount(address(token), creator, 0), 30_000 ether);

        vm.prank(creator);
        vesting.claim(address(token), 0);

        assertEq(token.balanceOf(creator), 70_000 ether);
        assertEq(vesting.totalTokenLocked(address(token)), 30_000 ether);
    }

    function testCliffVestingUnlocksEverythingAtEnd() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](1);
        allocations[0] =
            MEMECore.VestingAllocation({percentageBP: 1_000, duration: 7 days, mode: IMEMEVesting.VestingMode.CLIFF});
        MEMECore.CreateTokenParams memory params = _params(1_000, allocations);
        MEMEToken token = MEMEToken(_create(params, _requiredPayment(params)));

        vm.warp(block.timestamp + 6 days);
        vm.prank(creator);
        vm.expectRevert(MEMEVesting.NoClaimableAmount.selector);
        vesting.claim(address(token), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        vesting.claim(address(token), 0);

        assertEq(token.balanceOf(creator), 100_000 ether);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testCreationRejectsInsufficientInitialBuyPayment() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](0);
        MEMECore.CreateTokenParams memory params = _params(1_000, allocations);
        uint256 insufficientPayment = _requiredPayment(params) - 1;
        (bytes memory data, bytes memory signature) = _signedRequest(params);

        vm.prank(payer);
        vm.expectRevert(MEMECore.InsufficientFee.selector);
        core.createToken{value: insufficientPayment}(data, signature);
    }

    function testCreationRejectsVestingAboveInitialBuy() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](1);
        allocations[0] =
            MEMECore.VestingAllocation({percentageBP: 1_100, duration: 7 days, mode: IMEMEVesting.VestingMode.CLIFF});
        MEMECore.CreateTokenParams memory params = _params(1_000, allocations);
        uint256 payment = _requiredPayment(params);
        (bytes memory data, bytes memory signature) = _signedRequest(params);

        vm.prank(payer);
        vm.expectRevert(MEMECore.InvalidVestingAllocation.selector);
        core.createToken{value: payment}(data, signature);
    }

    function testCreationRejectsVestingWithoutInitialBuy() public {
        MEMECore.VestingAllocation[] memory allocations = new MEMECore.VestingAllocation[](1);
        allocations[0] =
            MEMECore.VestingAllocation({percentageBP: 100, duration: 7 days, mode: IMEMEVesting.VestingMode.CLIFF});
        MEMECore.CreateTokenParams memory params = _params(0, allocations);
        uint256 payment = core.creationFee();
        (bytes memory data, bytes memory signature) = _signedRequest(params);

        vm.prank(payer);
        vm.expectRevert(MEMECore.InvalidVestingAllocation.selector);
        core.createToken{value: payment}(data, signature);
    }

    function _params(uint256 initialBuyPercentage, MEMECore.VestingAllocation[] memory allocations)
        private
        view
        returns (MEMECore.CreateTokenParams memory)
    {
        return MEMECore.CreateTokenParams({
            name: "Vested Meme",
            symbol: "VEST",
            totalSupply: 1_000_000 ether,
            saleAmount: 800_000 ether,
            virtualBNBReserve: 10 ether,
            virtualTokenReserve: 1_000_000 ether,
            launchTime: 0,
            creator: creator,
            timestamp: block.timestamp,
            requestId: keccak256(abi.encode("step-05-request", initialBuyPercentage, allocations.length)),
            nonce: initialBuyPercentage + allocations.length,
            initialBuyPercentage: initialBuyPercentage,
            vestingAllocations: allocations
        });
    }

    function _requiredPayment(MEMECore.CreateTokenParams memory params) private view returns (uint256) {
        (, uint256 initialBNB, uint256 initialFee) = core.calculateInitialBuyCost(
            params.totalSupply, params.virtualBNBReserve, params.virtualTokenReserve, params.initialBuyPercentage
        );
        return core.creationFee() + initialBNB + initialFee;
    }

    function _create(MEMECore.CreateTokenParams memory params, uint256 payment) private returns (address tokenAddress) {
        (bytes memory data, bytes memory signature) = _signedRequest(params);
        vm.prank(payer);
        return core.createToken{value: payment}(data, signature);
    }

    function _signedRequest(MEMECore.CreateTokenParams memory params)
        private
        view
        returns (bytes memory data, bytes memory signature)
    {
        data = abi.encode(params);
        bytes32 digest = keccak256(abi.encodePacked(data, core.chainId(), address(core)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
