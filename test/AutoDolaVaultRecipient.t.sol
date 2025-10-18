// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";

// Mock contracts for testing (reusing from AutoDolaYieldStrategy.t.sol)
contract MockAutoDOLA is MockERC20 {
    mapping(address => uint256) private _balances;
    uint256 private _totalAssets;
    uint256 private _totalShares;
    address private _asset;
    address private _rewarder;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
        _totalAssets = 1000000e18; // Start with 1M DOLA worth of assets
        _totalShares = 1000000e18; // 1:1 initial ratio
        _asset = asset_;
        _rewarder = rewarder_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _mint(receiver, shares);
        _balances[receiver] += shares;
        _totalShares += shares;
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(_balances[owner] >= shares, "Insufficient shares");

        assets = convertToAssets(shares);
        _burn(owner, shares);
        _balances[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * _totalShares) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0) return shares;
        return (shares * _totalAssets) / _totalShares;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }

    // Simulate yield growth
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
    }
}

contract MockMainRewarder {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _rewards;
    uint256 private _totalSupply;
    address private _rewardToken;

    constructor(address rewardTokenAddr) {
        _rewardToken = rewardTokenAddr;
    }

    function stake(address user, uint256 amount) external {
        _balances[user] += amount;
        _totalSupply += amount;
    }

    function withdraw(address user, uint256 amount, bool claim) external {
        require(_balances[user] >= amount, "Insufficient staked balance");
        _balances[user] -= amount;
        _totalSupply -= amount;

        // If claim is true, also claim pending rewards
        if (claim && _rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(user, reward);
        }
    }

    function earned(address user) external view returns (uint256) {
        return _rewards[user];
    }

    function getReward(address account, address recipient, bool claimExtras) external returns (bool) {
        uint256 reward = _rewards[account];
        _rewards[account] = 0;
        if (reward > 0) {
            MockERC20(_rewardToken).transfer(recipient, reward);
        }
        return true;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    function simulateRewards(address user, uint256 amount) external {
        _rewards[user] += amount;
        MockERC20(_rewardToken).mint(address(this), amount);
    }
}

/**
 * @title AutoDolaVaultRecipientTest
 * @notice Tests verifying that deposits track by recipient and withdrawals track by msg.sender
 * @dev Addresses the critical tracking discrepancy identified in parent story 005's unit test quality review
 */
contract AutoDolaVaultRecipientTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client1 = address(0x5678);
    address client2 = address(0x9ABC);
    address alice = address(0xAA);
    address bob = address(0xBB);

    uint256 constant INITIAL_DOLA_SUPPLY = 10000000e18; // 10M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18;  // 1M TOKE

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy the actual vault
        vm.prank(owner);
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Mint tokens to test addresses
        dolaToken.mint(client1, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(client2, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY);

        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vm.stopPrank();
    }

    /**
     * @notice Test that deposits track the recipient parameter, not the caller (msg.sender)
     * @dev This is the critical tracking mechanism: client1 (caller) deposits FOR alice (recipient)
     */
    function testAutoDolaDepositTracksRecipientNotCaller() public {
        uint256 depositAmount = 1000e18;

        // client1 approves the vault to spend their DOLA
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);

        // CRITICAL: client1 deposits FOR alice (recipient)
        // The balance should be tracked under alice, NOT client1
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, alice);

        // ASSERTION: alice (recipient) should have the balance, not client1 (caller)
        assertEq(vault.balanceOf(address(dolaToken), alice), depositAmount, "Recipient should have the balance");
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Caller should NOT have the balance");

        // Verify DOLA was transferred from the caller (client1)
        assertEq(dolaToken.balanceOf(client1), INITIAL_DOLA_SUPPLY - depositAmount, "DOLA should be taken from caller");
    }

    /**
     * @notice Test that withdrawals check the recipient's balance in the vault
     * @dev This verifies the withdrawal checks recipient's balance correctly (bug fix from story 010)
     */
    function testAutoDolaWithdrawUsesCallerBalance() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // Setup: client1 deposits for themselves
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Verify client1 has the balance
        assertEq(vault.balanceOf(address(dolaToken), client1), depositAmount);

        // client1 withdraws their balance to their own address (recipient = client1)
        uint256 client1DolaBalanceBefore = dolaToken.balanceOf(client1);
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        // ASSERTION: client1's vault balance is reduced
        assertEq(vault.balanceOf(address(dolaToken), client1), depositAmount - withdrawAmount, "Caller's balance should be reduced");

        // ASSERTION: client1 (recipient) receives the DOLA
        assertEq(dolaToken.balanceOf(client1), client1DolaBalanceBefore + withdrawAmount, "Recipient should receive DOLA");
    }

    /**
     * @notice Test the critical cross-client scenario: client1 deposits for client2, then client2 withdraws
     * @dev This is the core test that addresses the MockVault vs AutoDolaYieldStrategy tracking discrepancy
     */
    function testCrossClientDepositWithdrawal() public {
        uint256 depositAmount = 2000e18;
        uint256 withdrawAmount = 1000e18;

        // SCENARIO: client1 deposits FOR client2 (cross-client deposit)
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client2);

        // VERIFICATION PHASE 1: Balance tracking
        // client2 (recipient) should have the balance
        assertEq(vault.balanceOf(address(dolaToken), client2), depositAmount, "Recipient should have vault balance");

        // client1 (caller/depositor) should NOT have any balance
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Depositor should NOT have vault balance");

        // VERIFICATION PHASE 2: Withdrawal authorization
        // client1 (who made the deposit) should NOT be able to withdraw because they have no balance
        vm.expectRevert("AutoDolaYieldStrategy: insufficient balance");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        // VERIFICATION PHASE 3: Only the recipient can withdraw
        // client2 (recipient) SHOULD be able to withdraw their balance to themselves
        uint256 client2DolaBalanceBefore = dolaToken.balanceOf(client2);
        vm.prank(client2);
        vault.withdraw(address(dolaToken), withdrawAmount, client2);

        // Verify the withdrawal succeeded
        assertEq(vault.balanceOf(address(dolaToken), client2), depositAmount - withdrawAmount, "Recipient balance reduced");
        assertEq(dolaToken.balanceOf(client2), client2DolaBalanceBefore + withdrawAmount, "Withdrawal recipient got DOLA");

        // VERIFICATION PHASE 4: Final state
        // client1 still has no balance
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Depositor still has no vault balance");

        // client2 has remaining balance
        assertEq(vault.balanceOf(address(dolaToken), client2), depositAmount - withdrawAmount, "Recipient has correct remaining balance");
    }

    /**
     * @notice Additional test: Multiple cross-client deposits accumulate correctly
     * @dev Verifies that multiple deposits for the same recipient accumulate properly
     */
    function testMultipleCrossClientDepositsAccumulate() public {
        uint256 deposit1 = 500e18;
        uint256 deposit2 = 700e18;

        // client1 deposits for bob
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, bob);

        // client2 deposits for bob
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit2, bob);

        // bob should have both deposits
        assertEq(vault.balanceOf(address(dolaToken), bob), deposit1 + deposit2, "Multiple deposits should accumulate");

        // Neither depositor should have balances
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "First depositor has no balance");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Second depositor has no balance");

        // Authorize bob to withdraw
        vm.prank(owner);
        vault.setClient(bob, true);

        // bob can withdraw the full amount to himself
        vm.prank(bob);
        vault.withdraw(address(dolaToken), deposit1 + deposit2, bob);

        assertEq(vault.balanceOf(address(dolaToken), bob), 0, "Bob's balance should be zero after full withdrawal");
    }

    /**
     * @notice Test that unauthorized recipient cannot withdraw after someone deposits for them
     * @dev Security test: if someone deposits for an unauthorized address, that address still can't withdraw
     */
    function testUnauthorizedRecipientCannotWithdraw() public {
        uint256 depositAmount = 1000e18;

        // alice is NOT an authorized client
        // client1 deposits for alice
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, alice);

        // alice should have the balance tracked
        assertEq(vault.balanceOf(address(dolaToken), alice), depositAmount);

        // alice attempts to withdraw but should fail (not an authorized client)
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(alice);
        vault.withdraw(address(dolaToken), depositAmount, alice);
    }

    /**
     * @notice Test recipient vs caller tracking with yield accumulation
     * @dev Verifies that yield is correctly attributed to the recipient, not the depositor
     */
    function testRecipientReceivesYieldNotCaller() public {
        uint256 depositAmount = 1000e18;
        uint256 yieldAmount = 100e18; // 10% yield

        // client1 deposits for bob
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, bob);

        // Simulate yield growth
        autoDolaVault.simulateYield(yieldAmount);

        // bob (recipient) should receive the yield
        uint256 bobBalance = vault.balanceOf(address(dolaToken), bob);
        assertTrue(bobBalance > depositAmount, "Recipient should receive yield");

        // client1 (depositor) should still have zero balance (no yield for them)
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Depositor should not receive any yield");
    }

    /**
     * @notice Test Story 008.10: Multiple deposits to same recipient accumulate correctly
     * @dev Verifies balance accumulation at line 199 (clientBalances[token][recipient] += amount)
     */
    function testMultipleDepositsToSameRecipient() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 500e18;

        // First deposit: client1 deposits for alice
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, alice);

        // Verify first deposit balance
        assertEq(vault.balanceOf(address(dolaToken), alice), deposit1, "First deposit should be tracked");

        // Second deposit: client1 deposits for alice again
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit2, alice);

        // Verify accumulated balance after second deposit
        assertEq(vault.balanceOf(address(dolaToken), alice), deposit1 + deposit2, "Second deposit should accumulate");

        // Third deposit: client2 deposits for alice (different client, same recipient)
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit3);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit3, alice);

        // CRITICAL: Verify line 199 accumulation logic works correctly
        // clientBalances[token][recipient] += amount should accumulate all three deposits
        uint256 expectedTotal = deposit1 + deposit2 + deposit3;
        assertEq(vault.balanceOf(address(dolaToken), alice), expectedTotal, "All deposits should accumulate to same recipient");

        // Verify total deposited tracking
        assertEq(vault.getTotalDeposited(address(dolaToken)), expectedTotal, "Total deposited should match sum of all deposits");

        // Verify depositors have no balance
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Depositor client1 should have no balance");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Depositor client2 should have no balance");
    }

    /**
     * @notice Test Story 008.10: Withdrawal after multiple deposits works correctly
     * @dev Verifies that withdrawals work properly after accumulated deposits
     */
    function testWithdrawAfterMultipleDeposits() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 1500e18;
        uint256 deposit3 = 500e18;
        uint256 totalDeposited = deposit1 + deposit2 + deposit3;
        uint256 withdrawAmount = 2000e18;

        // Multiple deposits for bob from different clients
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, bob);

        vm.prank(client1);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit2, bob);

        vm.prank(client2);
        dolaToken.approve(address(vault), deposit3);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit3, bob);

        // Verify accumulated balance
        assertEq(vault.balanceOf(address(dolaToken), bob), totalDeposited, "Bob should have accumulated balance");

        // Authorize bob to withdraw
        vm.prank(owner);
        vault.setClient(bob, true);

        // Bob withdraws part of the accumulated balance to himself
        uint256 bobDolaBalanceBefore = dolaToken.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(address(dolaToken), withdrawAmount, bob);

        // Verify withdrawal succeeded
        uint256 remainingBalance = totalDeposited - withdrawAmount;
        assertEq(vault.balanceOf(address(dolaToken), bob), remainingBalance, "Bob's balance should be reduced by withdrawal amount");
        assertEq(dolaToken.balanceOf(bob), bobDolaBalanceBefore + withdrawAmount, "Bob should receive withdrawn DOLA");

        // Bob withdraws remaining balance
        vm.prank(bob);
        vault.withdraw(address(dolaToken), remainingBalance, bob);

        // Verify complete withdrawal
        assertEq(vault.balanceOf(address(dolaToken), bob), 0, "Bob should have zero balance after full withdrawal");
    }

    /**
     * @notice Test Story 008.10: Verify totalDeposited accumulates correctly across multiple deposits
     * @dev Verifies that totalDeposited tracking is accurate for multiple recipients
     */
    function testTotalDepositedAccumulatesCorrectly() public {
        uint256 aliceDeposit1 = 1000e18;
        uint256 aliceDeposit2 = 500e18;
        uint256 bobDeposit1 = 2000e18;
        uint256 bobDeposit2 = 1500e18;

        // Initial state
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Initial total deposited should be zero");

        // First deposit for alice
        vm.prank(client1);
        dolaToken.approve(address(vault), aliceDeposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), aliceDeposit1, alice);

        assertEq(vault.getTotalDeposited(address(dolaToken)), aliceDeposit1, "Total deposited after first deposit");

        // Second deposit for alice (accumulation test)
        vm.prank(client1);
        dolaToken.approve(address(vault), aliceDeposit2);
        vm.prank(client1);
        vault.deposit(address(dolaToken), aliceDeposit2, alice);

        uint256 expectedAfterAlice = aliceDeposit1 + aliceDeposit2;
        assertEq(vault.getTotalDeposited(address(dolaToken)), expectedAfterAlice, "Total deposited after alice's second deposit");

        // First deposit for bob
        vm.prank(client2);
        dolaToken.approve(address(vault), bobDeposit1);
        vm.prank(client2);
        vault.deposit(address(dolaToken), bobDeposit1, bob);

        uint256 expectedAfterBob1 = expectedAfterAlice + bobDeposit1;
        assertEq(vault.getTotalDeposited(address(dolaToken)), expectedAfterBob1, "Total deposited after bob's first deposit");

        // Second deposit for bob
        vm.prank(client2);
        dolaToken.approve(address(vault), bobDeposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), bobDeposit2, bob);

        uint256 expectedTotal = aliceDeposit1 + aliceDeposit2 + bobDeposit1 + bobDeposit2;
        assertEq(vault.getTotalDeposited(address(dolaToken)), expectedTotal, "Total deposited should accumulate all deposits");

        // Verify individual balances
        assertEq(vault.balanceOf(address(dolaToken), alice), aliceDeposit1 + aliceDeposit2, "Alice's balance should be correct");
        assertEq(vault.balanceOf(address(dolaToken), bob), bobDeposit1 + bobDeposit2, "Bob's balance should be correct");

        // Verify totalDeposited matches sum of individual balances
        uint256 sumOfBalances = (aliceDeposit1 + aliceDeposit2) + (bobDeposit1 + bobDeposit2);
        assertEq(vault.getTotalDeposited(address(dolaToken)), sumOfBalances, "Total deposited should equal sum of balances");
    }
}
