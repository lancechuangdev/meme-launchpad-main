// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMEMEVesting {
    enum VestingMode {
        CLIFF,
        LINEAR
    }

    struct ScheduleInput {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        VestingMode mode;
    }

    function createVestingSchedules(address token, address beneficiary, ScheduleInput[] calldata schedules) external;
}
