// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interfaces
interface ILucidMathV3 {
    struct Distribution { uint256 netPayout; uint256 totalFee; uint256 adminShare; uint256 refShare; }
    function calculate(uint256 u, uint256 t, uint256 w, uint256 f, uint256 r, bool h) external pure returns (Distribution memory);
}
interface ILucidResolverV3 {
    function checkOutcome(address o, uint80 r, uint256 e, int256 t, bool l) external view returns (uint8, int256, bool);
}

contract LucidMarketsV4 is Ownable {
    using SafeERC20 for IERC20;

    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "Reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    ILucidMathV3 public math;
    ILucidResolverV3 public resolver;

    enum MarketOutcome { PENDING, NO, YES, VOID }

    // 📦 CONFIG
    struct MarketConfig {
        string question;
        string metadataURI;
        uint256 endTime;        // 🛑 Betting Closes Here
        uint256 resolutionTime; // 🔮 Admin/Oracle Resolves Here
        int256 targetPrice;
        address oracleFeed;
        address bettingToken;
        bool isLessThan;
        uint256 minBet;
    }

    struct MarketStatus {
        bool resolved;
        bool cancelled;
        MarketOutcome outcome;
        uint256 totalPool;
        uint256 totalYes;
        uint256 totalNo;
        uint256 winningPool;
    }

    struct BetInfo {
        uint256 yesAmount;
        uint256 noAmount;
        address referrer;
        bool claimed;
    }

    uint256 public marketCount;
    
    // 💸 FEES
    uint256 public feeBasis = 500;       
    uint256 public referralSplit = 2000; 

    address public treasury; 
    bool public isPaused; 

    mapping(uint256 => MarketConfig) public marketConfigs;
    mapping(uint256 => MarketStatus) public marketStatuses;
    mapping(uint256 => mapping(address => BetInfo)) public userBets;

    // Events
    event MarketCreated(uint256 indexed marketId, string question, address indexed token, uint256 minBet, uint256 resolutionTime);
    event BetPlaced(uint256 indexed marketId, address indexed user, uint256 amount, bool isYes, address referrer);
    event MarketResolved(uint256 indexed marketId, MarketOutcome outcome, bool isManual);
    event WinningsClaimed(uint256 indexed marketId, address indexed user, uint256 amount, uint256 feePaid);
    event FeesDistributed(uint256 indexed marketId, uint256 adminAmount, uint256 referrerAmount);
    event MarketCancelled(uint256 indexed marketId);

    constructor(address _math, address _resolver) Ownable(msg.sender) {
        math = ILucidMathV3(_math);
        resolver = ILucidResolverV3(_resolver);
        treasury = msg.sender;
    }

    // --- 1. CREATE MARKET ---
    function createMarket(MarketConfig calldata params) external onlyOwner {
        require(params.endTime > block.timestamp, "End time past");
        require(params.resolutionTime >= params.endTime, "Res time < End time");
        
        marketCount++;
        marketConfigs[marketCount] = params;
        emit MarketCreated(marketCount, params.question, params.bettingToken, params.minBet, params.resolutionTime);
    }

    // --- 2. PLACE BET ---
    function placeBet(uint256 _id, bool _isYes, uint256 _amt, address _ref) external payable nonReentrant {
        require(!isPaused, "Paused");
        
        MarketStatus storage s = marketStatuses[_id];
        MarketConfig storage c = marketConfigs[_id];

        // 🛑 Betting Deadline Check
        require(!s.resolved && !s.cancelled && block.timestamp < c.endTime, "Betting closed");
        require(_amt >= c.minBet, "Below min bet");

        if (c.bettingToken == address(0)) {
            require(msg.value == _amt, "ETH mismatch");
        } else {
            require(msg.value == 0, "Don't send ETH");
            IERC20(c.bettingToken).safeTransferFrom(msg.sender, address(this), _amt);
        }

        BetInfo storage bet = userBets[_id][msg.sender];
        if(bet.referrer == address(0) && _ref != address(0) && _ref != msg.sender) bet.referrer = _ref;

        if (_isYes) { bet.yesAmount += _amt; s.totalYes += _amt; }
        else { bet.noAmount += _amt; s.totalNo += _amt; }
        s.totalPool += _amt;

        emit BetPlaced(_id, msg.sender, _amt, _isYes, bet.referrer);
    }

    // --- 3A. AUTO RESOLVE (Chainlink) ---
    function resolveMarket(uint256 _id, uint80 _roundId) external onlyOwner {
        MarketStatus storage s = marketStatuses[_id];
        MarketConfig storage c = marketConfigs[_id];
        
        require(!s.resolved, "Resolved");
        require(c.oracleFeed != address(0), "Use Manual");

        (uint8 winCode, , bool valid) = resolver.checkOutcome(
            c.oracleFeed, _roundId, c.resolutionTime, c.targetPrice, c.isLessThan
        );
        require(valid, "Invalid Round");

        _finalizeMarket(_id, winCode);
        emit MarketResolved(_id, s.outcome, false);
    }

    // --- 3B. MANUAL RESOLVE ---
    function resolveManual(uint256 _id, uint8 _outcomeCode) external onlyOwner {
        MarketStatus storage s = marketStatuses[_id];
        MarketConfig storage c = marketConfigs[_id];
        
        require(!s.resolved, "Resolved");
        require(!s.cancelled, "Cancelled");
        require(c.oracleFeed == address(0), "Use Auto");

        // 🔒 SECURITY CHECK: Wait for Resolution Time
        require(block.timestamp >= c.resolutionTime, "Not yet resolution time");

        _finalizeMarket(_id, _outcomeCode);
        emit MarketResolved(_id, s.outcome, true);
    }

    // --- HELPER ---
    function _finalizeMarket(uint256 _id, uint8 _code) internal {
        MarketStatus storage s = marketStatuses[_id];
        MarketConfig storage c = marketConfigs[_id];

        if (_code == 2) s.outcome = MarketOutcome.YES;
        else if (_code == 1) s.outcome = MarketOutcome.NO;
        else s.outcome = MarketOutcome.VOID;

        s.resolved = true;
        s.winningPool = (s.outcome == MarketOutcome.YES) ? s.totalYes : s.totalNo;

        // 🎰 HOUSE TAKES ALL if nobody won
        if (s.outcome != MarketOutcome.VOID && s.winningPool == 0 && s.totalPool > 0) {
            _safeTransfer(c.bettingToken, treasury, s.totalPool);
            emit FeesDistributed(_id, s.totalPool, 0); 
        }
    }

    // --- 4. CLAIM WINNINGS (FIXED) ---
    function claimWinnings(uint256 _id) external nonReentrant {
        MarketStatus storage s = marketStatuses[_id];
        BetInfo storage bet = userBets[_id][msg.sender];

        // 🛠️ FIX: Removed "!s.cancelled" so you CAN claim refunds on cancelled markets
        require(s.resolved && !bet.claimed, "Invalid claim");

        uint256 stake;
        if (s.outcome == MarketOutcome.YES) stake = bet.yesAmount;
        else if (s.outcome == MarketOutcome.NO) stake = bet.noAmount;
        else if (s.outcome == MarketOutcome.VOID) stake = bet.yesAmount + bet.noAmount;

        require(stake > 0, "Nothing to claim");
        bet.claimed = true;

        // If VOID (or Cancelled), refund fully
        if (s.outcome == MarketOutcome.VOID) {
             _safeTransfer(marketConfigs[_id].bettingToken, msg.sender, stake);
             emit WinningsClaimed(_id, msg.sender, stake, 0);
             return;
        }

        ILucidMathV3.Distribution memory d = math.calculate(
            stake, s.totalPool, s.winningPool, feeBasis, referralSplit, (bet.referrer != address(0))
        );

        address token = marketConfigs[_id].bettingToken;
        _safeTransfer(token, msg.sender, d.netPayout);

        if(d.totalFee > 0) {
            _safeTransfer(token, treasury, d.adminShare);
            if(d.refShare > 0) _safeTransfer(token, bet.referrer, d.refShare);
            emit FeesDistributed(_id, d.adminShare, d.refShare);
        }

        emit WinningsClaimed(_id, msg.sender, d.netPayout, d.totalFee);
    }

    // --- ADMIN ---
    function cancelMarket(uint256 _id) external onlyOwner {
        MarketStatus storage s = marketStatuses[_id];
        require(!s.resolved, "Already resolved");
        s.cancelled = true;
        s.resolved = true;
        s.outcome = MarketOutcome.VOID; // Sets outcome to VOID for refunds
        emit MarketCancelled(_id);
    }

    // 💸 FEES
    function setFeeRates(uint256 _totalBasis, uint256 _refSplit) external onlyOwner {
        require(_totalBasis <= 500, "Max fee 5%"); 
        feeBasis = _totalBasis;
        referralSplit = _refSplit;
    }

    function setPaused(bool _s) external onlyOwner { isPaused = _s; }
    function setTreasury(address _t) external onlyOwner { treasury = _t; }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        if (_token == address(0)) {
            (bool success, ) = _to.call{value: _amount}("");
            require(success, "ETH Transfer failed");
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function sweepUnclaimed(uint256 _id) external onlyOwner {
        require(marketStatuses[_id].resolved && block.timestamp > marketConfigs[_id].resolutionTime + 365 days);
        address token = marketConfigs[_id].bettingToken;
        if(token == address(0)) _safeTransfer(address(0), treasury, address(this).balance);
        else _safeTransfer(token, treasury, IERC20(token).balanceOf(address(this)));
    }

    function emergencyRefund(uint256 _id) external nonReentrant {
        MarketStatus storage s = marketStatuses[_id];
        MarketConfig storage c = marketConfigs[_id];
        require(!s.resolved && block.timestamp > c.resolutionTime + 3 days);
        
        BetInfo storage bet = userBets[_id][msg.sender];
        uint256 total = bet.yesAmount + bet.noAmount;
        require(total > 0 && !bet.claimed);
        bet.claimed = true;
        _safeTransfer(c.bettingToken, msg.sender, total);
    }

    receive() external payable {}
}