pragma solidity ^0.8.20;
// SPDX-License-Identifier: AGPL-3.0-or-later
// Temple (templegold/EpochLib.sol)

import { IAuctionBase } from "contracts/interfaces/templegold/IAuctionBase.sol";

library EpochLib {

    function isActive(IAuctionBase.EpochInfo storage info) internal view returns (bool) {
        return info.startTime <= block.timestamp && block.timestamp < info.endTime;
    }

    function hasEnded(IAuctionBase.EpochInfo storage info) internal view returns (bool) {
        return info.endTime <= block.timestamp;
    }

    //q- hasStarted seems odd, is this not the same as isActive?
    //q- what is the difference between hasStarted and isActive?
    function hasStarted(IAuctionBase.EpochInfo storage info) internal view returns (bool) {
        return info.startTime > 0 && block.timestamp >= info.startTime;
    }
}