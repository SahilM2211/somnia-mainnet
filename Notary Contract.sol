// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DigitalNotary
 * @dev A smart contract to cryptographically sign agreements.
 * 1. Party A proposes an agreement (stores the Hash of the text).
 * 2. Party B signs it.
 * 3. The contract proves that both parties agreed to the EXACT text at a specific time.
 *
 * Deployment: Easy (No inputs).
 */
contract DigitalNotary {

    struct Agreement {
        uint256 id;
        address partyA;      // The creator
        address partyB;      // The counterparty
        string documentHash; // SHA256/Keccak hash of the real document/text
        string title;        // Readable title (e.g. "Freelance Contract")
        bool signedByB;      // Has Party B signed?
        uint256 timestamp;   // When it was created
        uint256 signedTime;  // When it was fully signed
    }

    Agreement[] public agreements;

    // Events to prove the actions happened
    event AgreementCreated(uint256 indexed id, address indexed partyA, address indexed partyB, string title);
    event AgreementSigned(uint256 indexed id, address indexed signer, uint256 timestamp);

    // Empty constructor for error-free deployment
    constructor() {}

    /**
     * @dev Create a new agreement for someone else to sign.
     * @param _counterparty The wallet address of the person you are making a deal with.
     * @param _documentHash The hash of the text/file (calculated off-chain).
     * @param _title A short descriptive title.
     */
    function createAgreement(address _counterparty, string memory _documentHash, string memory _title) public {
        require(_counterparty != address(0), "Invalid counterparty");
        require(_counterparty != msg.sender, "Cannot sign with yourself");

        agreements.push(Agreement({
            id: agreements.length,
            partyA: msg.sender,
            partyB: _counterparty,
            documentHash: _documentHash,
            title: _title,
            signedByB: false,
            timestamp: block.timestamp,
            signedTime: 0
        }));

        emit AgreementCreated(agreements.length - 1, msg.sender, _counterparty, _title);
    }

    /**
     * @dev The counterparty calls this to sign the deal.
     */
    function signAgreement(uint256 _id) public {
        require(_id < agreements.length, "Agreement does not exist");
        Agreement storage agg = agreements[_id];

        require(msg.sender == agg.partyB, "Only the designated counterparty can sign");
        require(!agg.signedByB, "Already signed");

        agg.signedByB = true;
        agg.signedTime = block.timestamp;

        emit AgreementSigned(_id, msg.sender, block.timestamp);
    }

    // --- View Functions ---

    function getAgreementCount() public view returns (uint256) {
        return agreements.length;
    }

    function getAgreement(uint256 _id) public view returns (
        address partyA, 
        address partyB, 
        string memory title, 
        string memory docHash, 
        bool isSigned, 
        uint256 timeCreated, 
        uint256 timeSigned
    ) {
        Agreement memory a = agreements[_id];
        return (a.partyA, a.partyB, a.title, a.documentHash, a.signedByB, a.timestamp, a.signedTime);
    }
}