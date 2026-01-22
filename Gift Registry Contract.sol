// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedRegistry
 * @dev A smart contract for weddings, birthdays, or fundraising wishlists.
 * 1. Owner adds items with a price.
 * 2. Guests "buy" items (send ETH).
 * 3. Funds go instantly to the Owner.
 * 4. Item is marked as purchased forever.
 *
 * Deployment: Easy (No inputs).
 */
contract GiftRegistry is Ownable {

    struct Item {
        uint256 id;
        string name;
        uint256 price; // in wei
        bool isPurchased;
        address giftedBy; // Address of the guest
        string guestMessage; // "Happy Wedding!"
    }

    Item[] public items;

    event ItemAdded(uint256 indexed id, string name, uint256 price);
    event ItemGifted(uint256 indexed id, address indexed guest, string message);
    
    // Easy deploy: Deployer is the "Celebrant" (Owner)
    constructor() Ownable(msg.sender) {}

    /**
     * @dev Owner adds an item to the wishlist.
     */
    function addItem(string memory _name, uint256 _price) public onlyOwner {
        require(_price > 0, "Price must be > 0");
        
        items.push(Item({
            id: items.length,
            name: _name,
            price: _price,
            isPurchased: false,
            giftedBy: address(0),
            guestMessage: ""
        }));

        emit ItemAdded(items.length - 1, _name, _price);
    }

    /**
     * @dev Guest buys an item. Funds are sent to owner instantly.
     */
    function giftItem(uint256 _id, string memory _message) public payable {
        require(_id < items.length, "Item does not exist");
        Item storage item = items[_id];

        require(!item.isPurchased, "Item already gifted!");
        require(msg.value >= item.price, "Insufficient ETH sent for this item");

        // Mark as purchased
        item.isPurchased = true;
        item.giftedBy = msg.sender;
        item.guestMessage = _message;

        // Forward funds to the owner (Celebrant)
        (bool success, ) = owner().call{value: msg.value}("");
        require(success, "Transfer to owner failed");

        emit ItemGifted(_id, msg.sender, _message);
    }

    /**
     * @dev Owner can remove an item if it hasn't been bought yet.
     * (We just hide it by keeping it in array but you could use a mapping for complex logic)
     * For this simple version, we don't implement delete to keep gas low and array simple.
     */

    // --- View Functions ---
    function getItemCount() public view returns (uint256) {
        return items.length;
    }

    function getAllItems() public view returns (Item[] memory) {
        return items;
    }
}