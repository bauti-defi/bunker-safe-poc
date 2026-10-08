// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Safe} from "@safe/Safe.sol";
import {SafeProxyFactory} from "@safe/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "@safe/libraries/MultiSendCallOnly.sol";
import {ISafe} from "@safe/interfaces/ISafe.sol";

import {BunkerSetup} from "../src/BunkerSetup.sol";

/// @notice Deploys Safe 1.5.0 infra (singleton, factory, MultiSendCallOnly) plus a bunker-mode Safe on
///         a dev chain. Env: BREAK_GLASS (sole Safe owner), HOT_KEY (initial hot key), SALT (proxy
///         salt nonce). Production chains already have canonical Safe deployments; this script deploys
///         fresh copies and is meant for local nodes only.
contract DeployBunkerSafe is Script {
    address internal constant SENTINEL = address(0x1);

    function run() external returns (ISafe safe, address module) {
        address breakGlass = vm.envAddress("BREAK_GLASS");
        address hotKey = vm.envAddress("HOT_KEY");
        uint256 salt = vm.envOr("SALT", uint256(0));

        address[] memory owners = new address[](1);
        owners[0] = breakGlass;

        vm.startBroadcast();
        Safe singleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        BunkerSetup bunkerSetup = new BunkerSetup();
        MultiSendCallOnly multiSend = new MultiSendCallOnly();
        bytes memory initializer = abi.encodeCall(
            Safe.setup,
            (
                owners,
                1,
                address(bunkerSetup),
                abi.encodeCall(BunkerSetup.deployAndEnable, (hotKey)),
                address(0),
                address(0),
                0,
                payable(address(0))
            )
        );
        safe = ISafe(payable(address(factory.createProxyWithNonce(address(singleton), initializer, salt))));
        vm.stopBroadcast();

        (address[] memory modules,) = safe.getModulesPaginated(SENTINEL, 10);
        module = modules[0];
        console2.log("SAFE", address(safe));
        console2.log("MULTISEND", address(multiSend));
        console2.log("MODULE", module);
    }
}
