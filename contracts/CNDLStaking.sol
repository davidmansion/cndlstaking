// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract CNDLStaking is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 initialTier;
        uint256 lastUpdateTime;
    }

    IERC20 public cndlToken;
    address public constant CNDL_TOKEN_ADDRESS = 0x6EFb32bc7893b793603E39643D86594CE3638157;
    address public constant FEE_ADDRESS = 0x83576669A353BC57aF70989746722315e48747a2;

    mapping(address => Stake) public stakes;
    mapping(address => uint256) public receiptScores;

    uint256 public constant DURATION = 9 days;
    uint256 public constant EARLY_UNSTAKE_FEE_PERCENT = 5;
    uint256[] public thresholds = [25000 * 10**18, 50000 * 10**18, 100000 * 10**18, 150000 * 10**18, 300000 * 10**18, 600000 * 10**18];
    uint256[] public tierScores = [1, 2, 3, 4, 5, 6]; // corresponding scores for each tier to increment receipt score per duration
    string[] public categoryNames = ["TierOne", "TierTwo", "TierThree", "TierFour", "TierFive", "TierSix"];

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 receiptScore);
    event ReceiptScoreReset(address indexed user);
    event ForciblyUnstaked(address indexed user, uint256 amount, uint256 receiptScore);

    constructor(address _cndlToken) {
        require(_cndlToken == CNDL_TOKEN_ADDRESS, "Invalid CNDL token address");
        cndlToken = IERC20(_cndlToken);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount >= thresholds[0], "Cannot stake below the minimum threshold");
        require(cndlToken.balanceOf(msg.sender) >= amount, "Insufficient balance to stake");
        require(cndlToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        uint256 initialTier = getTier(amount);

        if (stakes[msg.sender].amount > 0) {
            stakes[msg.sender].amount = stakes[msg.sender].amount.add(amount);
        } else {
            stakes[msg.sender] = Stake(amount, block.timestamp, initialTier, block.timestamp);
        }

        emit Staked(msg.sender, amount);
    }

    function unstake() external nonReentrant {
        updateReceiptScore(msg.sender);
        _unstake(msg.sender);
    }

    function forciblyUnstake(address account) external onlyOwner nonReentrant {
        updateReceiptScore(account);
        _unstake(account);
        emit ForciblyUnstaked(account, stakes[account].amount, receiptScores[account]);
    }

    function _unstake(address account) internal {
        Stake storage userStake = stakes[account];
        require(userStake.amount > 0, "No tokens staked");

        uint256 stakedAmount = userStake.amount;
        uint256 feeAmount = 0;

        if (block.timestamp < userStake.startTime + DURATION) {
            feeAmount = stakedAmount.mul(EARLY_UNSTAKE_FEE_PERCENT).div(100);
            require(cndlToken.transfer(FEE_ADDRESS, feeAmount), "Fee transfer failed");
            stakedAmount = stakedAmount.sub(feeAmount);
        }

        // Reset stake
        userStake.amount = 0;
        userStake.startTime = 0;

        require(cndlToken.transfer(account, stakedAmount), "Token transfer failed");

        emit Unstaked(account, stakedAmount, receiptScores[account]);
    }

    function updateReceiptScore(address account) internal {
        Stake storage userStake = stakes[account];
        if (userStake.amount == 0) {
            return;
        }

        uint256 periods = (block.timestamp - userStake.lastUpdateTime) / DURATION;
        if (periods > 0) {
            receiptScores[account] = receiptScores[account].add(tierScores[userStake.initialTier].mul(periods));
            userStake.lastUpdateTime = userStake.lastUpdateTime.add(periods * DURATION);
        }
    }

    function getUpdatedReceiptScore(address account) public view returns (uint256) {
        Stake storage userStake = stakes[account];
        if (userStake.amount == 0) {
            return receiptScores[account];
        }

        uint256 periods = (block.timestamp - userStake.lastUpdateTime) / DURATION;
        uint256 newScores = tierScores[userStake.initialTier].mul(periods);

        return receiptScores[account].add(newScores);
    }

    function receiptScore(address account) external view returns (uint256) {
        return getUpdatedReceiptScore(account);
    }

    function currentCategory(address account) external view returns (string memory) {
        uint256 stakedAmount = stakes[account].amount;
        require(stakedAmount >= thresholds[0], "No staked amount");

        for (uint256 i = thresholds.length; i > 0; i--) {
            if (stakedAmount >= thresholds[i - 1]) {
                return categoryNames[i - 1];
            }
        }

        revert("No valid threshold category found");
    }

    function isValidThreshold(uint256 amount) internal view returns (bool) {
        return amount >= thresholds[0];
    }

    function getTier(uint256 amount) internal view returns (uint256) {
        for (uint256 i = thresholds.length; i > 0; i--) {
            if (amount >= thresholds[i - 1]) {
                return i - 1;
            }
        }
        revert("Amount does not match any tier");
    }

    function resetReceiptScore(address account) external onlyOwner {
        receiptScores[account] = 0;
        emit ReceiptScoreReset(account);
    }
}
