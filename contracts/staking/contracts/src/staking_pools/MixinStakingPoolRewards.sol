/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.9;
pragma experimental ABIEncoderV2;

import "../libs/LibSafeMath.sol";
import "../libs/LibRewardMath.sol";
import "../immutable/MixinStorage.sol";
import "../immutable/MixinConstants.sol";
import "../stake/MixinStakeBalances.sol";
import "./MixinStakingPoolRewardVault.sol";
import "./MixinStakingPool.sol";


/// @dev This mixin contains logic for staking pool rewards.
/// Rewards for a pool are generated by their market makers trading on the 0x protocol (MixinStakingPool).
/// The operator of a pool receives a fixed percentage of all rewards; generally, the operator is the
/// sole market maker of a pool. The remaining rewards are divided among the members of a pool; each member
/// gets an amount proportional to how much stake they have delegated to the pool.
///
/// Note that members can freely join or leave a staking pool at any time, by delegating/undelegating their stake.
/// Moreover, there is no limit to how many members a pool can have. To limit the state-updates needed to track member balances,
/// we store only a single balance shared by all members. This state is updated every time a reward is paid to the pool - which
/// is currently at the end of each epoch. Additionally, each member has an associated "Shadow Balance" which is updated only
/// when a member delegates/undelegates stake to the pool, along with a "Total Shadow Balance" that represents the cumulative
/// Shadow Balances of all members in a pool.
///
/// -- Member Balances --
/// Terminology:
///     Real Balance - The reward balance in ETH of a member.
///     Total Real Balance - The sum total of reward balances in ETH across all members of a pool.
///     Shadow Balance - The realized reward balance of a member.
///     Total Shadow Balance - The sum total of realized reward balances across all members of a pool.
/// How it works:
/// 1. When a member delegates, their ownership of the pool increases; however, this new ownership applies
///    only to future rewards and must not change the rewards currently owned by other members. Thus, when a
///    member delegates stake, we *increase* their Shadow Balance and the Total Shadow Balance of the pool.
///
/// 2. When a member withdraws a portion of their reward, their realized balance increases but their ownership
///    within the pool remains unchanged. Thus, we simultaneously *decrease* their Real Balance and
///    *increase* their Shadow Balance by the amount withdrawn. The cumulative balance decrease and increase, respectively.
///
/// 3. When a member undelegates, the portion of their reward that corresponds to that stake is also withdrawn. Thus,
///    their realized balance *increases* while their ownership of the pool *decreases*. To reflect this, we
///    decrease their Shadow Balance, the Total Shadow Balance, their Real Balance, and the Total Real Balance.
contract MixinStakingPoolRewards is
    IStakingEvents,
    MixinDeploymentConstants,
    Ownable,
    MixinConstants,
    MixinStorage,
    MixinScheduler,
    MixinOwnable,
    MixinStakingPoolRewardVault,
    MixinZrxVault,
    MixinStakingPool,
    MixinStakeBalances
{

    using LibSafeMath for uint256;

    /// @dev Computes the reward balance in ETH of a specific member of a pool.
    /// @param poolId Unique id of pool.
    /// @param member The member of the pool.
    /// @return Balance.
    function computeRewardBalanceOfStakingPoolMember(bytes32 poolId, address member)
        public
        view
        returns (uint256)
    {
        IStructs.StoredStakeBalance memory delegatedStake = delegatedStakeToPoolByOwner[member][poolId];
        if (getCurrentEpoch() == 0 || delegatedStake.lastStored == getCurrentEpoch()) return 0;

        // `current` leg
        uint256 totalReward = 0;
        if (delegatedStake.current != 0) {
            uint256 beginEpoch = delegatedStake.lastStored - 1;
            uint endEpoch = delegatedStake.lastStored;
            IStructs.ND memory beginRatio = rewardRatioSums[beginEpoch];
            IStructs.ND memory endRatio = rewardRatioSums[endEpoch];
            uint256 rewardRatioN = ((endRatio.numerator * beginRatio.denominator) - (beginRatio.numerator * endRatio.denominator));
            uint256 rewardRatio = (delegatedStake.current * (rewardRatioN / beginRatio.denominator)) / endRatio.denominator;
            totalReward += rewardRatio;
        }

        // `next` leg
        {
            uint256 beginEpoch = delegatedStake.lastStored;
            uint endEpoch = uint256(getCurrentEpoch()) - 1;
            IStructs.ND memory beginRatio = rewardRatioSums[beginEpoch];
            IStructs.ND memory endRatio = rewardRatioSums[endEpoch];
            uint256 rewardRatioN = ((endRatio.numerator * beginRatio.denominator) - (beginRatio.numerator * endRatio.denominator));
            uint256 rewardRatio = (delegatedStake.next * (rewardRatioN / beginRatio.denominator)) / endRatio.denominator;
            totalReward += rewardRatio;
        }

        return totalReward;
    }

    /// @dev Computes the reward balance in ETH of a specific member of a pool.
    /// @param poolId Unique id of pool.
    /// @param member The member of the pool.
    /// @return Balance.
    function syncRewardBalanceOfStakingPoolMember(bytes32 poolId, address member)
        public
    {
        uint256 balance = computeRewardBalanceOfStakingPoolMember(poolId, member);
        if (balance == 0) {
            return;
        }

        // Pay the delegator
        require(address(rewardVault) != address(0), 'eyo');
        rewardVault.transferMemberBalanceToEthVault(poolId, member, balance);

        // Remove the reference
    }

/*
    /// @dev Computes the reward balance in ETH of a specific member of a pool.
    /// @param poolId Unique id of pool.
    /// @param member The member of the pool.
    /// @return Balance.
    function syncRewardBalanceOfStakingPoolOperator(bytes32 poolId)
        public
        view
        returns (uint256)
    {
        uint256 balance = computeRewardBalanceOfStakingPoolMember(poolId, member);

        // Pay the delegator


        // Remove the reference


    }
    */
}
