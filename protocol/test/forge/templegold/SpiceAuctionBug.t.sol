// pragma solidity 0.8.20;
// // SPDX-License-Identifier: AGPL-3.0-or-later
// // (tests/forge/templegold/SpiceAuction.t.sol)

// import { TempleGoldCommon } from "./TempleGoldCommon.t.sol";
// import { ISpiceAuction } from "contracts/interfaces/templegold/ISpiceAuction.sol";
// import { SpiceAuctionFactory } from "contracts/templegold/SpiceAuctionFactory.sol";
// import { ITempleGold } from "contracts/interfaces/templegold/ITempleGold.sol";
// import { TempleGold } from "contracts/templegold/TempleGold.sol";
// import { CommonEventsAndErrors } from "contracts/common/CommonEventsAndErrors.sol";
// import { IAuctionBase } from "contracts/interfaces/templegold/IAuctionBase.sol";
// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import { FakeERC20 } from "contracts/fakes/FakeERC20.sol";

// contract SpiceAuctionBugPOC is SpiceAuctionTestBase {
//     function test_POC_bug_tokenAllocationNotUpdated() public {
//         // 1. Set auction config as DAO
//         ISpiceAuction.SpiceAuctionConfig memory config = _getAuctionConfig();
//         vm.startPrank(daoExecutor);
//         spice.setAuctionConfig(config);
//         vm.stopPrank();
        
//         // 2. Determine auction token (auction token is templeGold if isTempleGoldAuctionToken is true)
//         address auctionToken = config.isTempleGoldAuctionToken ? address(templeGold) : spice.spiceToken();
        
//         // Fund the auction contract with auction tokens (e.g., 100 ether)
//         dealAdditional(IERC20(auctionToken), address(spice), 100 ether);
        
//         // 3. Start auction (which increases _totalAuctionTokenAllocation by the auction token amount)
//         // Warp to after waitPeriod to allow auction start
//         if (config.starter != address(0)) {
//             vm.startPrank(config.starter);
//         }
//         vm.warp(block.timestamp + config.waitPeriod);
//         spice.startAuction();
//         vm.stopPrank();
        
//         // At this point, _totalAuctionTokenAllocation[auctionToken] has been incremented by 100 ether,
//         // even though the auction hasn't fully started (cooldown period).
        
//         // 4. Remove the auction config during cooldown (i.e. before auction has ended)
//         // This should ideally also update _totalAuctionTokenAllocation, but it does not.
//         vm.startPrank(daoExecutor);
//         // Note: We do not set a new auction config for the next epoch,
//         // so auctionConfigs[currentEpochId + 1].duration == 0, forcing the removal branch.
//         spice.removeAuctionConfig();
//         vm.stopPrank();
        
//         // 5. Now try to recover the auction tokens.
//         // The recoverToken function computes:
//         //    maxRecoverAmount = balance - (totalAuctionTokenAllocation - claimedAuctionTokens)
//         // With a proper removal, totalAuctionTokenAllocation should have been decreased.
//         // However, because of the bug it remains 100 ether, so maxRecoverAmount == 100 - 100 == 0.
//         // Attempting to recover 100 ether should therefore revert.
//         vm.startPrank(daoExecutor);
//         vm.expectRevert(abi.encodeWithSelector(CommonEventsAndErrors.InvalidParam.selector));
//         spice.recoverToken(auctionToken, daoExecutor, 100 ether);
//         vm.stopPrank();
//     }
// }
