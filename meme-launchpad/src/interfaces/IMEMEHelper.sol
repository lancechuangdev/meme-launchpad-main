// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMEMEHelper {
    struct BondingCurveParams {
        uint256 virtualBNBReserve;
        uint256 virtualTokenReserve;
        uint256 k;
        uint256 availableTokens;
        uint256 collectedBNB;
    }

    function calculateTokenAmountOut(uint256 bnbIn, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 tokenOut);

    function calculateRequiredBNB(uint256 tokenOut, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 bnbIn);

    function calculateBNBAmountOut(uint256 tokenIn, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 bnbOut);
}
