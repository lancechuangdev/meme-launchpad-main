// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidityPool} from "./LiquidityPool.sol";

contract DEXRouter {
    using SafeERC20 for IERC20;

    mapping(address => address) public pairFor;

    error ZeroAddress();
    error ZeroLiquidity();

    event PairCreated(address indexed token, address indexed pair);
    event LiquidityAdded(
        address indexed token,
        address indexed pair,
        uint256 tokenAmount,
        uint256 nativeAmount,
        uint256 liquidity,
        address recipient
    );

    function createPair(address token) public returns (address pair) {
        if (token == address(0)) revert ZeroAddress();
        pair = pairFor[token];
        if (pair != address(0)) return pair;

        pair = address(new LiquidityPool(token, address(this)));
        pairFor[token] = pair;
        emit PairCreated(token, pair);
    }

    function addLiquidity(address token, uint256 tokenAmount, address lpRecipient)
        external
        payable
        returns (address pair, uint256 liquidity)
    {
        if (lpRecipient == address(0)) revert ZeroAddress();
        if (tokenAmount == 0 || msg.value == 0) revert ZeroLiquidity();

        pair = createPair(token);
        IERC20(token).safeTransferFrom(msg.sender, pair, tokenAmount);
        LiquidityPool(payable(pair)).depositNative{value: msg.value}();

        liquidity = _sqrt(tokenAmount * msg.value);
        if (liquidity == 0) revert ZeroLiquidity();
        LiquidityPool(payable(pair)).mint(lpRecipient, liquidity);

        emit LiquidityAdded(token, pair, tokenAmount, msg.value, liquidity, lpRecipient);
    }

    // Newton-Raphson iteration
    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;

        uint256 estimate = (value + 1) / 2;
        result = value;
        while (estimate < result) {
            result = estimate;
            estimate = (value / estimate + estimate) / 2;
        }
    }
}
