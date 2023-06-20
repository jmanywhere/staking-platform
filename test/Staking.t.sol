// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GeneralStaking.sol";
import "@openzeppelin/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract StakingUnitTest is Test {
    GeneralStaking staking;
    ERC20PresetFixedSupply token;

    address USER = makeAddr("user");
    address MKT = makeAddr("mkt");
    uint USER_DEPOSIT = 100 ether;
    uint timeDenominator = 365 days;
    uint POOL_FUND = 1_000_000 ether;

    //--------------------------------------------------------------
    // EVENTS
    //--------------------------------------------------------------
    event EditPool(
        uint indexed poolId,
        uint256 newApr,
        uint256 newWithdrawLockPeriod
    );
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event TreasureRecovered();

    //--------------------------------------------------------------
    // SETUP
    //--------------------------------------------------------------
    function setUp() public {
        token = new ERC20PresetFixedSupply(
            "test",
            "TEST",
            100_000_000 ether,
            USER
        );
        staking = new GeneralStaking(address(token), MKT);

        vm.deal(USER, USER_DEPOSIT);
        vm.startPrank(USER);
        token.transfer(address(this), POOL_FUND);
        token.approve(address(staking), POOL_FUND * 10);
        vm.stopPrank();
        token.approve(address(staking), POOL_FUND * 10);
    }

    function test_createPool() public {
        uint testTimestamp = block.timestamp;
        staking.addPool(15_00, 0);
        (
            uint apr,
            uint deposited,
            uint lockPeriod,
            uint accumulated,
            uint lastUpdate
        ) = staking.poolInfo(0);
        assertEq(apr, 1500);
        assertEq(deposited, 0);
        assertEq(lockPeriod, 0);
        assertEq(accumulated, 0);
        assertEq(lastUpdate, testTimestamp);

        skip(1 hours);
        testTimestamp = block.timestamp;

        staking.addPool(12_00, 1);

        assertEq(staking.totalPools(), 2);

        (apr, deposited, lockPeriod, accumulated, lastUpdate) = staking
            .poolInfo(1);
        assertEq(apr, 1200);
        assertEq(deposited, 0);
        assertEq(lockPeriod, 1 days);
        assertEq(accumulated, 0);
        assertEq(lastUpdate, testTimestamp);
    }

    function test_setMarketingWallet() public {
        assertEq(staking.marketingAddress(), MKT);
        staking.setMarketingAddress(address(2));
        assertEq(staking.marketingAddress(), address(2));
    }

    function test_setEarlyWithdrawFee() public {
        assertEq(staking.earlyWithdrawFee(), 10);
        staking.setEarlyWithdrawFee(15);
        assertEq(staking.earlyWithdrawFee(), 15);
        vm.expectRevert(GeneralStaking__InvalidEarlyWithdrawFee.selector);
        staking.setEarlyWithdrawFee(21);
    }

    function test_fundAllPools() public {
        staking.addPool(15_00, 0);
        vm.prank(USER);
        staking.addRewardTokens(POOL_FUND);

        assertEq(token.balanceOf(address(staking)), POOL_FUND);
        assertEq(token.balanceOf(address(staking)), staking.rewardTokens());
    }

    modifier poolAdded() {
        staking.addPool(15_00, 1);
        vm.prank(USER);
        staking.addRewardTokens(POOL_FUND);
        _;
    }

    function test_editPool() public poolAdded {
        vm.expectEmit();
        emit EditPool(0, 12_00, 1 days);
        staking.editPool(0, 12_00, 1);
        (
            uint apr,
            uint deposited,
            uint lockPeriod,
            uint accumulated,
            uint lastUpdate
        ) = staking.poolInfo(0);

        assertEq(apr, 1200);
        assertEq(deposited, 0);
        assertEq(lockPeriod, 1 days);
        assertEq(accumulated, 0);
        assertEq(lastUpdate, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                GeneralStaking__InvalidWithdrawLockPeriod.selector,
                366
            )
        );
        staking.editPool(0, 12_00, 366);
    }

    function test_NotDepositTokens() public poolAdded {
        // Invalid pool id
        vm.expectRevert(
            abi.encodeWithSelector(GeneralStaking__InvalidPoolId.selector, 3)
        );
        staking.deposit(3, USER_DEPOSIT);

        // Invalid  deposit amount
        vm.expectRevert(
            abi.encodeWithSelector(
                GeneralStaking__InsufficientDepositAmount.selector
            )
        );
        staking.deposit(0, 0);

        // Edit pool to disable it
        staking.editPool(0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(GeneralStaking__InvalidPoolId.selector, 0)
        );
        staking.deposit(0, USER_DEPOSIT);
    }

    function test_depositTokens() public poolAdded {
        uint initBalance = token.balanceOf(address(staking));
        // Deposit tokens
        vm.startPrank(USER);
        vm.expectEmit();
        emit Deposit(USER, 0, USER_DEPOSIT);
        staking.deposit(0, USER_DEPOSIT);
        vm.stopPrank();

        assertEq(token.balanceOf(address(staking)), initBalance + USER_DEPOSIT);
        (
            uint depositAmount,
            uint rewardDebt,
            uint lockedUp,
            uint lastUpdate,
            uint lastDeposit
        ) = staking.userInfo(0, USER);

        assertEq(depositAmount, USER_DEPOSIT);
        assertEq(rewardDebt, 0);
        assertEq(lockedUp, 0);
        assertEq(lastUpdate, block.timestamp);
        assertEq(lastDeposit, block.timestamp);
    }

    modifier userDeposited() {
        vm.startPrank(USER);
        staking.deposit(0, USER_DEPOSIT);
        vm.stopPrank();
        _;
    }

    function test_rewardsBeingGenerated() public poolAdded userDeposited {
        skip(1 hours);
        uint userPendingReward = staking.pendingReward(0, USER);

        uint expectedReward = ((USER_DEPOSIT * 15) * 1 hours) /
            (100 * timeDenominator);

        assertEq(userPendingReward, expectedReward);
    }

    function test_withdrawWithEarlyFee() public poolAdded userDeposited {
        uint expectedWithdraw = (USER_DEPOSIT * 9) / 10;
        uint currentUserBalance = token.balanceOf(USER);
        vm.prank(USER);
        vm.expectEmit();
        emit Withdraw(USER, 0, expectedWithdraw);
        staking.withdraw(0);
        assertEq(token.balanceOf(USER), currentUserBalance + expectedWithdraw);
        assertEq(token.balanceOf(MKT), USER_DEPOSIT / 10);
    }

    function test_withdrawWithoutEarlyFee() public poolAdded userDeposited {
        skip(25 hours);
        uint currentUserBalance = token.balanceOf(USER);
        vm.prank(USER);
        vm.expectEmit();
        emit Withdraw(USER, 0, USER_DEPOSIT);
        staking.withdraw(0);
        // this is GT because it claims some rewards
        assertGt(token.balanceOf(USER), currentUserBalance + USER_DEPOSIT);
        assertEq(token.balanceOf(MKT), 0);
    }

    function test_recoverRewards() public poolAdded userDeposited {
        vm.expectEmit();
        emit TreasureRecovered();
        staking.recoverTreasure(address(2));
        assertEq(token.balanceOf(address(2)), POOL_FUND);

        vm.expectRevert(GeneralStaking__InvalidSettings.selector);
        staking.recoverTreasure(address(2));
    }

    function test_harvest() public poolAdded userDeposited {
        vm.startPrank(USER);

        skip(2 hours);
        uint expectedReward = ((USER_DEPOSIT * 15) * 2 hours) /
            (100 * timeDenominator);

        staking.harvest(0);

        (, , uint rewardLocked, , ) = staking.userInfo(0, USER);
        assertEq(rewardLocked, expectedReward);
        vm.stopPrank();
    }

    function test_harvestWhenLockEnds() public poolAdded userDeposited {
        vm.startPrank(USER);
        skip(25 hours);
        uint expectedReward = ((USER_DEPOSIT * 15) * 25 hours) /
            (100 * timeDenominator);
        uint baseWallet = token.balanceOf(USER);

        staking.harvest(0);

        (, , uint rewardLocked, , ) = staking.userInfo(0, USER);
        assertEq(rewardLocked, 0);
        assertEq(token.balanceOf(USER), baseWallet + expectedReward);
        vm.stopPrank();
    }
}
