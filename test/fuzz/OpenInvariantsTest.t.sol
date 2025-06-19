// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// The invariants will contain our properties that we want to test

//First, let us know our invaiants.
/*
1. The total supply of DSC should always be less than the value of the collateral.
2. Getter view functions should never revert.
*/

/*
import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine engine;
    DecentralisedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreCollateralThanDsc() public view {
        // We are getting the total value of the collateral in the engine and comparing it to the total supply of DSC
        uint256 totalDscSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValueUsd = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValueUsd = engine.getUsdValue(wbtc, totalBtcDeposited);

        console.log("wethValueUsd: ", wethValueUsd);
        console.log("wbtcValueUsd: ", wbtcValueUsd);
        console.log("totalDscSupply: ", totalDscSupply);

        assert(wethValueUsd + wbtcValueUsd >= totalDscSupply);
    }
}
*/
