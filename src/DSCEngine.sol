// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {DecentralisedStableCoin} from "src/DecentralisedStableCoin.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
/*
 * @title DSCEngine
 * @author Simon Jonsson
 * This is done as coursework for Patrick Collins' Advanced Foundry course. Github repo https://github.com/Cyfrin/foundry-defi-stablecoin-cu
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////////////
    //  Errors               //
    ///////////////////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokeNotSupported();
    error DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustMatch();
    error DSCEngine__TransferFailed();
    error DSCEngine__ZeroAddressIsNotValidUser();
    error DSCEngine__HealthFactorBelowMinimum(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 healthFactor);

    ///////////////////////////
    //  State variables      //
    ///////////////////////////
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 public constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant FEED_PRECISION = 1e8;

    mapping(address token => address priceFeed) public s_priceFeeds;
    mapping(address => bool) private s_supportedTokens;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_DSCMinted;
    uint256 public totalCollateral;
    uint256 public totalDsc;
    DecentralisedStableCoin public immutable i_dsc;

    address[] private s_collateralTokens;

    ///////////////////////////
    //   Events              //
    ///////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed token, address indexed from, address indexed to, uint256 amount);
    event DSCMinted(address indexed user, uint256 indexed amount);

    ///////////////////////////
    //   Modifiers           //
    ///////////////////////////

    modifier nonZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isSupportedToken(address _token) {
        if (_token != address(0)) {
            revert DSCEngine__TokeNotSupported();
        }
        _;
    }

    ///////////////////////////
    //   Constructor         //
    ///////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (tokenAddresses[i] == address(0) || priceFeedAddresses[i] == address(0)) {
                revert DSCEngine__TokeNotSupported();
            }
            s_supportedTokens[tokenAddresses[i]] = true;
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralisedStableCoin(dscAddress);
    }

    ///////////////////////////
    //   External Functions  //
    ///////////////////////////

    function depositCollateralAndMintDsc(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmount)
        external
        nonZero(collateralAmount)
        isSupportedToken(collateralTokenAddress)
    {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDsc(dscAmount);
    }

    function depositCollateral(address collateralTokenAddress, uint256 amount)
        external
        nonZero(amount)
        isSupportedToken(collateralTokenAddress)
        nonReentrant
        returns (bool)
    {
        // Transfer the collateral from the user to this contract
        // Increase the collateral balance of the user
        // Increase the total collateral balance
        // Emit a DepositCollateral event
        s_collateralDeposited[msg.sender][collateralTokenAddress] += amount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, amount);
        bool success = ERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        return success;
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc(uint256 amount) external nonReentrant nonZero(amount) {
        s_DSCMinted[msg.sender] += amount;
        emit DSCMinted(msg.sender, amount);

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @param amount The amount of DSC to burn
     */
    function burnDsc(uint256 amount) public nonZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param user The user to liquidate
     * @param dscAmountToPayBack The amount of DSC to pay back
     *
     */
    function liquidate(address collateralAddress, address user, uint256 dscAmountToPayBack) external {
        // Check so the user health factor is below minimum.
        uint256 healtFactorBefore = _healthFactor(msg.sender);
        if (healthFactorBefore > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk(healthFactorBefore);
        }
        // Calculate the collateral value of the DSC paid back.
        uint256 tokenAmount = getTokenAmountFromUsd(collateralAddress, dscAmountToPayBack);
        // Calculate the liquidation bonus
        uint256 liquidationBonus = (tokenAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Transfer the collateral to the liquidator
        uint256 totalCollateralToRedeem = tokenAmount + liquidationBonus;
        _redeemCollateral(collateralAddress, user, msg.sender, totalCollateralToRedeem);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= healthFactorBefore) {
            revert DSCEngine__HealthFactorNotImproved(endingHealthFactor);
        }

        -_revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    //////////////////////////////////////////
    //   Internal  and Private functions    //
    //////////////////////////////////////////

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private nonZero(amountDscToBurn) {
        s_DSCMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(address collateralAddress, address from, address to, uint256 amount)
        private
        nonReentrant
        nonZero(amount)
    {
        CollateralDeposited[from][collateralAddress] -= amount;
        emit CollateralRedeemed(collateralAddress, from, to, amount);
        bool success = ERC20(collateralAddress).transferFrom(from, to, amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowMinimum(healthFactor);
        }
    }

    function _healthFactor(address user) internal view returns (uint256) {
        if (user == address(0)) {
            revert DSCEngine__ZeroAddressIsNotValidUser();
        }
        (uint256 dsMinted, uint256 collateralValueUsdc) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueUsdc * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / dsMinted;
    }

    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 dsMinted, uint256 collateralValueUsdc)
    {
        uint256 _totalCollateral = getCollateralValueUsd(user);
        uint256 _dsMinted = s_DSCMinted[user];
        return (_dsMinted, _totalCollateral);
    }

    /////////////////////////////////////////////
    //   Public and external view functions    //
    /////////////////////////////////////////////
    function getCollateralValueUsd(address user) public view returns (uint256) {
        uint256 _totalCollateral;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address tokenAddress = s_collateralTokens[i];
            uint256 userCollateral = s_collateralDeposited[user][tokenAddress];
            uint256 usdValue = getUsdValue(tokenAddress, userCollateral);
            _totalCollateral += usdValue;
        }
        return _totalCollateral;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getUsdValue(address tokenAddress, uint256 value) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * value) / FEED_PRECISION;
    }
}

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
