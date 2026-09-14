// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MEMEToken is ERC20Burnable {
    enum TransferMode {
        NORMAL,
        RESTRICTED,
        CONTROLLED
    }

    TransferMode public transferMode;
    address public vestingContract;
    address public dexPair;
    address public core;

    error ZeroAddress();
    error OnlyCore();
    error TransferRestricted();
    error TransferToTokenNotAllowed();
    error TransferNotAllowedToPair();

    event TransferModeChanged(TransferMode oldMode, TransferMode newMode);
    event VestingContractChanged(address vestingContract);
    event PairChanged(address pair);

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    constructor(string memory name, string memory symbol, uint256 totalSupply, address core_) ERC20(name, symbol) {
        if (core_ == address(0)) revert ZeroAddress();

        core = core_;
        transferMode = TransferMode.RESTRICTED;

        if (totalSupply > 0) {
            _mint(core_, totalSupply);
        }
    }

    function setTransferMode(TransferMode newMode) external onlyCore {
        TransferMode oldMode = transferMode;
        transferMode = newMode;
        emit TransferModeChanged(oldMode, newMode);
    }

    function setVestingContract(address vestingContract_) external onlyCore {
        if (vestingContract_ == address(0)) revert ZeroAddress();
        vestingContract = vestingContract_;
        emit VestingContractChanged(vestingContract_);
    }

    function setPair(address pair_) external onlyCore {
        if (pair_ == address(0)) revert ZeroAddress();
        dexPair = pair_;
        emit PairChanged(pair_);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0) || to == address(0)) {
            return;
        }

        if (to == address(this)) {
            revert TransferToTokenNotAllowed();
        }

        if (from == vestingContract && vestingContract != address(0)) {
            return;
        }

        if (transferMode != TransferMode.NORMAL && to == dexPair && dexPair != address(0)) {
            revert TransferNotAllowedToPair();
        }

        if (transferMode == TransferMode.RESTRICTED) {
            revert TransferRestricted();
        }
    }
}
