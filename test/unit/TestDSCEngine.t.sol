// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DSCEngine} from "src/DSCEngine.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {Test, console} from "forge-std/Test.sol";
import {DeployDSCEngine} from "script/DeployDSCEngine.s.sol";
import {DecentralisedStableCoin} from "src/DecentralisedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract TestDSCEngine is Test {
    DSCEngine public dscEngine;
    DecentralisedStableCoin public dsc;
    HelperConfig public helperConfig;
    DeployDSCEngine private dscEngineDeployer;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address bob;
    address alice;

    function setUp() public {
        dscEngineDeployer = new DeployDSCEngine();
        (dsc, dscEngine, helperConfig) = dscEngineDeployer.run();

        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        bob = makeAddr("bob");
        alice = makeAddr("alice");
    }

    function testDSCEngine() public view {
        // Test that the contract is deployed
        assertEq(address(dscEngine) != address(0), true);
    }

    ////////////////////////////////////////////////
    // Test AggregatorV3Interface assumptions     //
    ////////////////////////////////////////////////
    function testCheckOurAssumedDecialsAreCorrect() public view {
        uint256 priceFeedDecimalsCallResult = AggregatorV3Interface(wethUsdPriceFeed).decimals();
        console.log("Price feed decimals: ", priceFeedDecimalsCallResult);
        console.log("powerOfTen(priceFeedDecimalsCallResult): ", powerOfTen(priceFeedDecimalsCallResult));
        console.log("dscEngine.FEED_PRECISION(): ", dscEngine.FEED_PRECISION());
        require(
            powerOfTen(priceFeedDecimalsCallResult) == dscEngine.FEED_PRECISION(),
            "Price feed decimals do not match our assumed value"
        );
    }

    function testPrecisionMakesSense() public view {
        require(
            dscEngine.FEED_PRECISION() * dscEngine.ADDITIONAL_FEED_PRECISION() == dscEngine.PRECISION(),
            "Price feed precision and Additional feed precision does not multiply to overall Precison"
        );
    }

    ////////////////////////////////////////////////
    // Price tests                                //
    ////////////////////////////////////////////////
    function testGetUsdValue() public view {
        uint256 price = dscEngine.getUsdValue(weth, 1 ether);
        console.log("Price of WETH: ", price);
        require(price > 0, "Price of WETH is not greater than 0");
    }

    ////////////////////////////////////////////////
    // depositCollateral tests                    //
    ////////////////////////////////////////////////
    function testDepositCollateralRevertIfZero() public {
        vm.prank(bob);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    ////////////////////////////////////////////////
    // Helper functions                           //
    ////////////////////////////////////////////////

    // Power function to calculate 10^x
    function powerOfTen(uint256 exponent) internal pure returns (uint256) {
        uint256 result = 1;
        for (uint256 i = 0; i < exponent; i++) {
            result *= 10;
        }
        return result;
    }
}
