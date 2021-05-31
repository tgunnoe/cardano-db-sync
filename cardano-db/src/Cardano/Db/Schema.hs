{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Db.Schema where

import           Cardano.Db.Schema.Orphans ()

import           Cardano.Db.Types (DbInt65, DbLovelace, DbWord64)

import           Data.ByteString.Char8 (ByteString)
import           Data.Int (Int64)
import           Data.Text (Text)
import           Data.Time.Clock (UTCTime)
import           Data.WideWord.Word128 (Word128)
import           Data.Word (Word16, Word64)

-- Do not use explicit imports from this module as the imports can change
-- from version to version due to changes to the TH code in Persistent.
import           Database.Persist.Class (Unique)
import           Database.Persist.TH

-- In the schema definition we need to match Haskell types with with the
-- custom type defined in PostgreSQL (via 'DOMAIN' statements). For the
-- time being the Haskell types will be simple Haskell types like
-- 'ByteString' and 'Word64'.

-- We use camelCase here in the Haskell schema definition and 'persistLowerCase'
-- specifies that all the table and column names are converted to lower snake case.

share
  [ mkPersist sqlSettings
  , mkMigrate "migrateCardanoDb"
  ]
  [persistLowerCase|

  -- Schema versioning has three stages to best allow handling of schema migrations.
  --    Stage 1: Set up PostgreSQL data types (using SQL 'DOMAIN' statements).
  --    Stage 2: Persistent generated migrations.
  --    Stage 3: Set up 'VIEW' tables (for use by other languages and applications).
  -- This table should have a single row.
  SchemaVersion
    stageOne Int
    stageTwo Int
    stageThree Int
    deriving Eq

  PoolHash
    hashRaw             ByteString          sqltype=hash28type
    view                Text
    UniquePoolHash      hashRaw

  SlotLeader
    hash                ByteString          sqltype=hash28type
    poolHashId          PoolHashId Maybe    OnDeleteCascade   -- This will be non-null when a block is mined by a pool.
    description         Text                                  -- Description of the Slots leader.
    UniqueSlotLeader    hash

  -- Each table has autogenerated primary key named 'id', the Haskell type
  -- of which is (for instance for this table) 'BlockId'. This specific
  -- primary key Haskell type can be used in a type-safe way in the rest
  -- of the schema definition.
  -- All NULL-able fields other than 'epochNo' are NULL for EBBs, whereas 'epochNo' is
  -- only NULL for the genesis block.
  Block
    hash                ByteString          sqltype=hash32type
    epochNo             Word64 Maybe        sqltype=uinteger
    slotNo              Word64 Maybe        sqltype=uinteger
    epochSlotNo         Word64 Maybe        sqltype=uinteger
    blockNo             Word64 Maybe        sqltype=uinteger
    previousId          BlockId Maybe       OnDeleteCascade
    slotLeaderId        SlotLeaderId        OnDeleteCascade
    size                Word64              sqltype=uinteger
    time                UTCTime             sqltype=timestamp
    txCount             Word64
    protoMajor          Word16              sqltype=uinteger
    protoMinor          Word16              sqltype=uinteger
    -- Shelley specific
    vrfKey              Text Maybe
    opCert              ByteString Maybe    sqltype=hash32type
    UniqueBlock         hash

  Tx
    hash                ByteString          sqltype=hash32type
    blockId             BlockId             OnDeleteCascade     -- This type is the primary key for the 'block' table.
    blockIndex          Word64              sqltype=uinteger    -- The index of this transaction within the block.
    outSum              DbLovelace          sqltype=lovelace
    fee                 DbLovelace          sqltype=lovelace
    deposit             Int64                                   -- Needs to allow negaitve values.
    size                Word64              sqltype=uinteger

    invalidBefore       DbWord64 Maybe      sqltype=word64type
    invalidHereafter    DbWord64 Maybe      sqltype=word64type
    UniqueTx            hash
    deriving Show

  StakeAddress          -- Can be an address of a script hash
    hashRaw             ByteString          sqltype=addr29type
    view                Text
    registeredTxId      TxId                OnDeleteCascade     -- Only used for rollback.
    UniqueStakeAddress  hashRaw

  TxOut
    txId                TxId                OnDeleteCascade     -- This type is the primary key for the 'tx' table.
    index               Word16              sqltype=txindex
    address             Text
    addressRaw          ByteString
    paymentCred         ByteString Maybe    sqltype=hash28type
    stakeAddressId      StakeAddressId Maybe OnDeleteCascade
    value               DbLovelace          sqltype=lovelace
    UniqueTxout         txId index          -- The (tx_id, index) pair must be unique.

  TxIn
    txInId              TxId                OnDeleteCascade     -- The transaction where this is used as an input.
    txOutId             TxId                OnDeleteCascade     -- The transaction where this was created as an output.
    txOutIndex          Word16              sqltype=txindex
    UniqueTxin          txOutId txOutIndex

  -- A table containing metadata about the chain. There will probably only ever be one
  -- row in this table.
  Meta
    startTime           UTCTime             sqltype=timestamp
    networkName         Text
    UniqueMeta          startTime


  -- The following are tables used my specific 'plugins' to the regular cardano-db-sync node
  -- functionality. In the regular cardano-db-sync node these tables will be empty.

  -- The Epoch table is an aggregation of data in the 'Block' table, but is kept in this form
  -- because having it as a 'VIEW' is incredibly slow and inefficient.

  -- The 'outsum' type in the PostgreSQL world is 'bigint >= 0' so it will error out if an
  -- overflow (sum of tx outputs in an epoch) is detected. 'maxBound :: Int` is big enough to
  -- hold 204 times the total Lovelace distribution. The chance of that much being transacted
  -- in a single epoch is relatively low.
  Epoch
    outSum              Word128             sqltype=word128type
    fees                DbLovelace          sqltype=lovelace
    txCount             Word64              sqltype=uinteger
    blkCount            Word64              sqltype=uinteger
    no                  Word64              sqltype=uinteger
    startTime           UTCTime             sqltype=timestamp
    endTime             UTCTime             sqltype=timestamp
    UniqueEpoch         no
    deriving Eq
    deriving Show

  -- A table with all the different types of total balances.
  -- This is only populated for the Shelley and later eras, and only on epoch boundaries.
  -- The treasury and rewards fields will be correct for the whole epoch, but all other
  -- fields change block by block.
  AdaPots
    slotNo              Word64              sqltype=uinteger
    epochNo             Word64              sqltype=uinteger
    treasury            DbLovelace          sqltype=lovelace
    reserves            DbLovelace          sqltype=lovelace
    rewards             DbLovelace          sqltype=lovelace
    utxo                DbLovelace          sqltype=lovelace
    deposits            DbLovelace          sqltype=lovelace
    fees                DbLovelace          sqltype=lovelace
    blockId             BlockId             OnDeleteCascade
    UniqueAdaPots       blockId
    deriving Eq
    deriving Show

  -- -----------------------------------------------------------------------------------------------
  -- A Pool can have more than one owner, so we have a PoolOwner table that references this one.

  PoolMetadataRef
    poolId              PoolHashId
    url                 Text
    hash                ByteString          sqltype=hash32type
    registeredTxId      TxId                OnDeleteCascade     -- Only used for rollback.
    UniquePoolMetadataRef poolId hash

  PoolUpdate
    hashId              PoolHashId          OnDeleteCascade
    certIndex           Word16
    vrfKeyHash          ByteString          sqltype=hash32type
    pledge              DbLovelace          sqltype=lovelace
    rewardAddr          ByteString          sqltype=addr29type
    activeEpochNo       Word64
    metaId              PoolMetadataRefId Maybe OnDeleteCascade
    margin              Double                                  -- sqltype=percentage????
    fixedCost           DbLovelace          sqltype=lovelace
    registeredTxId      TxId                OnDeleteCascade     -- Slot number in which the pool was registered.
    UniquePoolUpdate    hashId registeredTxId

  PoolOwner
    addrId              StakeAddressId      OnDeleteCascade
    poolHashId          PoolHashId          OnDeleteCascade
    registeredTxId      TxId                OnDeleteCascade     -- Slot number in which the owner was registered.
    UniquePoolOwner     addrId poolHashId registeredTxId

  PoolRetire
    hashId              PoolHashId          OnDeleteCascade
    certIndex           Word16
    announcedTxId       TxId                OnDeleteCascade     -- Slot number in which the pool announced it was retiring.
    retiringEpoch       Word64              sqltype=uinteger    -- Epoch number in which the pool will retire.
    UniquePoolRetiring  hashId announcedTxId

  PoolRelay
    updateId            PoolUpdateId        OnDeleteCascade
    ipv4                Text Maybe
    ipv6                Text Maybe
    dnsName             Text Maybe
    dnsSrvName          Text Maybe
    port                Word16 Maybe
    -- Usually NULLables are not allowed in a uniqueness constraint. The semantics of how NULL
    -- interacts with those constraints is non-trivial:  two NULL values are not considered equal
    -- for the purposes of an uniqueness constraint.
    -- Use of "!force" attribute on the end of the line disables this check.
    UniquePoolRelay     updateId ipv4 ipv6 dnsName !force

  -- -----------------------------------------------------------------------------------------------

  Reserve
    addrId              StakeAddressId      OnDeleteCascade
    certIndex           Word16
    amount              DbInt65             sqltype=int65type
    txId                TxId                OnDeleteCascade
    UniqueReserves      addrId txId

  Withdrawal
    addrId              StakeAddressId      OnDeleteCascade
    amount              DbLovelace          sqltype=lovelace
    txId                TxId                OnDeleteCascade
    UniqueWithdrawal    addrId txId

  Delegation
    addrId              StakeAddressId      OnDeleteCascade
    certIndex           Word16
    poolHashId          PoolHashId          OnDeleteCascade
    activeEpochNo       Word64
    txId                TxId                OnDeleteCascade
    slotNo              Word64              sqltype=uinteger
    UniqueDelegation    addrId poolHashId txId

  -- When was a staking key/script registered
  StakeRegistration
    addrId              StakeAddressId      OnDeleteCascade
    certIndex           Word16
    txId                TxId                OnDeleteCascade
    UniqueStakeRegistration addrId txId

  -- When was a staking key/script deregistered
  StakeDeregistration
    addrId              StakeAddressId      OnDeleteCascade
    certIndex           Word16
    txId                TxId                OnDeleteCascade
    UniqueStakeDeregistration addrId txId

  TxMetadata
    key                 DbWord64            sqltype=word64type
    json                Text Maybe          sqltype=jsonb
    bytes               ByteString          sqltype=bytea
    txId                TxId                OnDeleteCascade
    UniqueTxMetadata    key txId

  -- -----------------------------------------------------------------------------------------------
  -- Reward, Stake and Treasury need to be obtained from the ledger state.

  -- The reward for each stake address and. This is not a balance, but a reward amount and the
  -- epoch in which the reward was earned.
  -- This table should never get rolled back.
  Reward
    addrId              StakeAddressId      OnDeleteCascade
    type                Text                sqltype=rewardtype
    amount              DbLovelace          sqltype=lovelace
    epochNo             Word64
    poolId              PoolHashId          OnDeleteCascade
    UniqueReward        epochNo addrId poolId

  -- Orphaned rewards happen when a stake address earns rewards, but the stake address is
  -- deregistered before the rewards are distributed.
  -- This table should never get rolled back.
  OrphanedReward
    addrId              StakeAddressId      OnDeleteCascade
    type                Text                sqltype=rewardtype
    amount              DbLovelace          sqltype=lovelace
    epochNo             Word64
    poolId              PoolHashId          OnDeleteCascade
    UniqueOrphaned      epochNo addrId poolId

  -- This table should never get rolled back.
  EpochStake
    addrId              StakeAddressId      OnDeleteCascade
    poolId              PoolHashId          OnDeleteCascade
    amount              DbLovelace          sqltype=lovelace
    epochNo             Word64
    UniqueStake         epochNo addrId poolId

  Treasury
    addrId              StakeAddressId      OnDeleteCascade
    certIndex           Word16
    amount              DbInt65             sqltype=int65type
    txId                TxId                OnDeleteCascade
    UniqueTreasury      addrId txId

  PotTransfer
    certIndex           Word16
    treasury            DbInt65             sqltype=int65type
    reserves            DbInt65             sqltype=int65type
    txId                TxId                OnDeleteCascade
    UniquePotTransfer   txId certIndex

  -- -----------------------------------------------------------------------------------------------
  -- Multi Asset related tables.

  MaTxMint
    policy              ByteString          sqltype=hash28type
    name                ByteString          sqltype=asset32type
    quantity            DbInt65             sqltype=int65type
    txId                TxId                OnDeleteCascade
    UniqueMaTxMint      policy name txId

  MaTxOut
    policy              ByteString          sqltype=hash28type
    name                ByteString          sqltype=asset32type
    quantity            DbWord64            sqltype=word64type
    txOutId             TxOutId             OnDeleteCascade
    UniqueMaTxOut       policy name txOutId

  -- -----------------------------------------------------------------------------------------------
  -- Update parameter proposals.

  ParamProposal
    epochNo             Word64              sqltype=uinteger
    key                 ByteString          sqltype=hash28type
    minFeeA             Word64 Maybe        sqltype=uinteger
    minFeeB             Word64 Maybe        sqltype=uinteger
    maxBlockSize        Word64 Maybe        sqltype=uinteger
    maxTxSize           Word64 Maybe        sqltype=uinteger
    maxBhSize           Word64 Maybe        sqltype=uinteger
    keyDeposit          DbLovelace Maybe    sqltype=lovelace
    poolDeposit         DbLovelace Maybe    sqltype=lovelace
    maxEpoch            Word64 Maybe        sqltype=uinteger
    optimalPoolCount    Word64 Maybe        sqltype=uinteger
    influence           Double Maybe        -- sqltype=rational
    monetaryExpandRate  Double Maybe        -- sqltype=interval
    treasuryGrowthRate  Double Maybe        -- sqltype=interval
    decentralisation    Double Maybe        -- sqltype=interval
    entropy             ByteString Maybe    sqltype=hash32type
    protocolMajor       Word16 Maybe        sqltype=uinteger
    protocolMinor       Word16 Maybe        sqltype=uinteger
    minUtxoValue        DbLovelace Maybe    sqltype=lovelace
    minPoolCost         DbLovelace Maybe    sqltype=lovelace

    registeredTxId      TxId                OnDeleteCascade    -- Slot number in which update registered.
    UniqueParamProposal key registeredTxId

  EpochParam
    epochNo             Word64              sqltype=uinteger
    minFeeA             Word64              sqltype=uinteger
    minFeeB             Word64              sqltype=uinteger
    maxBlockSize        Word64              sqltype=uinteger
    maxTxSize           Word64              sqltype=uinteger
    maxBhSize           Word64              sqltype=uinteger
    keyDeposit          DbLovelace          sqltype=lovelace
    poolDeposit         DbLovelace          sqltype=lovelace
    maxEpoch            Word64              sqltype=uinteger
    optimalPoolCount    Word64              sqltype=uinteger
    influence           Double              -- sqltype=rational
    monetaryExpandRate  Double              -- sqltype=interval
    treasuryGrowthRate  Double              -- sqltype=interval
    decentralisation    Double              -- sqltype=interval
    entropy             ByteString Maybe    sqltype=hash32type
    protocolMajor       Word16              sqltype=uinteger
    protocolMinor       Word16              sqltype=uinteger
    minUtxoValue        DbLovelace          sqltype=lovelace
    minPoolCost         DbLovelace          sqltype=lovelace

    nonce               ByteString Maybe    sqltype=hash32type

    blockId             BlockId             OnDeleteCascade      -- The first block where these parameters are valid.
    UniqueEpochParam    epochNo blockId

  -- -----------------------------------------------------------------------------------------------
  -- Pool offline (ie not on the blockchain) data.

  PoolOfflineData
    poolId              PoolHashId          OnDeleteCascade
    tickerName          Text
    hash                ByteString          sqltype=hash32type
    metadata            Text
    pmrId               PoolMetadataRefId   OnDeleteCascade
    UniquePoolOfflineData  poolId hash
    deriving Show

  -- The pool metadata fetch error. We duplicate the poolId for easy access.
  -- TODO(KS): Debatable whether we need to persist this between migrations!

  PoolOfflineFetchError
    poolId              PoolHashId          OnDeleteCascade
    fetchTime           UTCTime             sqltype=timestamp
    pmrId               PoolMetadataRefId   OnDeleteCascade
    fetchError          Text
    retryCount          Word                sqltype=uinteger
    UniquePoolOfflineFetchError poolId fetchTime retryCount
    deriving Show

  EpochSyncTime
    no                  Word64
    seconds             Double Maybe
    state               Text                sqltype=syncstatetype
    UniqueEpochSyncTime no

  --------------------------------------------------------------------------
  -- Tables below must be preserved when migrations occur!
  --------------------------------------------------------------------------

  -- A table containing a managed list of reserved ticker names.
  -- For now they are grouped under the specific hash of the pool.
  ReservedPoolTicker
    name                Text
    poolId              PoolHashId
    UniqueReservedPoolTicker name
    deriving Show

  -- A table containin a list of administrator users that can be used to access the secure API endpoints.
  -- Yes, we don't have any hash check mechanisms here, if they get to the database, game over anyway.
  AdminUser
    username            Text
    password            Text
    UniqueAdminUser     username
    deriving Show

  |]

deriving instance Eq (Unique EpochSyncTime)
