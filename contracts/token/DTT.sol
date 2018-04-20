pragma solidity ^0.4.21;

interface tokenRecipient {
    function receiveApproval (address from, uint256 value, address token, bytes extraData) external;
}

/**
 * DreamTeam token contract. It implements the next capabilities:
 * 1. Standard ERC20 functionality. [OK]
 * 2. Additional utility function approveAndCall. [OK]
 * 3. Function to rescue "lost forever" tokens, which were accidentally sent to the contract address. [OK]
 * 4. Additional transfer and approve functions which allow to distinct the transaction signer and executor,
 *    which enables accounts with no Ether on their balances to make token transfers and use DreamTeam services. [TEST]
 * 5. Token sale distribution rules. [OK]
 */
contract DTT {

    string public name;
    string public symbol;
    uint8 public decimals = 6; // Makes JavaScript able to handle precise calculations (until totalSupply < 9 milliards)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(uint => bool)) public usedSigIds; // Used in *ViaSignature(..)
    address public tokenDistributor; // Account authorized to distribute tokens only during the token distribution event
    address public rescueAccount; // Account authorized to withdraw tokens accidentally sent to this contract

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    bytes public ethSignedMessagePrefix = "\x19Ethereum Signed Message:\n32";
    enum sigStandard { typed, personal, stringHex }
    enum sigDestination { transfer, approve, approveAndCall }
    bytes32 public sigDestinationTransfer = keccak256(
        "address Token Contract Address",
        "address Sender's Address",
        "address Recipient's Address",
        "uint256 Amount to Transfer (last six digits are decimals)",
        "uint256 Fee in Tokens Paid to Executor (last six digits are decimals)",
        "uint256 Signature Expiration Timestamp (unix timestamp)",
        "uint256 Signature ID",
        "uint8 Signature Standard"
    ); // `transferViaSignature`: keccak256(address(this), from, to, value, fee, deadline, sigId, sigStandard)
    bytes32 public sigDestinationApprove = keccak256(
        "address Token Contract Address",
        "address Withdraw Approval Address",
        "address Withdraw Recipient Address",
        "uint256 Amount to Transfer (last six digits are decimals)",
        "uint256 Fee in Tokens Paid to Executor (last six digits are decimals)",
        "uint256 Signature Expiration Timestamp (unix timestamp)",
        "uint256 Signature ID",
        "uint8 Signature Standard"
    ); // `approveViaSignature`: keccak256(address(this), from, spender, value, fee, deadline, sigId, sigStandard)
    bytes32 public sigDestinationApproveAndCall = keccak256( // `approveAndCallViaSignature`
        "address Token Contract Address",
        "address Withdraw Approval Address",
        "address Withdraw Recipient Address",
        "uint256 Amount to Transfer (last six digits are decimals)",
        "bytes Data to Transfer",
        "uint256 Fee in Tokens Paid to Executor (last six digits are decimals)",
        "uint256 Signature Expiration Timestamp (unix timestamp)",
        "uint256 Signature ID",
        "uint8 Signature Standard"
    ); // `approveAndCallViaSignature`: keccak256(address(this), from, spender, value, extraData, fee, deadline, sigId, sigStandard)

    function DTT (string tokenName, string tokenSymbol) public { // todo: remove initial supply
        name = tokenName;
        symbol = tokenSymbol;
        rescueAccount = tokenDistributor = msg.sender;
    }

    /**
     * Utility internal function used to safely transfer `value` tokens `from` -> `to`. Throws if transfer is impossible.
     */
    function internalTransfer (address from, address to, uint value) internal {
        // Prevent people from accidentally burning their tokens + uint256 wrap prevention
        require(to != 0x0 && balanceOf[from] >= value && balanceOf[to] + value >= balanceOf[to]);
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    /**
     * Utility internal function used to safely transfer `value1` tokens `from` -> `to1`, and `value2` tokens
     * `from` -> `to2`, minimizing gas usage (calling `internalTransfer` twice is more expensive). Throws if
     * transfers are impossible.
     */
    function internalDoubleTransfer (address from, address to1, uint value1, address to2, uint value2) internal {
        require( // Prevent people from accidentally burning their tokens + uint256 wrap prevention
            to1 != 0x0 && to2 != 0x0 && balanceOf[from] >=
            value1 + value2 && balanceOf[to1] + value1 >= balanceOf[to1] && balanceOf[to2] + value2 >= balanceOf[to2]
        );
        balanceOf[from] -= value1 + value2;
        balanceOf[to1] += value1;
        emit Transfer(from, to1, value1);
        if (value2 > 0) {
            balanceOf[to2] += value2;
            emit Transfer(from, to2, value2);
        }
    }

    /**
     * Transfer `value` tokens to `to` address from the account of sender.
     * @param to - the address of the recipient
     * @param value - the amount to send
     */
    function transfer (address to, uint256 value) public returns (bool) {
        internalTransfer(msg.sender, to, value);
        return true;
    }

    /**
     * Internal method that makes sure that signature corresponds to a given data and some other constraints are met.
     */
    function requireSignature (
        bytes32 data, address from, uint256 deadline, uint256 sigId, bytes sig, sigStandard std, sigDestination signDest
    ) internal {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly { // solium-disable-line security/no-inline-assembly
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27)
            v += 27;
        require(block.timestamp <= deadline && !usedSigIds[from][sigId]); // solium-disable-line security/no-block-members
        if (std == sigStandard.typed) { // Typed signature
            require(
                from == ecrecover(
                    keccak256(
                        signDest == sigDestination.transfer
                            ? sigDestinationTransfer
                            : signDest == sigDestination.approve
                                ? sigDestinationApprove
                                : sigDestinationApproveAndCall,
                        data
                    ),
                    v, r, s
                )
            );
        } else if (std == sigStandard.personal) { // Ethereum signed message signature
            require(from == ecrecover(keccak256(ethSignedMessagePrefix, data), v, r, s));
        } else { // == 2; Signed string hash signature (the most expensive but universal)
            require(from == ecrecover(keccak256(ethSignedMessagePrefix, hexToString(data)), v, r, s));
        }
        usedSigIds[from][sigId] = true;
    }

    function hexToString (bytes32 sig) internal pure returns (string) { // TODO: convert to two uint256 and test gas
        bytes memory str = new bytes(64);
        for (uint8 i = 0; i < 32; ++i) {
            str[2 * i] = byte((uint8(sig[i]) / 16 < 10 ? 48 : 87) + uint8(sig[i]) / 16);
            str[2 * i + 1] = byte((uint8(sig[i]) % 16 < 10 ? 48 : 87) + (uint8(sig[i]) % 16));
        }
        return string(str);
    }

    /**
     * This function distincts transaction signer from transaction executor. It allows anyone to transfer tokens
     * from the `from` account by providing a valid signature, which can only be obtained from the `from` account
     * owner.
     * Note that passed parameters must be unique and cannot be passed twice (prevents replay attacks). When there's
     * a need to get a signature for the same transaction again, adjust the `deadline` parameter accordingly.
     */
    function transferViaSignature (
        address from,      // Account to transfer tokens from, which signed all below parameters
        address to,        // Account to transfer tokens to
        uint256 value,     // Value to transfer
        uint256 fee,       // Fee paid to transaction executor
        uint256 deadline,  // Time until the transaction can be executed by the delegate
        uint256 sigId,     // A "nonce" for the transaction. The same sigId cannot be used twice
        bytes   sig,       // Signature made by `from`, which is the proof of `from`'s agreement with the above parameters
        sigStandard sigStd // Determines how signature was made, because some standards are not implemented in some wallets (yet)
    ) public returns (bool) {
        requireSignature(
            keccak256(address(this), from, to, value, fee, deadline, sigId),
            from, deadline, sigId, sig, sigStd, sigDestination.transfer
        );
        internalDoubleTransfer(from, to, value, msg.sender, fee);
        return true;
    }

    /**
     * Transfer `value` tokens to `to` address from the `from` account, using the previously set allowance.
     * @param from - the address to transfer tokens from
     * @param to - the address of the recipient
     * @param value - the amount to send
     */
    function transferFrom (address from, address to, uint256 value) public returns (bool) {
        require(value <= allowance[from][msg.sender]); // Test whether allowance was set
        allowance[from][msg.sender] -= value;
        internalTransfer(from, to, value);
        return true;
    }

    /**
     * Allow `spender` to take `value` tokens from the transaction sender's account.
     * Beware that changing an allowance with this method brings the risk that someone may use both the old
     * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
     * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     * @param spender - the address authorized to spend
     * @param value - the maximum amount they can spend
     */
    function approve (address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * Same as `transferViaSignature`, but for approval.
     */
    function approveViaSignature (
        address from,     // Account to approve expenses on, which signed all below parameters
        address spender,  // Account to allow to do expenses
        uint256 value,    // Value to approve
        uint256 fee,      // Fee paid to transaction executor
        uint256 deadline, // Time until the transaction can be executed by the executor
        uint256 sigId,    // A "nonce" for the transaction. The same sigId cannot be used twice
        bytes   sig,      // Signature made by `from`, which is the proof of `from`'s agreement with the above parameters
        sigStandard sigStd
    ) public returns (bool) {
        requireSignature(
            keccak256(address(this), from, spender, value, fee, deadline, sigId),
            from, deadline, sigId, sig, sigStd, sigDestination.approve
        );
        allowance[from][spender] = value;
        emit Approval(from, spender, value);
        internalTransfer(from, msg.sender, value);
        return true;
    }

    /**
     * Utility function, which acts the same as approve(...) does, but also calls `receiveApproval` function on a
     * `spender` address, which is usually the address of the smart contract. In the same call, smart contract can
     * withdraw tokens from the sender's account and receive additional `extraData` for processing.
     * @param spender - the address to be authorized to spend tokens
     * @param value - the max amount the `spender` can withdraw
     * @param extraData - some extra information to send to the approved contract
     */
    function approveAndCall (address spender, uint256 value, bytes extraData) public returns (bool) {
        approve(spender, value);
        tokenRecipient(spender).receiveApproval(msg.sender, value, this, extraData);
        return true;
    }

    /**
     * Same as `approveViaSignature`, but for approveAndCall.
     */
    function approveAndCallViaSignature (
        address from,      // Account to approve expenses on, which signed all below parameters
        address spender,   // Account to allow to do expenses
        uint256 value,     // Value to transfer
        bytes   extraData, // Additional data to pass to a `tokenRecipient`
        uint256 fee,       // Fee paid to transaction executor
        uint256 deadline,  // Time until the transaction can be executed by the delegate
        uint256 sigId,     // A "nonce" for the transaction. The same sigId cannot be used twice
        bytes   sig,       // Signature made by `from`, which is the proof of `from`'s agreement with the above parameters
        sigStandard sigStd
    ) public returns (bool) {
        requireSignature(
            keccak256(address(this), from, spender, value, extraData, fee, deadline, sigId),
            from, deadline, sigId, sig, sigStd, sigDestination.approveAndCall
        );
        allowance[from][spender] = value;
        emit Approval(from, spender, value);
        tokenRecipient(spender).receiveApproval(from, value, this, extraData);
        internalTransfer(from, msg.sender, value);
        return true;
    }

    /**
     * `tokenDistributor` is authorized to distribute tokens to the parties who participated in the token sale by the
     * time the `lastMint` function is triggered, which closes the ability to mint any new tokens forever.
     * @param recipients - Addresses of token recipients
     * @param amounts - Corresponding amount of each token recipient in `recipients`
     */
    function multiMint (address[] recipients, uint256[] amounts) external {
        
        // Once the token distribution ends, tokenDistributor will become 0x0 and multiMint will never work
        require(tokenDistributor != 0x0 && tokenDistributor == msg.sender && recipients.length == amounts.length);

        uint total = 0;

        for (uint i = 0; i < recipients.length; ++i) {
            balanceOf[recipients[i]] += amounts[i];
            total += amounts[i];
            emit Transfer(0x0, recipients[i], amounts[i]);
        }

        totalSupply += total;
        
    }

    /**
     * The last mint that will ever happen. Disables the multiMint function and mints remaining 40% of tokens (in
     * regard of 60% tokens minted before) to a `tokenDistributor` address.
     */
    function lastMint () external {

        require(tokenDistributor != 0x0 && tokenDistributor == msg.sender && totalSupply > 0);

        uint256 remaining = totalSupply * 40 / 60; // Portion of tokens for DreamTeam (40%)

        // To make the total supply rounded (no fractional part), subtract the fractional part from DreamTeam's balance
        uint256 fractionalPart = (remaining + totalSupply) % (uint256(10) ** decimals);
        if (fractionalPart <= remaining)
            remaining -= fractionalPart; // Remove the fractional part to round the totalSupply

        balanceOf[tokenDistributor] += remaining;
        emit Transfer(0x0, tokenDistributor, remaining);

        totalSupply += remaining;
        tokenDistributor = 0x0; // Disable multiMint and lastMint functions forever

    }

    /**
     * ERC20 token is not designed to hold any tokens itself. This fallback function allows to rescue tokens
     * accidentally sent to the address of this smart contract.
     */
    function rescueTokens (DTT tokenContract, uint256 tokens) public {
        require(msg.sender == rescueAccount);
        tokenContract.approve(rescueAccount, tokens);
    }

    /**
     * Utility function that allows to change the rescueAccount address.
     */
    function changeRescueAccount (address newRescueAccount) public {
        require(msg.sender == rescueAccount);
        rescueAccount = newRescueAccount;
    }

}