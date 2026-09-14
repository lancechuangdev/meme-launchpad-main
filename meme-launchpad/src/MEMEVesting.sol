// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMEMEVesting} from "./interfaces/IMEMEVesting.sol";

contract MEMEVesting is AccessControl, ReentrancyGuard, IMEMEVesting {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 claimedAmount;
        VestingMode mode;
    }

    mapping(address => mapping(address => mapping(uint256 => VestingSchedule))) public vestingSchedules;
    mapping(address => mapping(address => uint256)) public scheduleCount;
    mapping(address => uint256) public totalTokenLocked;

    error ZeroAddress();
    error EmptySchedules();
    error InvalidSchedule();
    error ScheduleNotFound();
    error NoClaimableAmount();

    event VestingScheduleCreated(
        address indexed token,
        address indexed beneficiary,
        uint256 indexed scheduleId,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        VestingMode mode
    );
    event TokensClaimed(address indexed token, address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);

    constructor(address admin, address operator) {
        if (admin == address(0) || operator == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    function createVestingSchedules(address token, address beneficiary, ScheduleInput[] calldata schedules)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (schedules.length == 0) revert EmptySchedules();

        uint256 totalAmount;
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].amount == 0 || schedules[i].duration == 0) revert InvalidSchedule();
            totalAmount += schedules[i].amount;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        totalTokenLocked[token] += totalAmount;

        for (uint256 i = 0; i < schedules.length; i++) {
            ScheduleInput calldata input = schedules[i];
            uint256 scheduleId = scheduleCount[token][beneficiary]++;
            uint256 startTime = input.startTime == 0 ? block.timestamp : input.startTime;
            uint256 endTime = startTime + input.duration;

            vestingSchedules[token][beneficiary][scheduleId] = VestingSchedule({
                totalAmount: input.amount, startTime: startTime, endTime: endTime, claimedAmount: 0, mode: input.mode
            });

            emit VestingScheduleCreated(token, beneficiary, scheduleId, input.amount, startTime, endTime, input.mode);
        }
    }

    function claim(address token, uint256 scheduleId) external nonReentrant returns (uint256 amount) {
        VestingSchedule storage schedule = vestingSchedules[token][msg.sender][scheduleId];
        if (schedule.totalAmount == 0) revert ScheduleNotFound();

        amount = _claimable(schedule);
        if (amount == 0) revert NoClaimableAmount();

        schedule.claimedAmount += amount;
        totalTokenLocked[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit TokensClaimed(token, msg.sender, scheduleId, amount);
    }

    function getClaimableAmount(address token, address beneficiary, uint256 scheduleId)
        external
        view
        returns (uint256)
    {
        return _claimable(vestingSchedules[token][beneficiary][scheduleId]);
    }

    function _claimable(VestingSchedule memory schedule) private view returns (uint256) {
        if (schedule.totalAmount == 0 || block.timestamp <= schedule.startTime) return 0;

        uint256 vestedAmount;
        if (block.timestamp >= schedule.endTime) {
            vestedAmount = schedule.totalAmount;
        } else if (schedule.mode == VestingMode.LINEAR) {
            vestedAmount =
                schedule.totalAmount * (block.timestamp - schedule.startTime) / (schedule.endTime - schedule.startTime);
        }

        return vestedAmount - schedule.claimedAmount;
    }
}
