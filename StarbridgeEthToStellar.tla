------------------------------ MODULE StarbridgeEthToStellar ------------------------------

EXTENDS Integers

\* @typeAlias: STELLAR_TX = [from : STELLAR_ACCNT, to : STELLAR_ACCNT, amount : Int, seq : Int, maxTime : Int];
\* @typeAlias: ETH_TX = [from : ETH_ACCNT, to : ETH_ACCNT, amount : Int, hash : HASH, memo : STELLAR_ACCNT];

StellarAccountId == {"1_OF_STELLAR_ACCNT","2_OF_STELLAR_ACCNT"}
EthereumAccountId == {"1_OF_ETH_ACCNT","2_OF_ETH_ACCNT"}
Amount == 0..1
SeqNum == 0..2
Time == 0..4
Hash == {"0_OF_HASH","1_OF_HASH"}
WithdrawWindow == 1 \* time window the user has to execute a withdraw operation on Stellar

BridgeStellarAccountId == "1_OF_STELLAR_ACCNT"
BridgeEthereumAccountId == "1_OF_ETH_ACCNT"

VARIABLES
    \* state of Stellar and Ethereum:
    \* @type: STELLAR_ACCNT -> Int;
    stellarBalance,
    \* @type: STELLAR_ACCNT -> Int;
    stellarSeqNum,
    \* @type: Int;
    stellarTime,
    \* @type: Set(STELLAR_TX);
    stellarMempool,
    \* @type: Set(STELLAR_TX);
    stellarExecuted,
    \* @type: ETH_ACCNT -> Int;
    ethereumBalance,
    \* @type: Set(ETH_TX);
    ethereumMempool,
    \* @type: Int -> Set(ETH_TX);
    ethereumExecuted,
    \* @type: Set(HASH);
    ethereumUsedHashes,
    \* @type: Int;
    ethereumTime,

    \* state of the bridge:
    \* @type: HASH -> Bool;
    bridgeHasLastTx,
    \* @type: HASH -> STELLAR_TX;
    bridgeLastTx,
    \* @type: Int;
    bridgeStellarTime,
    \* @type: STELLAR_ACCNT -> Int;
    bridgeStellarSeqNum,
    \* @type: Set(STELLAR_TX);
    bridgeStellarExecuted,
    \* @type: Int -> Set(ETH_TX);
    bridgeEthereumExecuted,
    \* @type: HASH -> Bool;
    bridgeRefunded

ethereumVars == <<ethereumBalance, ethereumMempool, ethereumExecuted, ethereumUsedHashes, ethereumTime>>
stellarVars == <<stellarBalance, stellarSeqNum, stellarTime, stellarMempool, stellarExecuted>>
bridgeVars == <<bridgeHasLastTx, bridgeLastTx, bridgeStellarTime, bridgeStellarSeqNum, bridgeStellarExecuted, bridgeEthereumExecuted, bridgeRefunded>>
bridgeChainsStateVars == <<bridgeStellarTime, bridgeStellarSeqNum, bridgeStellarExecuted, bridgeEthereumExecuted>>

Stellar == INSTANCE Stellar WITH
    AccountId <- StellarAccountId,
    balance <- stellarBalance,
    seqNum <- stellarSeqNum,
    time <- stellarTime,
    mempool <- stellarMempool,
    executed <- stellarExecuted

Ethereum == INSTANCE Ethereum WITH
    AccountId <- EthereumAccountId,
    balance <- ethereumBalance,
    mempool <- ethereumMempool,
    executed <- ethereumExecuted,
    usedHashes <- ethereumUsedHashes,
    time <- ethereumTime

Init ==
    /\  bridgeHasLastTx = [h \in Hash |-> FALSE]
    /\  bridgeLastTx = [h \in Hash |-> CHOOSE tx \in Stellar!Transaction : TRUE]
    /\  bridgeStellarTime = 0
    /\  bridgeStellarSeqNum = [a \in StellarAccountId |-> 0]
    /\  bridgeStellarExecuted = {}
    /\  bridgeEthereumExecuted = [t \in Time |-> {}]
    /\  bridgeRefunded = [h \in Hash |-> FALSE]
    /\  Stellar!Init /\ Ethereum!Init

TypeOkay ==
    /\  bridgeHasLastTx \in [Hash -> BOOLEAN]
    /\  bridgeLastTx \in [Hash -> Stellar!Transaction]
    /\  bridgeStellarTime \in Time
    /\  bridgeStellarSeqNum \in [StellarAccountId -> SeqNum]
    /\  bridgeStellarExecuted \in SUBSET Stellar!Transaction
    /\  bridgeEthereumExecuted \in [Time -> SUBSET Ethereum!Transaction]
    /\  bridgeRefunded \in [Hash -> BOOLEAN]
    /\  Stellar!TypeOkay /\ Ethereum!TypeOkay

SyncWithStellar ==
    /\  bridgeStellarTime' = stellarTime
    /\  bridgeStellarSeqNum' = stellarSeqNum
    /\  bridgeStellarExecuted' = stellarExecuted
    /\  UNCHANGED <<ethereumVars, stellarVars, bridgeHasLastTx, bridgeLastTx, bridgeEthereumExecuted, bridgeRefunded>>

SyncWithEthereum ==
    /\  bridgeEthereumExecuted' = ethereumExecuted
    /\  UNCHANGED <<ethereumVars, stellarVars, bridgeHasLastTx, bridgeLastTx, bridgeStellarExecuted, bridgeStellarSeqNum, bridgeStellarTime, bridgeRefunded>>

\* A withdraw transaction is irrevocably invalid when its time bound has ellapsed or the sequence number of the receiving account is higher than the transaction's sequence number
\* @type: (STELLAR_TX) => Bool;
IrrevocablyInvalid(tx) ==
  \/  tx.maxTime < bridgeStellarTime
  \/  tx.seq < bridgeStellarSeqNum[tx.from]

BridgeEthereumExecuted == UNION {bridgeEthereumExecuted[t] : t \in Time}

\* timestamp of a transaction on Ethereum as seen by the bridge
TxTime(tx) == CHOOSE t \in Time : tx \in bridgeEthereumExecuted[t]

\* The bridge signs a new withdraw transaction when:
\* It never did so before for the same hash,
\* or the previous withdraw transaction is irrevocably invalid.
\* The transaction has a time bound set to WithdrawWindow ahead of the current time.
\* But what is the current time?
\* Initially it can be the time of the tx as recorded on ethereum, but what is it afterwards?
\* For now, we use previousTx.maxTime+WithdrawWindow
SignWithdrawTransaction == \E tx \in BridgeEthereumExecuted :
  /\  \neg bridgeRefunded[tx.hash]
  /\  \/  \neg bridgeHasLastTx[tx.hash]
      \/  IrrevocablyInvalid(bridgeLastTx[tx.hash])
  /\ \E seqNum \in SeqNum  : \* chosen by the client
      LET timeBound ==
            IF \neg bridgeHasLastTx[tx.hash]
              THEN TxTime(tx)+WithdrawWindow
              ELSE bridgeLastTx[tx.hash].time+WithdrawWindow
          withdrawTx == [
            from |-> BridgeStellarAccountId,
            to |-> tx.memo,
            amount |-> tx.amount,
            seq |-> seqNum,
            maxTime |-> timeBound]
      IN
        /\ timeBound \in Time \* for the model-checker
        /\ Stellar!ReceiveTx(withdrawTx)
        /\ bridgeHasLastTx' = [bridgeHasLastTx EXCEPT ![tx.hash] = TRUE]
        /\ bridgeLastTx' = [bridgeLastTx EXCEPT ![tx.hash] = withdrawTx]
  /\  UNCHANGED <<ethereumVars, bridgeChainsStateVars, bridgeRefunded>>

SignRefundTransaction == \E tx \in BridgeEthereumExecuted :
  /\  bridgeHasLastTx[tx.hash]
  /\  IrrevocablyInvalid(bridgeLastTx[tx.hash])
  /\  \neg bridgeRefunded[tx.hash]
  /\  \E h \in Hash :
      LET refundTx == [
        from |-> BridgeEthereumAccountId,
        to |-> tx.from,
        amount |-> tx.amount,
        hash |-> h,
        memo |-> bridgeLastTx[tx.hash].to] \* memo is arbitrary
      IN
        Ethereum!ReceiveTx(refundTx)
  /\  bridgeRefunded' = [bridgeRefunded EXCEPT ![tx.hash] = TRUE]
  /\  UNCHANGED <<stellarVars, bridgeHasLastTx, bridgeLastTx, bridgeChainsStateVars>>

UserInitiates ==
  \* a client initiates a transfer on Ethereum:
  /\ UNCHANGED <<stellarVars, bridgeVars>>
  /\ \E src \in EthereumAccountId \ {BridgeEthereumAccountId},
          x \in Amount \ {0}, h \in Hash, dst \in StellarAccountId \ {BridgeStellarAccountId} :
       LET tx == [from |-> src, to |-> BridgeEthereumAccountId, amount |-> x, hash |-> h, memo |-> dst]
       IN  Ethereum!ReceiveTx(tx)

Next ==
    \/  SyncWithStellar
    \/  SyncWithEthereum
    \/  UserInitiates
    \/  SignWithdrawTransaction
    \/  SignRefundTransaction
    \/ \* internal stellar transitions:
      /\ UNCHANGED <<ethereumVars, bridgeVars>>
      /\ \/  Stellar!Tick
         \/  Stellar!ExecuteTx
    \/ \* internal ethereum transitions:
      /\ UNCHANGED <<stellarVars, bridgeVars>>
      /\ \/ Ethereum!ExecuteTx
         \/ Ethereum!Tick

Inv == Ethereum!Inv
Inv_ == TypeOkay /\ Inv
=============================================================================
