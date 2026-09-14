// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MEMEFactory} from "./MEMEFactory.sol";
import {MEMEToken} from "./MEMEToken.sol";
import {DEXRouter} from "./DEXRouter.sol";
import {IMEMEHelper} from "./interfaces/IMEMEHelper.sol";
import {IMEMEVesting} from "./interfaces/IMEMEVesting.sol";

contract MEMECore is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using SafeERC20 for MEMEToken;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant REQUEST_EXPIRY = 1 hours;
    uint256 public constant MAX_INITIAL_BUY_PERCENTAGE = 9_990;
    uint256 public constant MIN_LIQUIDITY = 10 ether;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct VestingAllocation {
        uint256 percentageBP;
        uint256 duration;
        IMEMEVesting.VestingMode mode;
    }

    enum TokenStatus {
        NOT_CREATED, // The default value for an unknown token.
        TRADING, // Assigned by createToken(), users can buy and sell through the bonding curve. The token uses CONTROLLED transfer mode.
        PENDING_GRADUATION, // Enter after a buy leaves fewer than MIN_LIQUIDITY, bonding curve trading stops. Token transfers become RESTRICTED.
        GRADUATED, // Enter when graduateToken() is called, the collected BNB and remaining tokens are added to the DEX pool. Transfer mode becomes NORMAL, allowing regular ERC-20 trading.
        PAUSED, // Temporarily stop one token. Transfers become RESTRICTED.
        BLACKLISTED // An admin can freeze any existing token
    }

    struct CreateTokenParams {
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 saleAmount;
        uint256 virtualBNBReserve;
        uint256 virtualTokenReserve;
        uint256 launchTime;
        address creator;
        uint256 timestamp;
        bytes32 requestId;
        uint256 nonce;
        uint256 initialBuyPercentage;
        VestingAllocation[] vestingAllocations;
    }

    struct TokenInfo {
        address creator;
        uint256 createdAt;
        uint256 launchTime;
        TokenStatus status;
        address liquidityPool;
    }

    struct GraduationAmounts {
        uint256 nativePlatformFee;
        uint256 nativeCreatorFee;
        uint256 nativeLiquidity;
        uint256 tokenPlatformFee;
        uint256 tokenCreatorFee;
        uint256 tokenLiquidity;
    }

    bool public initialized;

    MEMEFactory public factory;
    address public helper;
    address public vesting;
    address public platformFeeReceiver;
    address public marginReceiver;
    address public graduateFeeReceiver;
    address public dexRouter;
    uint256 public chainId;

    uint256 public creationFee;
    uint256 public preBuyFeeRate;
    uint256 public tradingFeeRate;
    uint256 public graduationPlatformFeeRate;
    uint256 public graduationCreatorFeeRate;
    uint256 public minLockTime;

    mapping(bytes32 => bool) public usedRequestIds;
    mapping(address => TokenInfo) public tokenInfo;
    mapping(address => IMEMEHelper.BondingCurveParams) public bondingCurve;
    mapping(address => TokenStatus) private statusBeforeBlacklist;

    error AlreadyInitialized();
    error ZeroAddress();
    error InvalidSigner();
    error RequestExpired();
    error RequestAlreadyProcessed();
    error InsufficientFee();
    error InvalidTokenParameters();
    error NativeTransferFailed();
    error TokenNotTrading();
    error TokenNotLaunchedYet();
    error TransactionExpired();
    error DeadlineTooFar();
    error InvalidNativeAmount();
    error InvalidTokenAmount();
    error SlippageExceeded();
    error InsufficientLiquidity();
    error InvalidInitialBuy();
    error InvalidVestingAllocation();
    error InvalidGraduationStatus();
    error GraduationLiquidityUnavailable();
    error InvalidTokenStatus();
    error InvalidAdminValue();

    event Initialized(address indexed admin, address indexed signer, address indexed factory);
    event HelperChanged(address indexed oldHelper, address indexed newHelper);
    event VestingChanged(address indexed oldVesting, address indexed newVesting);
    event DexRouterChanged(address indexed oldRouter, address indexed newRouter);
    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint256 totalSupply,
        bytes32 requestId
    );
    event TokenBought(
        address indexed token,
        address indexed buyer,
        uint256 bnbAmount,
        uint256 tokenAmount,
        uint256 tradingFee,
        uint256 virtualBNBReserve,
        uint256 virtualTokenReserve,
        uint256 availableTokens,
        uint256 collectedBNB
    );
    event TokenSold(
        address indexed token,
        address indexed seller,
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 tradingFee,
        uint256 virtualBNBReserve,
        uint256 virtualTokenReserve,
        uint256 availableTokens,
        uint256 collectedBNB
    );
    event InitialBuyExecuted(
        address indexed token, address indexed creator, uint256 tokenAmount, uint256 bnbAmount, uint256 tradingFee
    );
    event VestingCreated(address indexed token, address indexed beneficiary, uint256 amount, uint256 scheduleCount);
    event TokenStatusChanged(address indexed token, TokenStatus oldStatus, TokenStatus newStatus);
    event TokenGraduated(
        address indexed token, address indexed pair, uint256 nativeLiquidity, uint256 tokenLiquidity, uint256 lpTokens
    );
    event TokenPaused(address indexed token);
    event TokenUnpaused(address indexed token);
    event TokenBlacklisted(address indexed token);
    event TokenRemovedFromBlacklist(address indexed token);
    event PlatformFeeReceiverChanged(address indexed oldReceiver, address indexed newReceiver);
    event GraduateFeeReceiverChanged(address indexed oldReceiver, address indexed newReceiver);
    event MarginReceiverChanged(address indexed oldReceiver, address indexed newReceiver);
    event CreationFeeChanged(uint256 fee);
    event PreBuyFeeRateChanged(uint256 rate);
    event TradingFeeRateChanged(uint256 rate);
    event GraduationFeeRatesChanged(uint256 platformRate, uint256 creatorRate);
    event MinLockTimeChanged(uint256 minLockTime);

    function initialize(
        address factory_,
        address helper_,
        address signer_,
        address platformFeeReceiver_,
        address marginReceiver_,
        address graduateFeeReceiver_,
        address admin_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            factory_ == address(0) || helper_ == address(0) || signer_ == address(0)
                || platformFeeReceiver_ == address(0) || marginReceiver_ == address(0)
                || graduateFeeReceiver_ == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }

        initialized = true;
        factory = MEMEFactory(factory_);
        helper = helper_;
        platformFeeReceiver = platformFeeReceiver_;
        marginReceiver = marginReceiver_;
        graduateFeeReceiver = graduateFeeReceiver_;
        chainId = block.chainid;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(SIGNER_ROLE, signer_);
        _grantRole(DEPLOYER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);

        creationFee = 0.05 ether;
        preBuyFeeRate = 300;
        tradingFeeRate = 100;
        graduationPlatformFeeRate = 550;
        graduationCreatorFeeRate = 250;
        minLockTime = 1 days;

        emit Initialized(admin_, signer_, factory_);
    }

    function deployTokenFor(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 timestamp,
        uint256 nonce
    ) external onlyRole(ADMIN_ROLE) returns (address) {
        return factory.deployToken(name, symbol, totalSupply, timestamp, nonce);
    }

    function createToken(bytes calldata data, bytes calldata signature)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address tokenAddress)
    {
        if (msg.value < creationFee) revert InsufficientFee();

        CreateTokenParams memory params = abi.decode(data, (CreateTokenParams));
        bytes32 messageHash = keccak256(abi.encodePacked(data, chainId, address(this)));
        address recoveredSigner = messageHash.recover(signature);

        if (!hasRole(SIGNER_ROLE, recoveredSigner)) revert InvalidSigner();
        if (block.timestamp > params.timestamp + REQUEST_EXPIRY) revert RequestExpired();
        if (usedRequestIds[params.requestId]) revert RequestAlreadyProcessed();
        if (
            bytes(params.name).length == 0 || bytes(params.symbol).length == 0 || params.totalSupply == 0
                || params.saleAmount == 0 || params.saleAmount > params.totalSupply || params.virtualBNBReserve == 0
                || params.virtualTokenReserve <= params.saleAmount || params.creator == address(0)
                || params.requestId == bytes32(0)
        ) {
            revert InvalidTokenParameters();
        }

        (uint256 initialTokens, uint256 initialBNB, uint256 adjustedBNBReserve, uint256 adjustedTokenReserve) =
            _calculateInitialBuy(params);
        uint256 initialBuyFee = initialBNB * preBuyFeeRate / 10_000;
        uint256 totalPaymentRequired = creationFee + initialBNB + initialBuyFee;
        if (msg.value < totalPaymentRequired) revert InsufficientFee();

        // Consume the signed request before making external calls.
        usedRequestIds[params.requestId] = true;

        tokenAddress =
            factory.deployToken(params.name, params.symbol, params.totalSupply, params.timestamp, params.nonce);

        MEMEToken(tokenAddress).setTransferMode(MEMEToken.TransferMode.CONTROLLED);
        bondingCurve[tokenAddress] = IMEMEHelper.BondingCurveParams({
            virtualBNBReserve: adjustedBNBReserve,
            virtualTokenReserve: adjustedTokenReserve,
            k: params.virtualBNBReserve * params.virtualTokenReserve,
            availableTokens: params.saleAmount - initialTokens,
            collectedBNB: initialBNB
        });
        tokenInfo[tokenAddress] = TokenInfo({
            creator: params.creator,
            createdAt: block.timestamp,
            launchTime: params.launchTime,
            status: TokenStatus.TRADING,
            liquidityPool: address(0)
        });

        if (initialTokens > 0) {
            uint256 directTokens = _distributeInitialTokens(tokenAddress, params, initialTokens);
            if (directTokens > 0) MEMEToken(tokenAddress).safeTransfer(params.creator, directTokens);

            emit InitialBuyExecuted(tokenAddress, params.creator, initialTokens, initialBNB, initialBuyFee);
        }

        _sendNative(platformFeeReceiver, creationFee + initialBuyFee);

        uint256 refund = msg.value - totalPaymentRequired;
        if (refund > 0) _sendNative(msg.sender, refund);

        emit TokenCreated(
            tokenAddress, params.creator, params.name, params.symbol, params.totalSupply, params.requestId
        );
    }

    function buy(address token, uint256 minTokenAmount, uint256 deadline) external payable nonReentrant whenNotPaused {
        _validateTrade(token);
        // It limits a buy tx's deadline to less than 24 hours in the future: block.timestamp <= deadline < block.timestamp + 1 day
        if (deadline < block.timestamp) revert TransactionExpired();
        if (deadline >= block.timestamp + 1 days) revert DeadlineTooFar();
        if (msg.value == 0) revert InvalidNativeAmount();

        IMEMEHelper.BondingCurveParams storage curve = bondingCurve[token];
        IMEMEHelper helperContract = IMEMEHelper(helper);

        uint256 tradingFee = msg.value * tradingFeeRate / 10_000;
        uint256 netBNBAmount = msg.value - tradingFee;
        uint256 tokenAmount = helperContract.calculateTokenAmountOut(netBNBAmount, curve);

        if (tokenAmount > curve.availableTokens) {
            tokenAmount = curve.availableTokens;
            // when buying the final available tokens, the bonding curve calculates the exact net BNB required.
            netBNBAmount = helperContract.calculateRequiredBNB(tokenAmount, curve);
            // We must work backward to find the fee.
            // fee = gross * rate / 10_000 and net = gross - fee
            // given net, fee = net * rate / (10_000 - rate)
            tradingFee = netBNBAmount * tradingFeeRate / (10_000 - tradingFeeRate);
            uint256 refund = msg.value - netBNBAmount - tradingFee;
            if (refund > 0) _sendNative(msg.sender, refund);
        }

        if (tokenAmount == 0 || tokenAmount < minTokenAmount) revert SlippageExceeded();

        curve.virtualBNBReserve += netBNBAmount;
        curve.virtualTokenReserve -= tokenAmount;
        curve.availableTokens -= tokenAmount;
        curve.collectedBNB += netBNBAmount;

        _sendNative(platformFeeReceiver, tradingFee);
        MEMEToken(token).safeTransfer(msg.sender, tokenAmount);

        if (curve.availableTokens < MIN_LIQUIDITY) {
            _changeTokenStatus(token, TokenStatus.PENDING_GRADUATION);
            MEMEToken(token).setTransferMode(MEMEToken.TransferMode.RESTRICTED);
        }

        emit TokenBought(
            token,
            msg.sender,
            netBNBAmount,
            tokenAmount,
            tradingFee,
            curve.virtualBNBReserve,
            curve.virtualTokenReserve,
            curve.availableTokens,
            curve.collectedBNB
        );
    }

    function sell(address token, uint256 tokenAmount, uint256 minBNBAmount, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        _validateTrade(token);
        if (block.timestamp > deadline) revert TransactionExpired();
        if (tokenAmount == 0) revert InvalidTokenAmount();

        IMEMEHelper.BondingCurveParams storage curve = bondingCurve[token];
        uint256 grossBNBAmount = IMEMEHelper(helper).calculateBNBAmountOut(tokenAmount, curve);
        if (grossBNBAmount > curve.collectedBNB) revert InsufficientLiquidity();

        uint256 tradingFee = grossBNBAmount * tradingFeeRate / 10_000;
        uint256 netBNBAmount = grossBNBAmount - tradingFee;
        if (netBNBAmount < minBNBAmount) revert SlippageExceeded();

        MEMEToken(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        curve.virtualBNBReserve -= grossBNBAmount;
        curve.virtualTokenReserve += tokenAmount;
        curve.availableTokens += tokenAmount;
        curve.collectedBNB -= grossBNBAmount;

        _sendNative(platformFeeReceiver, tradingFee);
        _sendNative(msg.sender, netBNBAmount);

        emit TokenSold(
            token,
            msg.sender,
            tokenAmount,
            netBNBAmount,
            tradingFee,
            curve.virtualBNBReserve,
            curve.virtualTokenReserve,
            curve.availableTokens,
            curve.collectedBNB
        );
    }

    function calculateBuyAmountWithFee(address token, uint256 bnbAmount)
        external
        view
        returns (uint256 tokenAmount, uint256 netBNBAmount, uint256 tradingFee)
    {
        IMEMEHelper.BondingCurveParams memory curve = bondingCurve[token];
        tradingFee = bnbAmount * tradingFeeRate / 10_000;
        netBNBAmount = bnbAmount - tradingFee;
        tokenAmount = IMEMEHelper(helper).calculateTokenAmountOut(netBNBAmount, curve);

        if (tokenAmount > curve.availableTokens) {
            tokenAmount = curve.availableTokens;
            netBNBAmount = IMEMEHelper(helper).calculateRequiredBNB(tokenAmount, curve);
            tradingFee = netBNBAmount * tradingFeeRate / (10_000 - tradingFeeRate);
        }
    }

    function calculateSellReturnWithFee(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 netBNBAmount, uint256 tradingFee)
    {
        uint256 grossBNBAmount = IMEMEHelper(helper).calculateBNBAmountOut(tokenAmount, bondingCurve[token]);
        tradingFee = grossBNBAmount * tradingFeeRate / 10_000;
        netBNBAmount = grossBNBAmount - tradingFee;
    }

    function calculateInitialBuyCost(
        uint256 totalSupply,
        uint256 virtualBNBReserve,
        uint256 virtualTokenReserve,
        uint256 percentageBP
    ) external view returns (uint256 tokenAmount, uint256 bnbAmount, uint256 feeAmount) {
        if (percentageBP > MAX_INITIAL_BUY_PERCENTAGE) revert InvalidInitialBuy();
        tokenAmount = totalSupply * percentageBP / 10_000;
        if (tokenAmount == 0) return (0, 0, 0);
        if (tokenAmount >= virtualTokenReserve) revert InvalidInitialBuy();

        uint256 newBNBReserve = virtualBNBReserve * virtualTokenReserve / (virtualTokenReserve - tokenAmount);
        bnbAmount = newBNBReserve - virtualBNBReserve;
        feeAmount = bnbAmount * preBuyFeeRate / 10_000;
    }

    function graduateToken(address token) external onlyRole(DEPLOYER_ROLE) nonReentrant {
        TokenInfo storage info = tokenInfo[token];
        if (info.status != TokenStatus.PENDING_GRADUATION) revert InvalidGraduationStatus();
        if (dexRouter == address(0)) revert ZeroAddress();

        IMEMEHelper.BondingCurveParams storage curve = bondingCurve[token];
        uint256 collectedBNB = curve.collectedBNB;
        uint256 remainingTokens = curve.availableTokens;
        if (collectedBNB == 0 || remainingTokens == 0) revert GraduationLiquidityUnavailable();

        GraduationAmounts memory amounts = _graduationAmounts(collectedBNB, remainingTokens);

        DEXRouter router = DEXRouter(dexRouter);
        address pair = router.createPair(token);
        MEMEToken memeToken = MEMEToken(token);
        memeToken.setPair(pair);
        memeToken.setTransferMode(MEMEToken.TransferMode.NORMAL);

        curve.availableTokens = 0;
        curve.collectedBNB = 0;
        _changeTokenStatus(token, TokenStatus.GRADUATED);
        info.liquidityPool = pair;

        memeToken.safeIncreaseAllowance(dexRouter, amounts.tokenLiquidity);
        (, uint256 lpTokens) =
            router.addLiquidity{value: amounts.nativeLiquidity}(token, amounts.tokenLiquidity, DEAD_ADDRESS);

        _sendNative(graduateFeeReceiver, amounts.nativePlatformFee);
        if (amounts.tokenPlatformFee > 0) memeToken.safeTransfer(graduateFeeReceiver, amounts.tokenPlatformFee);
        _sendNative(info.creator, amounts.nativeCreatorFee);
        if (amounts.tokenCreatorFee > 0) memeToken.safeTransfer(info.creator, amounts.tokenCreatorFee);

        emit TokenGraduated(token, pair, amounts.nativeLiquidity, amounts.tokenLiquidity, lpTokens);
    }

    function pauseToken(address token) external onlyRole(PAUSER_ROLE) {
        if (tokenInfo[token].status != TokenStatus.TRADING) revert InvalidTokenStatus();
        _changeTokenStatus(token, TokenStatus.PAUSED);
        MEMEToken(token).setTransferMode(MEMEToken.TransferMode.RESTRICTED);
        emit TokenPaused(token);
    }

    function unpauseToken(address token) external onlyRole(PAUSER_ROLE) {
        if (tokenInfo[token].status != TokenStatus.PAUSED) revert InvalidTokenStatus();
        _changeTokenStatus(token, TokenStatus.TRADING);
        MEMEToken(token).setTransferMode(MEMEToken.TransferMode.CONTROLLED);
        emit TokenUnpaused(token);
    }

    function blacklistToken(address token) external onlyRole(ADMIN_ROLE) {
        TokenStatus currentStatus = tokenInfo[token].status;
        if (currentStatus == TokenStatus.NOT_CREATED || currentStatus == TokenStatus.BLACKLISTED) {
            revert InvalidTokenStatus();
        }

        statusBeforeBlacklist[token] = currentStatus;
        _changeTokenStatus(token, TokenStatus.BLACKLISTED);
        MEMEToken(token).setTransferMode(MEMEToken.TransferMode.RESTRICTED);
        emit TokenBlacklisted(token);
    }

    function removeFromBlacklist(address token) external onlyRole(ADMIN_ROLE) {
        if (tokenInfo[token].status != TokenStatus.BLACKLISTED) revert InvalidTokenStatus();

        TokenStatus restoredStatus = statusBeforeBlacklist[token];
        delete statusBeforeBlacklist[token];
        _changeTokenStatus(token, restoredStatus);

        MEMEToken.TransferMode mode = restoredStatus == TokenStatus.GRADUATED
            ? MEMEToken.TransferMode.NORMAL
            : restoredStatus == TokenStatus.TRADING
                ? MEMEToken.TransferMode.CONTROLLED
                : MEMEToken.TransferMode.RESTRICTED;
        MEMEToken(token).setTransferMode(mode);
        emit TokenRemovedFromBlacklist(token);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setHelper(address helper_) external onlyRole(ADMIN_ROLE) {
        if (helper_ == address(0)) revert ZeroAddress();
        address oldHelper = helper;
        helper = helper_;
        emit HelperChanged(oldHelper, helper_);
    }

    function setVesting(address vesting_) external onlyRole(ADMIN_ROLE) {
        if (vesting_ == address(0)) revert ZeroAddress();
        address oldVesting = vesting;
        vesting = vesting_;
        emit VestingChanged(oldVesting, vesting_);
    }

    function setDexRouter(address dexRouter_) external onlyRole(ADMIN_ROLE) {
        if (dexRouter_ == address(0)) revert ZeroAddress();
        address oldRouter = dexRouter;
        dexRouter = dexRouter_;
        emit DexRouterChanged(oldRouter, dexRouter_);
    }

    function setPlatformFeeReceiver(address receiver) external onlyRole(ADMIN_ROLE) {
        if (receiver == address(0)) revert ZeroAddress();
        address oldReceiver = platformFeeReceiver;
        platformFeeReceiver = receiver;
        emit PlatformFeeReceiverChanged(oldReceiver, receiver);
    }

    function setGraduateFeeReceiver(address receiver) external onlyRole(ADMIN_ROLE) {
        if (receiver == address(0)) revert ZeroAddress();
        address oldReceiver = graduateFeeReceiver;
        graduateFeeReceiver = receiver;
        emit GraduateFeeReceiverChanged(oldReceiver, receiver);
    }

    function setMarginReceiver(address receiver) external onlyRole(ADMIN_ROLE) {
        if (receiver == address(0)) revert ZeroAddress();
        address oldReceiver = marginReceiver;
        marginReceiver = receiver;
        emit MarginReceiverChanged(oldReceiver, receiver);
    }

    function setCreationFee(uint256 fee) external onlyRole(ADMIN_ROLE) {
        if (fee > 0.1 ether) revert InvalidAdminValue();
        creationFee = fee;
        emit CreationFeeChanged(fee);
    }

    function setPreBuyFeeRate(uint256 rate) external onlyRole(ADMIN_ROLE) {
        if (rate > 600) revert InvalidAdminValue();
        preBuyFeeRate = rate;
        emit PreBuyFeeRateChanged(rate);
    }

    function setTradingFeeRate(uint256 rate) external onlyRole(ADMIN_ROLE) {
        if (rate > 200) revert InvalidAdminValue();
        tradingFeeRate = rate;
        emit TradingFeeRateChanged(rate);
    }

    function setGraduationFeeRates(uint256 platformRate, uint256 creatorRate) external onlyRole(ADMIN_ROLE) {
        if (platformRate > 1_100 || creatorRate > 500) revert InvalidAdminValue();
        graduationPlatformFeeRate = platformRate;
        graduationCreatorFeeRate = creatorRate;
        emit GraduationFeeRatesChanged(platformRate, creatorRate);
    }

    function setMinLockTime(uint256 lockTime) external onlyRole(ADMIN_ROLE) {
        minLockTime = lockTime;
        emit MinLockTimeChanged(lockTime);
    }

    function _sendNative(address receiver, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = payable(receiver).call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    function _validateTrade(address token) private view {
        TokenInfo memory info = tokenInfo[token];
        if (info.creator == address(0) || info.status != TokenStatus.TRADING) revert TokenNotTrading();
        if (info.launchTime > block.timestamp) revert TokenNotLaunchedYet();
    }

    function _changeTokenStatus(address token, TokenStatus newStatus) private {
        TokenStatus oldStatus = tokenInfo[token].status;
        tokenInfo[token].status = newStatus;
        emit TokenStatusChanged(token, oldStatus, newStatus);
    }

    function _graduationAmounts(uint256 collectedBNB, uint256 remainingTokens)
        private
        view
        returns (GraduationAmounts memory amounts)
    {
        amounts.nativePlatformFee = collectedBNB * graduationPlatformFeeRate / 10_000;
        amounts.nativeCreatorFee = collectedBNB * graduationCreatorFeeRate / 10_000;
        amounts.nativeLiquidity = collectedBNB - amounts.nativePlatformFee - amounts.nativeCreatorFee;

        amounts.tokenPlatformFee = remainingTokens * graduationPlatformFeeRate / 10_000;
        amounts.tokenCreatorFee = remainingTokens * graduationCreatorFeeRate / 10_000;
        amounts.tokenLiquidity = remainingTokens - amounts.tokenPlatformFee - amounts.tokenCreatorFee;
    }

    function _calculateInitialBuy(CreateTokenParams memory params)
        private
        pure
        returns (uint256 tokensOut, uint256 bnbRequired, uint256 newBNBReserve, uint256 newTokenReserve)
    {
        if (params.initialBuyPercentage > MAX_INITIAL_BUY_PERCENTAGE) revert InvalidInitialBuy();
        if (params.initialBuyPercentage == 0 && params.vestingAllocations.length > 0) {
            revert InvalidVestingAllocation();
        }

        tokensOut = params.totalSupply * params.initialBuyPercentage / 10_000;
        if (tokensOut > params.saleAmount || tokensOut >= params.virtualTokenReserve) revert InvalidInitialBuy();
        if (tokensOut == 0) {
            return (0, 0, params.virtualBNBReserve, params.virtualTokenReserve);
        }

        newTokenReserve = params.virtualTokenReserve - tokensOut;
        newBNBReserve = params.virtualBNBReserve * params.virtualTokenReserve / newTokenReserve;
        bnbRequired = newBNBReserve - params.virtualBNBReserve;
    }

    function _distributeInitialTokens(address tokenAddress, CreateTokenParams memory params, uint256 initialTokens)
        private
        returns (uint256 directTokens)
    {
        uint256 allocationCount = params.vestingAllocations.length;
        if (allocationCount == 0) return initialTokens;
        if (vesting == address(0)) revert InvalidVestingAllocation();

        IMEMEVesting.ScheduleInput[] memory schedules = new IMEMEVesting.ScheduleInput[](allocationCount);
        uint256 totalVestedTokens;
        uint256 totalAllocationBP;
        uint256 startTime = params.launchTime == 0 ? block.timestamp : params.launchTime;

        for (uint256 i = 0; i < allocationCount; i++) {
            VestingAllocation memory allocation = params.vestingAllocations[i];
            if (allocation.percentageBP == 0 || allocation.duration == 0) revert InvalidVestingAllocation();
            if (allocation.mode == IMEMEVesting.VestingMode.LINEAR && allocation.duration < minLockTime) {
                revert InvalidVestingAllocation();
            }

            uint256 amount = params.totalSupply * allocation.percentageBP / 10_000;
            totalAllocationBP += allocation.percentageBP;
            totalVestedTokens += amount;
            schedules[i] = IMEMEVesting.ScheduleInput({
                amount: amount, startTime: startTime, duration: allocation.duration, mode: allocation.mode
            });
        }

        if (totalAllocationBP > params.initialBuyPercentage || totalVestedTokens > initialTokens) {
            revert InvalidVestingAllocation();
        }

        MEMEToken token = MEMEToken(tokenAddress);
        token.setVestingContract(vesting);
        token.safeIncreaseAllowance(vesting, totalVestedTokens);
        IMEMEVesting(vesting).createVestingSchedules(tokenAddress, params.creator, schedules);

        emit VestingCreated(tokenAddress, params.creator, totalVestedTokens, allocationCount);
        return initialTokens - totalVestedTokens;
    }
}
