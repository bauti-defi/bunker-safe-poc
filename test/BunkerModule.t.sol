// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Safe} from "@safe/Safe.sol";
import {SafeProxyFactory} from "@safe/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "@safe/libraries/MultiSendCallOnly.sol";
import {ISafe} from "@safe/interfaces/ISafe.sol";
import {Enum} from "@safe/libraries/Enum.sol";
import {IOwnerManager} from "@safe/interfaces/IOwnerManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BunkerModule} from "../src/BunkerModule.sol";
import {BunkerSetup} from "../src/BunkerSetup.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Reverter {
    error Nope();

    function boom() external pure {
        revert Nope();
    }
}

contract BunkerModuleTest is Test {
    address internal constant SENTINEL = address(0x1);
    uint256 internal constant FAR_FUTURE = type(uint256).max;
    uint8 internal constant CALL = uint8(Enum.Operation.Call);
    uint8 internal constant DELEGATECALL = uint8(Enum.Operation.DelegateCall);

    ISafe internal safe;
    BunkerModule internal module;
    MockToken internal token;
    Reverter internal reverter;
    MultiSendCallOnly internal multiSend;

    address internal breakGlass;
    uint256 internal breakGlassPk;
    address internal recipient = makeAddr("recipient");
    address internal relayer = makeAddr("relayer");

    // Deterministic chain of one-time hot keys: hot[0] is installed at bootstrap.
    uint256[] internal hotPk;
    address[] internal hot;

    function setUp() public {
        (breakGlass, breakGlassPk) = makeAddrAndKey("breakGlass");
        for (uint256 i; i < 6; ++i) {
            (address k, uint256 pk) = makeAddrAndKey(string.concat("hot", vm.toString(i)));
            hot.push(k);
            hotPk.push(pk);
        }

        Safe singleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        BunkerSetup bunkerSetup = new BunkerSetup();
        multiSend = new MultiSendCallOnly();

        address[] memory owners = new address[](1);
        owners[0] = breakGlass;
        bytes memory initializer = abi.encodeCall(
            Safe.setup,
            (
                owners,
                1,
                address(bunkerSetup),
                abi.encodeCall(BunkerSetup.deployAndEnable, (hot[0])),
                address(0),
                address(0),
                0,
                payable(address(0))
            )
        );
        safe = ISafe(payable(address(factory.createProxyWithNonce(address(singleton), initializer, 0))));
        (address[] memory modules,) = safe.getModulesPaginated(SENTINEL, 10);
        module = BunkerModule(modules[0]);

        token = new MockToken();
        reverter = new Reverter();
        vm.deal(address(safe), 10 ether);
        token.mint(address(safe), 1_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _call(address to, uint256 value, bytes memory data, address next)
        internal
        pure
        returns (BunkerModule.Op memory)
    {
        return BunkerModule.Op({
            to: to, value: value, data: data, operation: CALL, nextHotKey: next, deadline: FAR_FUTURE, minPayloadGas: 0
        });
    }

    function _batch(bytes memory transactions, address next) internal view returns (BunkerModule.Op memory) {
        return BunkerModule.Op({
            to: address(multiSend),
            value: 0,
            data: abi.encodeCall(MultiSendCallOnly.multiSend, (transactions)),
            operation: DELEGATECALL,
            nextHotKey: next,
            deadline: FAR_FUTURE,
            minPayloadGas: 0
        });
    }

    function _entry(uint8 operation, address to, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(operation, to, value, data.length, data);
    }

    function _sign(uint256 pk, BunkerModule.Op memory op) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, module.hashOp(op));
        return abi.encodePacked(r, s, v);
    }

    function _submit(BunkerModule.Op memory op, bytes memory sig) internal returns (BunkerModule.Outcome) {
        vm.prank(relayer);
        return module.execute(op, sig);
    }

    function _assertRotated(address from, address to) internal view {
        assertTrue(module.burned(from), "signer not burned");
        assertEq(module.hotKey(), to, "hot key not rotated");
    }

    function _swapBreakGlassCalldata(address newOwner) internal view returns (bytes memory) {
        return abi.encodeCall(IOwnerManager.swapOwner, (SENTINEL, breakGlass, newOwner));
    }

    // -------------------------------------------------------------- bootstrap

    function test_bootstrap_breakGlassIsSoleOwnerAndNeverSigned() public view {
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], breakGlass);
        assertEq(safe.getThreshold(), 1);
        assertTrue(safe.isModuleEnabled(address(module)));
        assertEq(address(module.SAFE()), address(safe));
        assertEq(module.hotKey(), hot[0]);
        // Bootstrap went through setup's delegatecall: no Safe tx was ever signed by the owner.
        assertEq(safe.nonce(), 0);
    }

    // ------------------------------------------------------------ happy path

    function test_execute_multiSendBatchRunsFromSafeAndRotates() public {
        bytes memory transactions = abi.encodePacked(
            _entry(CALL, recipient, 1 ether, ""),
            _entry(CALL, address(token), 0, abi.encodeCall(ERC20.transfer, (recipient, 100e18)))
        );
        BunkerModule.Op memory op = _batch(transactions, hot[1]);

        BunkerModule.Outcome outcome = _submit(op, _sign(hotPk[0], op));

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.Executed));
        assertEq(recipient.balance, 1 ether);
        assertEq(token.balanceOf(recipient), 100e18);
        _assertRotated(hot[0], hot[1]);
    }

    function test_execute_singleCallRunsAndConsumedSignatureCannotBeReplayed() public {
        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[1]);
        bytes memory sig = _sign(hotPk[0], op);

        assertEq(uint8(_submit(op, sig)), uint8(BunkerModule.Outcome.Executed));
        assertEq(recipient.balance, 1 ether);
        _assertRotated(hot[0], hot[1]);

        vm.expectRevert(abi.encodeWithSelector(BunkerModule.NotHotKey.selector, hot[0]));
        _submit(op, sig);
        assertEq(recipient.balance, 1 ether);
    }

    function test_execute_rejectsSignatureFromNonHotKey() public {
        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[1]);
        bytes memory ownerSig = _sign(breakGlassPk, op);
        bytes memory futureKeySig = _sign(hotPk[1], op);

        vm.expectRevert(abi.encodeWithSelector(BunkerModule.NotHotKey.selector, breakGlass));
        _submit(op, ownerSig);

        vm.expectRevert(abi.encodeWithSelector(BunkerModule.NotHotKey.selector, hot[1]));
        _submit(op, futureKeySig);
        assertEq(module.hotKey(), hot[0]);
    }

    function test_execute_signatureIsBoundToChain() public {
        BunkerModule.Op memory op = _call(recipient, 0, "", hot[1]);
        bytes memory sig = _sign(hotPk[0], op);
        vm.chainId(block.chainid + 1);
        vm.expectPartialRevert(BunkerModule.NotHotKey.selector);
        _submit(op, sig);
    }

    // ------------------------------------- rotation survives payload outcomes

    function test_payloadRevert_rollsBackWholeBatchButStillRotates() public {
        bytes memory transactions = abi.encodePacked(
            _entry(CALL, recipient, 1 ether, ""), _entry(CALL, address(reverter), 0, abi.encodeCall(Reverter.boom, ()))
        );
        BunkerModule.Op memory op = _batch(transactions, hot[1]);

        BunkerModule.Outcome outcome = _submit(op, _sign(hotPk[0], op));

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.PayloadReverted));
        assertEq(recipient.balance, 0, "batch not atomic");
        _assertRotated(hot[0], hot[1]);
    }

    function test_expiredOp_skipsPayloadButStillRotates() public {
        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[1]);
        op.deadline = block.timestamp;
        bytes memory sig = _sign(hotPk[0], op);
        vm.warp(block.timestamp + 1);

        BunkerModule.Outcome outcome = _submit(op, sig);

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.Expired));
        assertEq(recipient.balance, 0);
        _assertRotated(hot[0], hot[1]);
    }

    function test_invalidOperation_skipsPayloadButStillRotates() public {
        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[1]);
        op.operation = 2;

        BunkerModule.Outcome outcome = _submit(op, _sign(hotPk[0], op));

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.InvalidOperation));
        assertEq(recipient.balance, 0);
        _assertRotated(hot[0], hot[1]);
    }

    /// The payload may administer the Safe and the module (the operator is trusted), but even through
    /// `setHotKey` it can never bring back a burned key: that would make its old signatures replayable.
    function test_payloadCannotReinstateBurnedHotKey() public {
        BunkerModule.Op memory op = _call(address(module), 0, abi.encodeCall(BunkerModule.setHotKey, (hot[0])), hot[1]);
        bytes memory sig = _sign(hotPk[0], op);

        BunkerModule.Outcome outcome = _submit(op, sig);

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.PayloadReverted));
        _assertRotated(hot[0], hot[1]);
        vm.expectRevert(abi.encodeWithSelector(BunkerModule.NotHotKey.selector, hot[0]));
        _submit(op, sig);
    }

    function test_emptyBatch_isAllowedRotateOnlyOp() public {
        BunkerModule.Op memory op = _batch("", hot[1]);
        assertEq(uint8(_submit(op, _sign(hotPk[0], op))), uint8(BunkerModule.Outcome.Executed));
        _assertRotated(hot[0], hot[1]);
    }

    function test_payloadCannotReenterWithNextHotKey() public {
        // The payload makes the Safe call a contract that calls execute() with an op pre-signed by
        // the next key.
        BunkerModule.Op memory inner = _call(recipient, 5 ether, "", hot[2]);
        bytes memory innerSig = _sign(hotPk[1], inner);
        BunkerModule.Op memory outer = _call(address(this), 0, abi.encodeCall(this.reenter, (inner, innerSig)), hot[1]);

        BunkerModule.Outcome outcome = _submit(outer, _sign(hotPk[0], outer));

        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.PayloadReverted));
        assertEq(recipient.balance, 0);
        _assertRotated(hot[0], hot[1]);
    }

    function reenter(BunkerModule.Op calldata op, bytes calldata sig) external {
        module.execute(op, sig);
    }

    // --------------------------------------------------- invalid next hot key

    function test_invalidNextHotKey_freezesModuleAndSkipsPayload() public {
        address[2] memory invalid = [address(0), hot[0]];
        for (uint256 i; i < invalid.length; ++i) {
            uint256 snap = vm.snapshotState();
            BunkerModule.Op memory op = _call(recipient, 1 ether, "", invalid[i]);

            BunkerModule.Outcome outcome = _submit(op, _sign(hotPk[0], op));

            assertEq(uint8(outcome), uint8(BunkerModule.Outcome.Frozen));
            assertEq(recipient.balance, 0);
            _assertRotated(hot[0], address(0));

            BunkerModule.Op memory next = _call(recipient, 0, "", hot[2]);
            bytes memory nextSig = _sign(hotPk[1], next);
            vm.expectRevert(BunkerModule.ModuleFrozen.selector);
            _submit(next, nextSig);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------- gas griefing

    function test_insufficientPayloadGas_revertsAndAnyoneCanRetry() public {
        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[1]);
        op.minPayloadGas = 500_000;
        bytes memory sig = _sign(hotPk[0], op);

        vm.prank(relayer);
        vm.expectPartialRevert(BunkerModule.InsufficientGas.selector);
        module.execute{gas: 300_000}(op, sig);
        assertEq(module.hotKey(), hot[0], "griefed submission must not consume the key");

        // The same public signature is now relayed by someone else with enough gas.
        vm.prank(makeAddr("otherRelayer"));
        BunkerModule.Outcome outcome = module.execute{gas: 1_000_000}(op, sig);
        assertEq(uint8(outcome), uint8(BunkerModule.Outcome.Executed));
        assertEq(recipient.balance, 1 ether);
        _assertRotated(hot[0], hot[1]);
    }

    // ------------------------------------------------------------ break glass

    function test_breakGlass_resetsHotKeyAndRotatesOwnerAtomically() public {
        address newBreakGlass = makeAddr("breakGlass2");
        bytes memory batch = abi.encodePacked(
            _entry(CALL, address(module), 0, abi.encodeCall(BunkerModule.setHotKey, (hot[3]))),
            _entry(CALL, address(safe), 0, _swapBreakGlassCalldata(newBreakGlass))
        );
        _execBySafeOwner(address(multiSend), abi.encodeCall(MultiSendCallOnly.multiSend, (batch)));

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newBreakGlass);
        _assertRotated(hot[0], hot[3]);

        BunkerModule.Op memory op = _call(recipient, 1 ether, "", hot[4]);
        _submit(op, _sign(hotPk[3], op));
        assertEq(recipient.balance, 1 ether);
    }

    function test_setHotKey_onlyCallableBySafe() public {
        vm.prank(relayer);
        vm.expectRevert(BunkerModule.OnlySafe.selector);
        module.setHotKey(hot[1]);
    }

    function test_setHotKey_rejectsBurnedKeyAndAllowsExplicitFreeze() public {
        BunkerModule.Op memory op = _call(recipient, 0, "", hot[1]);
        _submit(op, _sign(hotPk[0], op));

        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(BunkerModule.InvalidHotKey.selector, hot[0]));
        module.setHotKey(hot[0]);

        vm.prank(address(safe));
        module.setHotKey(address(0));
        _assertRotated(hot[1], address(0));
    }

    function _execBySafeOwner(address to, bytes memory data) internal {
        bytes memory signature = _signSafeTx(to, data);
        bool ok = safe.execTransaction(
            to, 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), signature
        );
        assertTrue(ok);
    }

    function _signSafeTx(address to, bytes memory data) internal view returns (bytes memory) {
        bytes32 txHash = safe.getTransactionHash(
            to, 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), safe.nonce()
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(breakGlassPk, txHash);
        return abi.encodePacked(r, s, v);
    }
}
