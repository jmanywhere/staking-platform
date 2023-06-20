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
error GeneralStaking__InvalidTransfer();
error GeneralStaking__InvalidPoolApr(uint256 _poolApr);
error GeneralStaking__InvalidWithdrawLockPeriod(uint256 _withdrawLockPeriod);
error GeneralStaking__InvalidAmount();
error GeneralStaking__InvalidEarlyWithdrawFee();
error GeneralStaking__InvalidSettings();

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
    uint256 public constant FEE_BASE = 100;
    uint256 public constant BASE_APR = 100_00; // 100% APR
    uint256 public constant APR_TIME = 365 days;
    uint256 public constant REWARD_DENOMINATOR = 100_00 * 365 days;
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
    event EarlyWithdrawalUpdate(uint _old, uint _new);
    event TreasureAdded();
    event RewardsPaid();
    event PoolUpdated();
    event EditPool(
        uint indexed poolId,
        uint256 newApr,
        uint256 newWithdrawLockPeriod
    );
    event PoolAdd(uint _poolIdAdded);

    //---------------------------------------------
    //   Constructor
    //---------------------------------------------
    constructor(address _rewardToken) {
        token = IERC20(_rewardToken);
    }

    //---------------------------------------------
    //   External Functions
    //---------------------------------------------
    function deposit(uint _pid, uint amount) external nonReentrant {
        if (amount == 0) revert GeneralStaking__InsufficientDepositAmount();

        PoolInfo storage pool = poolInfo[_pid];

        if (_pid > totalPools || pool.poolApr == 0)
            revert GeneralStaking__InvalidPoolId(_pid);

        UserInfo storage user = userInfo[_pid][msg.sender];

        _updateAndPayOrLock(msg.sender, _pid);

        user.depositAmount += amount;

        user.rewardDebt = pool.accAprOverTime * user.depositAmount;
        user.lastInteraction = block.timestamp;
        user.lastDeposit = block.timestamp;
        pool.totalDeposit += amount;

        if (!token.transferFrom(msg.sender, address(this), amount))
            revert GeneralStaking__InvalidTransferFrom();

        emit Deposit(msg.sender, _pid, amount);
    }

    function withdraw(uint _pid) external nonReentrant {
        if (_pid > totalPools) revert GeneralStaking__InvalidPoolId(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _updateAndPayOrLock(msg.sender, _pid);

        uint256 amount = user.depositAmount;
        uint penalty = 0;

        if (!_canHarvest(user.lastDeposit, pool.withdrawLockPeriod)) {
            rewardTokens += user.rewardLockedUp;
            penalty = (amount * earlyWithdrawFee) / FEE_BASE;
            amount -= penalty;
        }
        pool.totalDeposit -= user.depositAmount;

        userInfo[_pid][msg.sender] = UserInfo({
            depositAmount: 0,
            rewardDebt: 0,
            rewardLockedUp: 0,
            lastInteraction: block.timestamp,
            lastDeposit: 0
        });

        _safeTokenTransfer(msg.sender, amount);
        if (penalty > 0) _safeTokenTransfer(marketingAddress, penalty);
        emit Withdraw(msg.sender, _pid, amount);
    }

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
        if (_withdrawLockPeriod > 365)
            revert GeneralStaking__InvalidWithdrawLockPeriod(
                _withdrawLockPeriod
            );
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

    /**
     *
     * @param _poolId The id to edit
     * @param _poolApr the new pool APR, if 0, the pool is disabled to deposit
     * @param _withdrawLockPeriod the new lock period. if 0, lock is removed. I think max should be 1 year.
     */
    function editPool(
        uint256 _poolId,
        uint256 _poolApr,
        uint256 _withdrawLockPeriod
    ) external onlyOwner {
        if (_poolId > totalPools) revert GeneralStaking__InvalidPoolId(_poolId);
        if (_withdrawLockPeriod > 365)
            revert GeneralStaking__InvalidWithdrawLockPeriod(
                _withdrawLockPeriod
            );
        _updatePool(_poolId);
        _withdrawLockPeriod *= 1 days; // value in seconds
        poolInfo[_poolId].poolApr = _poolApr;
        poolInfo[_poolId].withdrawLockPeriod = _withdrawLockPeriod;
        emit EditPool(_poolId, _poolApr, _withdrawLockPeriod);
    }

    /**
     * @param _marketingAddress The new address to send marketing funds to
     */
    function setMarketingAddress(address _marketingAddress) external onlyOwner {
        marketingAddress = _marketingAddress;
        emit MarketingWalletUpdate();
    }

    /**
     * @param _earlyWithdrawFee The new fee to be charged for early withdraws
     */
    function setEarlyWithdrawFee(uint256 _earlyWithdrawFee) external onlyOwner {
        if (_earlyWithdrawFee > 20)
            revert GeneralStaking__InvalidEarlyWithdrawFee();
        emit EarlyWithdrawalUpdate(earlyWithdrawFee, _earlyWithdrawFee);
        earlyWithdrawFee = _earlyWithdrawFee;
    }

    /**
     * Last resort to recover any tokens that were destined for rewards
     * @param _to The address to send the tokens to
     */
    function recoverTreasure(address _to) external onlyOwner {
        if (_to == address(0) || rewardTokens == 0)
            revert GeneralStaking__InvalidSettings();
        if (!token.transfer(_to, rewardTokens))
            revert GeneralStaking__InvalidTransfer();
        rewardTokens = 0;
        emit TreasureRecovered();
    }

    /**
     * Add tokens for rewards in the pool
     * @param _rewardTokens The amount of tokens to add to the reward pool
     */
    function addRewardTokens(uint256 _rewardTokens) external {
        if (_rewardTokens == 0) revert GeneralStaking__InvalidAmount();
        rewardTokens += _rewardTokens;

        if (!token.transferFrom(msg.sender, address(this), _rewardTokens))
            revert GeneralStaking__InvalidTransferFrom();
    }

    //---------------------------------------------
    //   Internal Functions
    //---------------------------------------------
    /**
     *
     * @param _poolId The pool ID to update values for
     * @dev Updates the current pool reward amount
     */
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

    /**
     * @notice This function exists to prevent rounding error issues
     * @param _to Address to send the funds to
     * @param _amount amount of Reward Token to send to _to address
     */
    function _safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            token.transfer(_to, tokenBal);
        } else {
            token.transfer(_to, _amount);
        }
    }

    function _payOrLockTokens(address _user, uint _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint pending = ((pool.accAprOverTime * user.depositAmount) -
            user.rewardDebt) / REWARD_DENOMINATOR;

        if (_canHarvest(user.lastDeposit, pool.withdrawLockPeriod)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                pending += user.rewardLockedUp;
                user.rewardLockedUp = 0;
                _safeTokenTransfer(_user, pending);
                emit RewardsPaid();
            } else if (pending > 0) {
                user.rewardLockedUp += pending;
                emit RewardLockedUp(_user, _pid, pending);
            }
        }
    }

    function _updateAndPayOrLock(address _user, uint _pid) internal {
        _updatePool(_pid);
        _payOrLockTokens(_user, _pid);
    }

    function _canHarvest(
        uint lastDeposit,
        uint withdrawLock
    ) internal view returns (bool) {
        return lastDeposit + withdrawLock < block.timestamp;
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
        if (rewardsPerSecond == 0 || rewardTokens == 0) return 0;
        return rewardTokens / rewardsPerSecond;
    }

    /**
     * @notice This function returns the pending Rewards for a specific user in a pool
     * @param _pid The pool Id to check
     * @param _userAddress The user address to check
     */
    function pendingReward(
        uint _pid,
        address _userAddress
    ) external view returns (uint256) {
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
            (REWARD_DENOMINATOR);
    }
}
