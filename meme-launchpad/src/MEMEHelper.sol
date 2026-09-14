// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMEMEHelper} from "./interfaces/IMEMEHelper.sol";

contract MEMEHelper is IMEMEHelper {
    error InvalidCurve();
    error InvalidTokenOutput();

    function calculateTokenAmountOut(uint256 bnbIn, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 tokenOut)
    {
        if (bnbIn == 0) return 0;
        if (curve.k == 0 || curve.virtualBNBReserve == 0) revert InvalidCurve();

        uint256 newBNBReserve = curve.virtualBNBReserve + bnbIn;
        uint256 newTokenReserve = curve.k / newBNBReserve;
        if (curve.virtualTokenReserve <= newTokenReserve) return 0;

        return curve.virtualTokenReserve - newTokenReserve;
    }

    function calculateRequiredBNB(uint256 tokenOut, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 bnbIn)
    {
        if (tokenOut == 0) return 0;
        if (curve.k == 0 || curve.virtualTokenReserve == 0) revert InvalidCurve();
        if (tokenOut >= curve.virtualTokenReserve) revert InvalidTokenOutput();

        uint256 newTokenReserve = curve.virtualTokenReserve - tokenOut;
        uint256 newBNBReserve = curve.k / newTokenReserve;
        if (newBNBReserve <= curve.virtualBNBReserve) return 0;

        return newBNBReserve - curve.virtualBNBReserve;
    }

    function calculateBNBAmountOut(uint256 tokenIn, BondingCurveParams memory curve)
        external
        pure
        returns (uint256 bnbOut)
    {
        if (tokenIn == 0) return 0;
        if (curve.k == 0 || curve.virtualTokenReserve == 0) revert InvalidCurve();

        uint256 newTokenReserve = curve.virtualTokenReserve + tokenIn;
        uint256 newBNBReserve = curve.k / newTokenReserve;
        if (curve.virtualBNBReserve <= newBNBReserve) return 0;

        return curve.virtualBNBReserve - newBNBReserve;
    }
}
