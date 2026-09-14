// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityPool is ERC20 {
    address public immutable token;
    address public immutable router;

    error OnlyRouter();

    constructor(address token_, address router_) ERC20("LP Token", "LLP") {
        token = token_;
        router = router_;
    }

    function depositNative() external payable {
        if (msg.sender != router) revert OnlyRouter();
    }

    function mint(address recipient, uint256 amount) external {
        if (msg.sender != router) revert OnlyRouter();
        _mint(recipient, amount);
    }
}
