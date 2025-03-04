pragma solidity ^0.8.20;
// SPDX-License-Identifier: AGPL-3.0-or-later
// Temple (templegold/TempleGoldStaking.sol)


import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CommonEventsAndErrors } from "contracts/common/CommonEventsAndErrors.sol";
import { TempleElevatedAccess } from "contracts/v2/access/TempleElevatedAccess.sol";
import { ITempleGold } from "contracts/interfaces/templegold/ITempleGold.sol";
import { ITempleGoldStaking } from "contracts/interfaces/templegold/ITempleGoldStaking.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/** 
 * @title Temple Gold Staking
 * @notice Temple Gold Staking contract. Stakers deposit Temple and claim rewards in Temple Gold. 
 * Temple Gold is distributed to staking contract for stakers on mint.
 * Duration for distributing staking rewards is set with `setRewardDuration`. A vesting period is used
 * to encourage longer staking times.
 */
contract TempleGoldStaking is ITempleGoldStaking, TempleElevatedAccess, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice The staking token. Temple
    IERC20 public immutable override stakingToken;
    /// @notice Reward token. Temple Gold
    IERC20 public immutable override rewardToken;

    /// @notice Distribution starter
    address public override distributionStarter;
    /// @notice Vesting period
    uint32 public override vestingPeriod;
    /// @notice Week length
    uint256 constant public WEEK_LENGTH = 7 days;

    /// @notice Rewards stored per token
    uint256 public override rewardPerTokenStored;
    /// @notice Total supply of staking token
    uint256 public override totalSupply;

    /// @notice Time tracking
    uint256 public override periodFinish;
    /// @notice Last rewards update time
    uint256 public override lastUpdateTime;

    /// @notice Store next reward amount for next epoch
    uint256 public override nextRewardAmount;
    /// @notice Duration for rewards distribution
    uint256 public rewardDuration;
    /// @notice Cooldown time before next distribution of rewards
    /// @dev If set to zero, rewards distribution is callable any time 
    uint160 public override rewardDistributionCoolDown;
    /// @notice Timestamp for last reward notification
    uint96 public override lastRewardNotificationTimestamp;

    /// @notice For use when migrating to a new staking contract if TGLD changes.
    address public override migrator;
    /// @notice Data struct for rewards
    Reward internal rewardData;
    /// @notice Staker balances
    mapping(address account => uint256 balance) private _balances;
    
    /// @notice Account vote delegates
    mapping(address account => address delegate) public delegates;

    /// @notice Track account stakes
    mapping(address account => mapping(uint256 index => StakeInfo)) private _stakeInfos;
    /// @notice Track account stake index
    mapping(address account => uint256 lastIndex) private _accountLastStakeIndex;
    /// @notice Stakers claimable rewards
    mapping(address account => mapping(uint256 index => uint256 amount)) public override claimableRewards;
    /// @notice Staker reward per token paid
    mapping(address account => mapping(uint256 index => uint256 amount)) public override userRewardPerTokenPaid;
    /// @notice Track voting
    mapping(address account => mapping(uint256 epoch => Checkpoint)) private _checkpoints;
    mapping(address account => uint256 number) public override numCheckpoints;

    constructor(
        address _rescuer,
        address _executor,
        address _stakingToken,
        address _rewardToken
    ) TempleElevatedAccess(_rescuer, _executor){
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }
    
    /**
     * @notice Set vesting period for stakers
     * @param _period Vesting period
     */
    function setVestingPeriod(uint32 _period) external override onlyElevatedAccess {
        if (_period < WEEK_LENGTH) { revert CommonEventsAndErrors.InvalidParam(); }
        // only change after reward epoch ends
        if (rewardData.periodFinish >= block.timestamp) { revert InvalidOperation(); }
        vestingPeriod = _period;
        emit VestingPeriodSet(_period);
    }

    /**
     * @notice Set reward duration
     * @param _duration Reward duration
     */
    function setRewardDuration(uint256 _duration) external override onlyElevatedAccess {
        // minimum reward duration
        if (_duration < WEEK_LENGTH) { revert CommonEventsAndErrors.InvalidParam(); }
        // only change after reward epoch ends
        if (rewardData.periodFinish >= block.timestamp) { revert InvalidOperation(); }
        rewardDuration = _duration;
        emit RewardDurationSet(_duration);
    }

    /**
     * @notice Set starter of rewards distribution for the next epoch
     * @dev If starter is address zero, anyone can call `distributeRewards` to apply and 
     * distribute rewards for next reward duration
     * @param _starter Starter address
     * @dev could be:
     * 1. a bot (if set to non zero address) that checks requirements are met before starting auction
     * 2. or anyone if set to zero address
     */
    function setDistributionStarter(address _starter) external onlyElevatedAccess {
        /// @notice Starter can be address zero
        distributionStarter = _starter;
        emit DistributionStarterSet(_starter);
    }

    /**
     * @notice Set migrator
     * @param _migrator Migrator
     */
    function setMigrator(address _migrator) external override onlyElevatedAccess {
        if (_migrator == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        migrator = _migrator;
        emit MigratorSet(_migrator);
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) external override {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Set reward distribution cooldown
     * @param _cooldown Cooldown in seconds
     */
    function setRewardDistributionCoolDown(uint160 _cooldown) external override onlyElevatedAccess {
        /// @dev zero cooldown is allowed
        rewardDistributionCoolDown = _cooldown;
        emit RewardDistributionCoolDownSet(_cooldown);
    }

    /**
      * @notice For migrations to a new staking contract
      *         1. Withdraw `staker`s tokens to the new staking contract (the migrator)
      *         2. Any existing rewards are claimed and sent directly to the `staker`
      * @dev Called only from the new staking contract (the migrator).
      *      `setMigrator(new_staking_contract)` needs to be called first
      * @param staker The staker who is being migrated to a new staking contract.
      * @param index Index of stake to withdraw
      */
    function migrateWithdraw(address staker, uint256 index) external override onlyMigrator returns (uint256) {
        if (staker == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        StakeInfo storage _stakeInfo = _stakeInfos[staker][index];
        uint256 stakerBalance = _stakeInfo.amount;
        _withdrawFor(_stakeInfo, staker, msg.sender, index, _stakeInfo.amount, true, staker);
        return stakerBalance;
    }
    
    /**
     * @notice Distributed TGLD rewards minted to this contract to stakers
     * @dev This starts another epoch of rewards distribution. Calculates new `rewardRate` from any left over rewards up until now
     */

     //q- why are we passing in address(0) and 0?
    function distributeRewards() updateReward(address(0), 0) external {
        if (distributionStarter != address(0) && msg.sender != distributionStarter) 
            { revert CommonEventsAndErrors.InvalidAccess(); }
        if (totalSupply == 0) { revert NoStaker(); }
        // Mint and distribute TGLD if no cooldown set
        if (lastRewardNotificationTimestamp + rewardDistributionCoolDown > block.timestamp) 
                { revert CannotDistribute(); }
        _distributeGold();
        uint256 rewardAmount = nextRewardAmount;
        // revert if next reward is 0 or less than reward duration (final dust amounts)
        if (rewardAmount < rewardDuration ) { revert CommonEventsAndErrors.ExpectedNonZero(); }
        nextRewardAmount = 0;
        _notifyReward(rewardAmount);
        lastRewardNotificationTimestamp = uint32(block.timestamp);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
     //q- what are checkpoints?
    function getCurrentVotes(address account) external override view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? _checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint256 blockNumber) external override view returns (uint256) {
        if (blockNumber >= block.number) { revert InvalidBlockNumber(); }

        uint256 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (_checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return _checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (_checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = _checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return _checkpoints[account][lower].votes;
    }

    /**
     * @notice Stake
     * @param amount Amount of staking token
     */
    function stake(uint256 amount) external override {
        stakeFor(msg.sender, amount);
    }

    /**
     * @notice Stake for account when contract is not paused.
     * @param _for Account to stake for
     * @param _amount Amount of staking token
     */
    
    //@audit - not checking _for != address(0)  allows for griefing attacks
    function stakeFor(address _for, uint256 _amount) public whenNotPaused {
        //q- Do we check if for == msg.sender?
        //a- we allow staking for another account
        if (_amount == 0) revert CommonEventsAndErrors.ExpectedNonZero();
        
        // pull tokens and apply stake
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _lastIndex = _accountLastStakeIndex[_for];
        _accountLastStakeIndex[_for] = ++_lastIndex; //q-what is last stake Index for ?
        _applyStake(_for, _amount, _lastIndex);
        _moveDelegates(address(0), delegates[_for], _amount);
    }

    /**
     * @notice Withdraw staked tokens
     * @param amount Amount to withdraw
     * @param claim Boolean if to claim rewards
     */
    function withdraw(uint256 amount, uint256 index, bool claim) external override {
        StakeInfo storage _stakeInfo = _stakeInfos[msg.sender][index];
        _withdrawFor(_stakeInfo, msg.sender, msg.sender, index, amount, claim, msg.sender);
    }

    /**
     * @notice Withdraw all staked tokens
     * @param claim Boolean if to claim rewards
     */
    function withdrawAll(uint256 stakeIndex, bool claim) external override {
        StakeInfo storage _stakeInfo = _stakeInfos[msg.sender][stakeIndex];
        _withdrawFor(_stakeInfo, msg.sender, msg.sender, stakeIndex, _stakeInfo.amount, claim, msg.sender);
    }

    /// @notice Owner can pause user swaps from occuring
    function pause() external override onlyElevatedAccess {
        _pause();
    }

    /// @notice Owner can unpause so user swaps can occur
    function unpause() external override onlyElevatedAccess {
        _unpause();
    }

    /**
     * @notice Get last stake index for account
     * @param account Account
     * @return Last stake index
     */
    function getAccountLastStakeIndex(address account) external override view returns (uint256) {
        return _accountLastStakeIndex[account];
    }

    /**
     * @notice Get account stake info
     * @param account Account
     * @return Stake info
     */
    function getAccountStakeInfo(address account, uint256 index) external override view returns (StakeInfo memory) {
        return _stakeInfos[account][index];
    }

    /**
     * @notice Get account checkpoint data 
     * @param account Account
     * @param epoch Epoch
     * @return Checkpoint data
     */
    function getCheckpoint(address account, uint256 epoch) external override view returns (Checkpoint memory) {
        return _checkpoints[account][epoch];
    }

    /**
     * @notice Get account staked balance
     * @param account Account
     * @return Staked balance of account
     */
    function balanceOf(address account) public override view returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Get account staked balance
     * @param account Account
     * @param stakeIndex Staked index
     * @return Staked balance of account
     */
    function stakeBalanceOf(address account, uint256 stakeIndex) external override view returns (uint256) {
        StakeInfo storage stakeInfo = _stakeInfos[account][stakeIndex];
        return stakeInfo.amount;
    }

    /**
     * @notice Get earned rewards of account
     * @param account Account
     * @param index Index
     * @return Earned rewards of account
     */
    function earned(address account, uint256 index) external override view returns (uint256) {
        StakeInfo memory _stakeInfo =  _stakeInfos[account][index];
        return _earned(_stakeInfo, account, index);
    }

    /**
     * @notice Get Temple Gold reward per token of Temple 
     * @return Reward per token
     */
    function rewardPerToken() external override view returns (uint256) {
        return _rewardPerToken();
    }

    /**
     * @notice Get finish timestamp of rewards
     * @return Finish timestamp
     */
    function rewardPeriodFinish() external view returns (uint40) {
        return rewardData.periodFinish;
    }

    /**
     * @notice Elevated access can recover tokens which are not staking or reward tokens
     * @param _token Token to recover
     * @param _to Recipient
     * @param _amount Amount of tokens
     */
    function recoverToken(address _token, address _to, uint256 _amount) external override onlyElevatedAccess {
        if (_token == address(stakingToken) || _token == address(rewardToken )) 
            { revert CommonEventsAndErrors.InvalidAddress(); }

        IERC20(_token).safeTransfer(_to, _amount);
        emit CommonEventsAndErrors.TokenRecovered(_to, _token, _amount);
    }

    /**  
     * @notice Get rewards
     * @param staker Staking account
     * @param index Index
     */
    //q- why can anyone call this function?
    //q- Can't we just call getReward for another staker to claim their early?
    //a- yes we can, but this does not withdraw their stake and does not neccesarily cause any harm.

    //@audit-low- allowing third parties to trigger reward distributions for users is not ideal and could have tax implications
    //and unwanted consequences.
    function getReward(address staker, uint256 index) external override updateReward(staker, index) {
        _getReward(staker, staker, index);
    }

    /**  
     * @notice Mint and distribute Temple Gold rewards 
     */
    function distributeGold() external {
        _distributeGold();
    }

    /**  
     * @notice Notify rewards distribution. Called by TempleGold contract after successful mint
     * @param amount Amount minted to this contract
     */
    function notifyDistribution(uint256 amount) external {
        if (msg.sender != address(rewardToken)) { revert CommonEventsAndErrors.InvalidAccess(); }
        /// @notice Temple Gold contract mints TGLD amount to contract before calling `notifyDistribution`
        nextRewardAmount += amount;
        emit GoldDistributionNotified(amount, block.timestamp);
    }
    
    /**  
     * @notice Get reward data
     * @return Reward data
     */
    function getRewardData() external override view returns (Reward memory) {
        return rewardData;
    }

    function _getReward(address staker, address rewardsToAddress, uint256 index) internal {
        uint256 amount = claimableRewards[staker][index];
        if (amount > 0) {
            claimableRewards[staker][index] = 0;
            rewardToken.safeTransfer(rewardsToAddress, amount);
        }
            emit RewardPaid(staker, rewardsToAddress, index, amount);
    }

    function _withdrawFor(
        StakeInfo storage stakeInfo,
        address staker,
        address toAddress,
        uint256 stakeIndex,
        uint256 amount,
        bool claimRewards,
        address rewardsToAddress
    ) internal updateReward(staker, stakeIndex) {
        if (amount == 0) { revert CommonEventsAndErrors.ExpectedNonZero(); }
        uint256 _stakeAmount = stakeInfo.amount;
        if (_stakeAmount < amount) 
            { revert CommonEventsAndErrors.InsufficientBalance(address(stakingToken), amount, _stakeAmount); }

        unchecked {
            stakeInfo.amount = _stakeAmount - amount;
        }
        _balances[staker] -= amount;
        totalSupply -= amount;
        _moveDelegates(delegates[staker], address(0), amount);

        stakingToken.safeTransfer(toAddress, amount);
        emit Withdrawn(staker, toAddress, stakeIndex, amount);

        if (claimRewards) {
            // can call internal because user reward already updated
            _getReward(staker, rewardsToAddress, stakeIndex);
        }
    }

    function _earned(
        StakeInfo memory _stakeInfo,
        address _account,
        uint256 _index
    ) internal view returns (uint256) {
        uint256 vestingRate = _getVestingRate(_stakeInfo);
        if (vestingRate == 0) {
            return 0;
        }
        uint256 _perTokenReward;
        if (vestingRate == 1e18) { 
            _perTokenReward = _rewardPerToken();
        } else { 
            _perTokenReward = _rewardPerToken() * vestingRate / 1e18;
        }
        
        //Ok From this it seems the intention is that our debt is userRewardPerTokePaid, but this seems odd in our 
        //article I had the impression we subtract our debt when a user wants to withdraw.

            (_stakeInfo.amount * (_perTokenReward - userRewardPerTokenPaid[_account][_index])) / 1e18 +
            claimableRewards[_account][_index];
    }

    function _getVestingRate(StakeInfo memory _stakeInfo) internal view returns (uint256 vestingRate) {
        if (_stakeInfo.stakeTime == 0) {
            return 0;
        }
        if (block.timestamp > _stakeInfo.fullyVestedAt) {
            vestingRate = 1e18;
        } else {
            vestingRate = (block.timestamp - _stakeInfo.stakeTime) * 1e18 / vestingPeriod;
        }
    }

    function _applyStake(address _for, uint256 _amount, uint256 _index) internal updateReward(_for, _index) {
        totalSupply += _amount;
        _balances[_for] += _amount;
        _stakeInfos[_for][_index] = StakeInfo(uint64(block.timestamp), uint64(block.timestamp + vestingPeriod), _amount);
        //q- we say that the full vested time is block.timestamp + vestingPerioud is this correct?
        emit Staked(_for, _amount);
    }

    function _rewardPerToken() internal view returns (uint256) {
        if (totalSupply == 0) {
            return rewardData.rewardPerTokenStored;
        }

        //rewardData.rewardPerTokenStored +
        //(_lastTimeRewardApplicable(rewardData.periodFinish)) - This should be the last time we updated our rewardPerToken
        //why are we passing in rewardData.periodFinish?? (this is most likely for vesting rate hmmmm)

        //Assuming period Finish is < block.timestamp this equation tunrns out to 

        //rewardData.rewardPerTokenStored + (block.timestamp - rewardData.lastUpdateTime) * rewardRate( aka reward/block) / totalSuply
        //This correctly follows our formula

        return
            rewardData.rewardPerTokenStored +
            (((_lastTimeRewardApplicable(rewardData.periodFinish) -
                rewardData.lastUpdateTime) *
                rewardData.rewardRate * 1e18)
                / totalSupply);
    }

    function _notifyReward(uint256 amount) private {
        if (block.timestamp >= rewardData.periodFinish) {
            rewardData.rewardRate = uint216(amount / rewardDuration);
            // collect dust
            nextRewardAmount = amount - (rewardData.rewardRate * rewardDuration);
        } else {
            uint256 remaining = uint256(rewardData.periodFinish) - block.timestamp;
            uint256 leftover = remaining * rewardData.rewardRate;
            rewardData.rewardRate = uint216((amount + leftover) / rewardDuration);
            // collect dust
            nextRewardAmount = (amount + leftover) - (rewardData.rewardRate * rewardDuration);
        }
        rewardData.lastUpdateTime = uint40(block.timestamp);
        rewardData.periodFinish = uint40(block.timestamp + rewardDuration);
    }

    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns (uint256) {
        if (_finishTime < block.timestamp) {
            return _finishTime;
        }
        return block.timestamp;
    }

    function _distributeGold() internal {
        /// @dev no op silent fail if nothing to distribute
        ITempleGold(address(rewardToken)).mint();
    }

    //delegator is me, delegatee is who I'm sending my votes to
    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates[delegator];
        uint256 delegatorBalance = _balances[delegator];
        delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);
        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(
        address srcRep,
        address dstRep,
        uint256 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint256 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? _checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld - amount;
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint256 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? _checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld + amount;
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint256 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        if (nCheckpoints > 0 && _checkpoints[delegatee][nCheckpoints - 1].fromBlock == block.number) {
            _checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            _checkpoints[delegatee][nCheckpoints] = Checkpoint(block.number, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        } 
        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    modifier updateReward(address _account, uint256 _index) {
        {
            // stack too deep
            rewardData.rewardPerTokenStored = uint216(_rewardPerToken()); //Update our rewardPerToken 
            rewardData.lastUpdateTime = uint40(_lastTimeRewardApplicable(rewardData.periodFinish)); //Update our reward Distribution time/ Keep track of how much time has passed.
            if (_account != address(0)) {
                StakeInfo memory _stakeInfo = _stakeInfos[_account][_index];
                uint256 vestingRate = _getVestingRate(_stakeInfo);
                //our claimable rewards should be then rewardPerToken * account Balance
                claimableRewards[_account][_index] = _earned(_stakeInfo, _account, _index);
                

                //Lets say our vesting period is 10 hours, our rewardPerHour is 100, and our user stakes 50 Token
                //Initially our vesting rate is 0% so this does 0 * x = 0 (look at below line of code)
                //so Intially userRewardPerTokenPaid is 0, and our global rewardPerToken is 0

                //At T=5(hours), Lets say our user deposits and we update state. We expect our user to be half vested, with a vesting rate of 50%.
                //We have accumulated 500 Reward (100 * 5) and so our reward per Token is 500 Reward / 50 Token = 10 RPT
                
                //The below code says that our UserRewardPerTokenPaid 0.5 * 10 = 5RPT

                //_perTokenReward = RPT * vestingRate = 5 * 0.5 = 2.5

                //The above code says our user earned 50 * (5 - 2.5) = 125

                //At T=6, our user updates state again. In that time we got 100RewardPerHour.
                //So we accumulated 100 Reward and our TotalReward is 500+ 100 = 600, and our RPT is 600/50 = 12
                // so our UserRewardPerTokenPaid is 0.6 * 12 = 6RPT.
                //_perTokenReward = RPT * vestingRate = 6 * 0.6 = 3.6

                //our above code says we earned 50 * (6 - 3.6) = 270 
                
                userRewardPerTokenPaid[_account][_index] = vestingRate * uint256(rewardData.rewardPerTokenStored) / 1e18; 
            }
        }
        _;
    }
    
    modifier onlyMigrator() {
        if (msg.sender != migrator) { revert CommonEventsAndErrors.InvalidAccess(); }
        _;
    }
}