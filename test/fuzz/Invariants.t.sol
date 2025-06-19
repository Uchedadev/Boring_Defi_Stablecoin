// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
import {console} from "forge-std/console.sol";

contract Invariants is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine engine;
    DecentralisedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        handler = new Handler(engine, dsc);
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        targetContract(address(handler));
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
        console.log(
            "Times the mint function is called",
            handler.timesMintIsCalled()
        );

        assert(wethValueUsd + wbtcValueUsd >= totalDscSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        engine.getMinHealthFactor();
        engine.getCollateralTokens();
    }
}
