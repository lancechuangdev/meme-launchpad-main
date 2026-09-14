// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MEMEToken} from "./MEMEToken.sol";

contract MEMEFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    address public core;

    error ZeroAddress();

    event TokenDeployed(address indexed token, string name, string symbol, uint256 totalSupply, address deployer);
    event CoreChanged(address indexed oldCore, address indexed newCore);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function deployToken(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 timestamp,
        uint256 nonce
    ) external onlyRole(DEPLOYER_ROLE) returns (address token) {
        bytes32 salt = _salt(name, symbol, totalSupply, core, timestamp, nonce);
        token = address(new MEMEToken{salt: salt}(name, symbol, totalSupply, core));

        emit TokenDeployed(token, name, symbol, totalSupply, msg.sender);
    }

    function predictTokenAddress(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address owner,
        uint256 timestamp,
        uint256 nonce
    ) external view returns (address) {
        bytes32 salt = _salt(name, symbol, totalSupply, owner, timestamp, nonce);
        bytes32 bytecodeHash =
            keccak256(abi.encodePacked(type(MEMEToken).creationCode, abi.encode(name, symbol, totalSupply, owner)));
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash));

        return address(uint160(uint256(digest)));
    }

    function setCore(address core_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (core_ == address(0)) revert ZeroAddress();

        address oldCore = core;
        core = core_;
        _grantRole(DEPLOYER_ROLE, core_);

        emit CoreChanged(oldCore, core_);
    }

    function _salt(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address owner,
        uint256 timestamp,
        uint256 nonce
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, symbol, totalSupply, owner, timestamp, nonce));
    }
}
