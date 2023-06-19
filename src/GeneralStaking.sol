// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

//---------------------------------------------
//   Imports
//---------------------------------------------
import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/security/ReentrancyGuard.sol";

//---------------------------------------------
//   Errors
//---------------------------------------------
error GeneralStaking__InsufficientDepositAmount();
error GeneralStaking__InvalidPoolId(uint256 _poolId);
error GeneralStaking__InvalidTransferFrom();
error GeneralStaking__InvalidPoolApr(uint256 _poolApr);

//---------------------------------------------
//   Main Contract
//---------------------------------------------
/**
 * @title GeneralStaking contract has masterchef like functions
 * @author CFG-Ninja - SemiInvader
 * @notice This contract allows the creation of pools that deliver a specific APR for any user staking in it.
 *          It is the job of the owner to keep enough funds on the contract to pay the rewards.
 */

contract GeneralStaking is Ownable, ReentrancyGuard {
    //---------------------------------------------
    //   Type Definitions
    //---------------------------------------------
    struct UserInfo {
        uint256 depositAmount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 lastInteraction; // Last time the user interacted with the contract.
        uint256 lastDeposit; // Last time the user deposited.
        // We also removed debt, since we're working only with APRs, there's no need to keep track of debt.
    }

    struct PoolInfo {
        uint256 poolApr; // APR for the pool.
        uint256 totalDeposit; // Total amount of tokens deposited in the pool.
        uint256 withdrawLockPeriod; // Time in seconds that the user has to wait to withdraw.
        uint256 accAprOverTime; // Accumulated apr in a specific amount of time, times 1e12 for
        uint256 lastUpdate; // Last time the pool was updated.
    }
    //---------------------------------------------
    //   State Variables
    //---------------------------------------------
    // Info of each pool (APR, total deposit, withdraw lock period
    mapping(uint256 _poolId => PoolInfo pool) public poolInfo;
    // Track userInfo per pool
    mapping(uint256 _poolId => mapping(address _userAddress => UserInfo info))
        public userInfo;
    // Track all current pools

    address public marketingAddress; // Address to send marketing funds to.
    IERC20 public token; // Main token reward to be distributed
    uint256 public totalPools; // Total amount of pools
    uint256 public rewardTokens; // Amount of tokens to be distributed
    uint256 public constant BASE_APR = 100_00; // 100% APR
    uint256 public startTimeStamp;
    uint256 public totalLockedUpRewards;
    uint256 public earlyWithdrawFee = 10;

    //---------------------------------------------
    //   Events
    //---------------------------------------------
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event AprUpdated(address indexed caller, uint256 poolId, uint256 newApr);
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );
    event TreasureRecovered();
    event MarketingWalletUpdate();
    event RewardUpdate();
    event EarlyWithdrawalUpdate();
    event TreasureAdded();
    event RewardsPaid();
    event PoolUpdated();
    event PoolSet();
    event PoolAdd(uint _poolIdAdded);

    //---------------------------------------------
    //   Constructor
    //---------------------------------------------
    constructor(address _rewardToken, uint256 _startTimestamp) {
        token = IERC20(_rewardToken);
        startTimeStamp = _startTimestamp;
    }

    //---------------------------------------------
    //   External Functions
    //---------------------------------------------
    function deposit(uint _pid, uint amount) external nonReentrant {
        if (amount == 0) revert GeneralStaking__InsufficientDepositAmount();
        if (_pid > totalPools) revert GeneralStaking__InvalidPoolId(_pid);

        UserInfo storage user = userInfo[_pid][msg.sender];
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolApr == 0) revert GeneralStaking__InvalidPoolId(_pid);
        _updatePool(_pid);

        // TODO check if user has already deposited and claim any rewards pending

        user.depositAmount += amount;

        user.rewardDebt = pool.accAprOverTime * user.depositAmount;
        user.lastInteraction = block.timestamp;
        user.lastDeposit = block.timestamp;
        pool.totalDeposit += amount;

        if (!token.transferFrom(msg.sender, address(this), amount))
            revert GeneralStaking__InvalidTransferFrom();

        emit Deposit(msg.sender, _pid, amount);
    }

    function withdraw(uint _pid) external nonReentrant {}

    function emergencyWithdraw(uint _pid) external nonReentrant {}

    function harvest(uint _pid) external nonReentrant {}

    /**
     * @notice add a pool to the list with the given APR and withdraw lock period
     * @param _poolApr APR that is assured for any user in the pool
     * @param _withdrawLockPeriod Time in days that the user has to wait to withdraw
     */
    function addPool(
        uint256 _poolApr,
        uint256 _withdrawLockPeriod
    ) external onlyOwner {
        if (_poolApr == 0) revert GeneralStaking__InvalidPoolApr(_poolApr);
        _withdrawLockPeriod *= 1 days; // value in seconds

        poolInfo[totalPools] = PoolInfo({
            poolApr: _poolApr,
            totalDeposit: 0,
            withdrawLockPeriod: _withdrawLockPeriod,
            accAprOverTime: 0,
            lastUpdate: block.timestamp
        });

        emit PoolAdd(totalPools);
        totalPools++;
    }

    function editPool(
        uint256 _poolId,
        uint256 _poolApr,
        uint256 _withdrawLockPeriod
    ) external onlyOwner {}

    function setMarketingAddress(
        address _marketingAddress
    ) external onlyOwner {}

    function setEarlyWithdrawFee(
        uint256 _earlyWithdrawFee
    ) external onlyOwner {}

    function recoverTreasure(address _to) external onlyOwner {}

    function addRewardTokens(uint256 _rewardTokens) external onlyOwner {}

    //---------------------------------------------
    //   Internal Functions
    //---------------------------------------------

    function _updatePool(uint256 _poolId) internal {
        PoolInfo storage pool = poolInfo[_poolId];

        if (block.timestamp > pool.lastUpdate && pool.poolApr > 0) {
            uint256 timePassed = (block.timestamp - pool.lastUpdate) *
                pool.poolApr;
            pool.accAprOverTime += timePassed;
        }
        pool.lastUpdate = block.timestamp;
        return;
    }

    //---------------------------------------------
    //   Private Functions
    //---------------------------------------------

    //---------------------------------------------
    //   External & Public View Functions
    //---------------------------------------------
    /// @notice  Request an APPROXIMATE amount of time until the contract runs out of funds on rewards
    /// @notice PLEASE NOTE THAT THIS IS AN APPROXIMATION, IT DOES NOT TAKE INTO ACCOUNT PENDING REWARDS NEEDED TO BE CLAIMED
    /// @return Returns the amount of seconds when the contract runs out of funds
    function timeToEmpty() external view returns (uint256) {
        uint allPools = totalPools;
        uint rewardsPerSecond = 0;
        for (uint i = 0; i < allPools; i++) {
            rewardsPerSecond +=
                (poolInfo[i].poolApr * poolInfo[i].totalDeposit) /
                (BASE_APR * 365 days);
        }
        return rewardTokens / rewardsPerSecond;
    }

    function pendingReward(
        uint _pid,
        address _userAddress
    ) public view returns (uint256) {
        if (_pid > totalPools) revert GeneralStaking__InvalidPoolId(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_userAddress];

        uint256 accAprOverTime = pool.accAprOverTime;
        uint256 poolApr = pool.poolApr;
        uint256 lastUpdate = pool.lastUpdate;

        if (block.timestamp > lastUpdate && poolApr > 0) {
            uint256 timePassed = (block.timestamp - lastUpdate) * poolApr;
            accAprOverTime += timePassed;
        }

        return
            ((accAprOverTime * user.depositAmount) - user.rewardDebt) /
            BASE_APR;
    }
}
