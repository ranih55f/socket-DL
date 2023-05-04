// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../../Setup.t.sol";
import "../../../contracts/switchboard/native/PolygonL2Switchboard.sol";

// Goerli -> mumbai
contract PolygonL2SwitchboardTest is Setup {
    bytes32[] roots;
    uint256 nonce;

    uint256 confirmGasLimit_ = 300000;
    uint256 initiateGasLimit_ = 300000;
    uint256 executionOverhead_ = 300000;
    address fxChild_ = 0xCf73231F28B7331BBe3124B907840A94851f9f11;

    IGasPriceOracle gasPriceOracle_;

    PolygonL2Switchboard polygonL2Switchboard;
    ICapacitor singleCapacitor;

    function setUp() external {
        initialise();
        _a.chainSlug = uint32(uint256(80001));
        _b.chainSlug = uint32(uint256(5));

        uint256 fork = vm.createFork(
            vm.envString("POLYGON_MUMBAI_RPC"),
            32375450
        );
        vm.selectFork(fork);

        uint256[] memory transmitterPivateKeys = new uint256[](1);
        transmitterPivateKeys[0] = _transmitterPrivateKey;

        _chainSetup(transmitterPivateKeys);
    }

    function testInitateNativeConfirmation() public {
        address socketAddress = address(_a.socket__);

        vm.startPrank(socketAddress);

        bytes32 packedMessage = _a.hasher__.packMessage(
            _a.chainSlug,
            msg.sender,
            _b.chainSlug,
            0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1,
            0,
            1000000,
            100,
            abi.encode(msg.sender)
        );

        singleCapacitor.addPackedMessage(packedMessage);

        (, bytes32 packetId, ) = _getLatestSignature(
            _a,
            address(singleCapacitor),
            _b.chainSlug
        );
        polygonL2Switchboard.initiateNativeConfirmation(packetId);
        vm.stopPrank();
    }

    function _chainSetup(uint256[] memory transmitterPrivateKeys_) internal {
        _watcher = vm.addr(_watcherPrivateKey);
        _transmitter = vm.addr(_transmitterPrivateKey);

        deployContractsOnSingleChain(_a, _b.chainSlug, transmitterPrivateKeys_);
    }

    function deployContractsOnSingleChain(
        ChainContext storage cc_,
        uint256 remoteChainSlug_,
        uint256[] memory transmitterPrivateKeys_
    ) internal {
        // deploy socket setup
        deploySocket(cc_, _socketOwner);

        vm.startPrank(_socketOwner);

        cc_.transmitManager__.grantRoleWithSlug(
            GAS_LIMIT_UPDATER_ROLE,
            remoteChainSlug_,
            _socketOwner
        );

        vm.stopPrank();

        bytes32 digest = keccak256(
            abi.encode(
                PROPOSE_GAS_LIMIT_UPDATE_SIG_IDENTIFIER,
                cc_.chainSlug,
                remoteChainSlug_,
                cc_.transmitterNonce,
                _proposeGasLimit
            )
        );
        bytes memory sig = _createSignature(digest, _socketOwnerPrivateKey);
        cc_.transmitManager__.setProposeGasLimit(
            cc_.transmitterNonce++,
            remoteChainSlug_,
            _proposeGasLimit,
            sig
        );

        SocketConfigContext memory scc_ = addPolygonL2Switchboard(
            cc_,
            remoteChainSlug_,
            _capacitorType
        );
        cc_.configs__.push(scc_);

        // add roles
        hoax(_socketOwner);
        cc_.executionManager__.grantRole(EXECUTOR_ROLE, _executor);
        _addTransmitters(transmitterPrivateKeys_, cc_, remoteChainSlug_);
    }

    function deploySocket(
        ChainContext storage cc_,
        address deployer_
    ) internal {
        vm.startPrank(deployer_);

        cc_.hasher__ = new Hasher();
        cc_.sigVerifier__ = new SignatureVerifier();
        cc_.capacitorFactory__ = new CapacitorFactory(deployer_);
        cc_.gasPriceOracle__ = new GasPriceOracle(
            deployer_,
            uint32(cc_.chainSlug)
        );
        cc_.executionManager__ = new ExecutionManager(
            cc_.gasPriceOracle__,
            deployer_
        );

        cc_.transmitManager__ = new TransmitManager(
            cc_.sigVerifier__,
            cc_.gasPriceOracle__,
            deployer_,
            cc_.chainSlug,
            _sealGasLimit
        );

        cc_.gasPriceOracle__.grantRole(GOVERNANCE_ROLE, deployer_);
        cc_.gasPriceOracle__.grantRole(GAS_LIMIT_UPDATER_ROLE, deployer_);

        cc_.gasPriceOracle__.setTransmitManager(cc_.transmitManager__);

        cc_.socket__ = new Socket(
            uint32(cc_.chainSlug),
            address(cc_.hasher__),
            address(cc_.transmitManager__),
            address(cc_.executionManager__),
            address(cc_.capacitorFactory__),
            deployer_
        );

        vm.stopPrank();
    }

    function addPolygonL2Switchboard(
        ChainContext storage cc_,
        uint256 remoteChainSlug_,
        uint256 capacitorType_
    ) internal returns (SocketConfigContext memory scc_) {
        polygonL2Switchboard = new PolygonL2Switchboard(
            cc_.chainSlug,
            confirmGasLimit_,
            initiateGasLimit_,
            executionOverhead_,
            fxChild_,
            _socketOwner,
            address(cc_.socket__),
            cc_.gasPriceOracle__
        );

        scc_ = registerSwitchbaord(
            cc_,
            _socketOwner,
            address(polygonL2Switchboard),
            remoteChainSlug_,
            capacitorType_
        );
    }

    function registerSwitchbaord(
        ChainContext storage cc_,
        address deployer_,
        address switchBoardAddress_,
        uint256 remoteChainSlug_,
        uint256 capacitorType_
    ) internal returns (SocketConfigContext memory scc_) {
        vm.startPrank(deployer_);
        cc_.socket__.registerSwitchBoard(
            switchBoardAddress_,
            DEFAULT_BATCH_LENGTH,
            uint32(remoteChainSlug_),
            uint32(capacitorType_)
        );

        scc_.siblingChainSlug = remoteChainSlug_;
        scc_.capacitor__ = cc_.socket__.capacitors__(
            switchBoardAddress_,
            remoteChainSlug_
        );
        singleCapacitor = scc_.capacitor__;

        scc_.decapacitor__ = cc_.socket__.decapacitors__(
            switchBoardAddress_,
            remoteChainSlug_
        );
        scc_.switchboard__ = ISwitchboard(switchBoardAddress_);

        polygonL2Switchboard.grantRole(GOVERNANCE_ROLE, deployer_);
        vm.stopPrank();
    }
}
