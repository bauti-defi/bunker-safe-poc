// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISafe} from "@safe/interfaces/ISafe.sol";
import {BunkerModule} from "./BunkerModule.sol";

/// @title BunkerSetup
/// @notice Delegatecall target for `Safe.setup(..., to, data, ...)`. Deploys a BunkerModule bound to
///         the Safe being created and enables it, so the break-glass owner never has to sign a
///         transaction to bootstrap bunker mode.
contract BunkerSetup {
    address private immutable SELF = address(this);

    error OnlyDelegateCall();

    function deployAndEnable(address initialHotKey) external {
        if (address(this) == SELF) revert OnlyDelegateCall();
        // Runs in the Safe's context: `address(this)` is the Safe, so the module's creator and bound
        // Safe are the same address, and `enableModule` passes the Safe's `authorized` check.
        BunkerModule module = new BunkerModule(ISafe(payable(address(this))), initialHotKey);
        ISafe(payable(address(this))).enableModule(address(module));
    }
}
