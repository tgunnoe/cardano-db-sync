{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Cardano.DbSync.Era.Shelley.Insert (
  insertShelleyBlock,
  -- These are exported for data in Shelley Genesis
  insertPoolRegister,
  insertStakeRegistration,
  insertDelegation,
  insertStakeAddressRefIfMissing,
  mkAdaPots,
  prepareTxOut,
) where

import Cardano.BM.Trace (Trace, logDebug, logInfo, logWarning)
import Cardano.Crypto.Hash (hashToBytes)
import qualified Cardano.Crypto.Hashing as Crypto
import Cardano.Db (DbLovelace (..), DbWord64 (..), PoolUrl (..))
import qualified Cardano.Db as DB
import Cardano.DbSync.Api
import Cardano.DbSync.Api.Types (InsertOptions (..), SyncEnv (..), SyncOptions (..))
import Cardano.DbSync.Cache (
  insertBlockAndCache,
  insertDatumAndCache,
  insertPoolKeyWithCache,
  insertStakeAddress,
  queryDatum,
  queryMAWithCache,
  queryOrInsertRewardAccount,
  queryOrInsertStakeAddress,
  queryPoolKeyOrInsert,
  queryPoolKeyWithCache,
  queryPrevBlockWithCache,
 )
import Cardano.DbSync.Cache.Epoch (writeEpochBlockDiffToCache)
import Cardano.DbSync.Cache.Types (Cache (..), CacheNew (..), EpochBlockDiff (..))

import qualified Cardano.DbSync.Era.Shelley.Generic as Generic
import Cardano.DbSync.Era.Shelley.Generic.Metadata (
  TxMetadataValue (..),
  metadataValueToJsonNoSchema,
 )
import Cardano.DbSync.Era.Shelley.Generic.ParamProposal
import Cardano.DbSync.Era.Shelley.Insert.Epoch
import Cardano.DbSync.Era.Shelley.Insert.Grouped
import Cardano.DbSync.Era.Shelley.Query
import Cardano.DbSync.Era.Util (liftLookupFail, safeDecodeToJson)
import Cardano.DbSync.Error
import Cardano.DbSync.Ledger.Types (ApplyResult (..), getGovExpiresAt, lookupDepositsMap)
import Cardano.DbSync.OffChain
import Cardano.DbSync.Types
import Cardano.DbSync.Util
import Cardano.DbSync.Util.Bech32
import Cardano.DbSync.Util.Cbor (serialiseTxMetadataToCbor)
import qualified Cardano.Ledger.Address as Ledger
import qualified Cardano.Ledger.Alonzo.Scripts as Ledger
import Cardano.Ledger.BaseTypes
import qualified Cardano.Ledger.BaseTypes as Ledger
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Coin as Ledger
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Conway.Core (DRepVotingThresholds (..), PoolVotingThresholds (..))
import Cardano.Ledger.Conway.Governance
import Cardano.Ledger.Conway.TxCert
import qualified Cardano.Ledger.Credential as Ledger
import Cardano.Ledger.DRep
import Cardano.Ledger.Keys
import qualified Cardano.Ledger.Keys as Ledger
import Cardano.Ledger.Mary.Value (AssetName (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.Language (Language)
import qualified Cardano.Ledger.Shelley.API.Wallet as Shelley
import qualified Cardano.Ledger.Shelley.TxBody as Shelley
import Cardano.Ledger.Shelley.TxCert
import Cardano.Prelude
import Control.Monad.Extra (mapMaybeM, whenJust)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Except.Extra (newExceptT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Either.Extra (eitherToMaybe)
import Data.Group (invert)
import qualified Data.Map.Strict as Map
import qualified Data.Strict.Maybe as Strict
import qualified Data.Text.Encoding as Text
import Database.Persist.Sql (SqlBackend)
import Lens.Micro
import Ouroboros.Consensus.Cardano.Block (StandardConway, StandardCrypto)

{- HLINT ignore "Reduce duplication" -}

type IsPoolMember = PoolKeyHash -> Bool

insertShelleyBlock ::
  (MonadBaseControl IO m, MonadIO m) =>
  SyncEnv ->
  Bool ->
  Bool ->
  Bool ->
  Generic.Block ->
  SlotDetails ->
  IsPoolMember ->
  ApplyResult ->
  ReaderT SqlBackend m (Either SyncNodeError ())
insertShelleyBlock syncEnv shouldLog withinTwoMins withinHalfHour blk details isMember applyResult = do
  runExceptT $ do
    pbid <- case Generic.blkPreviousHash blk of
      Nothing -> liftLookupFail (renderErrorMessage (Generic.blkEra blk)) DB.queryGenesis -- this is for networks that fork from Byron on epoch 0.
      Just pHash -> queryPrevBlockWithCache (renderErrorMessage (Generic.blkEra blk)) cache pHash
    mPhid <- lift $ queryPoolKeyWithCache cache CacheNew $ coerceKeyRole $ Generic.blkSlotLeader blk
    let epochNo = sdEpochNo details

    slid <- lift . DB.insertSlotLeader $ Generic.mkSlotLeader (ioShelley iopts) (Generic.unKeyHashRaw $ Generic.blkSlotLeader blk) (eitherToMaybe mPhid)
    blkId <-
      lift . insertBlockAndCache cache $
        DB.Block
          { DB.blockHash = Generic.blkHash blk
          , DB.blockEpochNo = Just $ unEpochNo epochNo
          , DB.blockSlotNo = Just $ unSlotNo (Generic.blkSlotNo blk)
          , DB.blockEpochSlotNo = Just $ unEpochSlot (sdEpochSlot details)
          , DB.blockBlockNo = Just $ unBlockNo (Generic.blkBlockNo blk)
          , DB.blockPreviousId = Just pbid
          , DB.blockSlotLeaderId = slid
          , DB.blockSize = Generic.blkSize blk
          , DB.blockTime = sdSlotTime details
          , DB.blockTxCount = fromIntegral $ length (Generic.blkTxs blk)
          , DB.blockProtoMajor = getVersion $ Ledger.pvMajor (Generic.blkProto blk)
          , DB.blockProtoMinor = fromIntegral $ Ledger.pvMinor (Generic.blkProto blk)
          , -- Shelley specific
            DB.blockVrfKey = Just $ Generic.blkVrfKey blk
          , DB.blockOpCert = Just $ Generic.blkOpCert blk
          , DB.blockOpCertCounter = Just $ Generic.blkOpCertCounter blk
          }

    let zippedTx = zip [0 ..] (Generic.blkTxs blk)
    let txInserter = insertTx syncEnv isMember blkId (sdEpochNo details) (Generic.blkSlotNo blk) applyResult
    blockGroupedData <- foldM (\gp (idx, tx) -> txInserter idx tx gp) mempty zippedTx
    minIds <- insertBlockGroupedData syncEnv blockGroupedData

    -- now that we've inserted the Block and all it's txs lets cache what we'll need
    -- when we later update the epoch values.
    -- if have --dissable-epoch && --dissable-cache then no need to cache data.
    when (soptEpochAndCacheEnabled $ envOptions syncEnv)
      . newExceptT
      $ writeEpochBlockDiffToCache
        cache
        EpochBlockDiff
          { ebdBlockId = blkId
          , ebdTime = sdSlotTime details
          , ebdFees = groupedTxFees blockGroupedData
          , ebdEpochNo = unEpochNo (sdEpochNo details)
          , ebdOutSum = fromIntegral $ groupedTxOutSum blockGroupedData
          , ebdTxCount = fromIntegral $ length (Generic.blkTxs blk)
          }

    when withinHalfHour $
      insertReverseIndex blkId minIds

    liftIO $ do
      let epoch = unEpochNo epochNo
          slotWithinEpoch = unEpochSlot (sdEpochSlot details)

      when (withinTwoMins && slotWithinEpoch /= 0 && unBlockNo (Generic.blkBlockNo blk) `mod` 20 == 0) $ do
        logInfo tracer $
          mconcat
            [ renderInsertName (Generic.blkEra blk)
            , ": continuing epoch "
            , textShow epoch
            , " (slot "
            , textShow slotWithinEpoch
            , "/"
            , textShow (unEpochSize $ sdEpochSize details)
            , ")"
            ]
      logger tracer $
        mconcat
          [ renderInsertName (Generic.blkEra blk)
          , ": epoch "
          , textShow (unEpochNo epochNo)
          , ", slot "
          , textShow (unSlotNo $ Generic.blkSlotNo blk)
          , ", block "
          , textShow (unBlockNo $ Generic.blkBlockNo blk)
          , ", hash "
          , renderByteArray (Generic.blkHash blk)
          ]

    whenStrictJust (apNewEpoch applyResult) $ \newEpoch -> do
      insertOnNewEpoch tracer iopts blkId (Generic.blkSlotNo blk) epochNo newEpoch

    insertStakeSlice syncEnv $ apStakeSlice applyResult

    when (ioGov iopts)
      . lift
      $ insertOffChainVoteResults tracer (envOffChainVoteResultQueue syncEnv)

    when (ioOffChainPoolData iopts)
      . lift
      $ insertOffChainPoolResults tracer (envOffChainPoolResultQueue syncEnv)
  where
    iopts = getInsertOptions syncEnv

    logger :: Trace IO a -> a -> IO ()
    logger
      | shouldLog = logInfo
      | withinTwoMins = logInfo
      | unBlockNo (Generic.blkBlockNo blk) `mod` 5000 == 0 = logInfo
      | otherwise = logDebug

    renderInsertName :: Generic.BlockEra -> Text
    renderInsertName eraText =
      mconcat ["Insert ", textShow eraText, " Block"]

    renderErrorMessage :: Generic.BlockEra -> Text
    renderErrorMessage eraText =
      case eraText of
        Generic.Shelley -> "insertShelleyBlock"
        other -> mconcat ["insertShelleyBlock(", textShow other, ")"]

    tracer :: Trace IO Text
    tracer = getTrace syncEnv

    cache :: Cache
    cache = envCache syncEnv

-- -----------------------------------------------------------------------------

insertOnNewEpoch ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  InsertOptions ->
  DB.BlockId ->
  SlotNo ->
  EpochNo ->
  Generic.NewEpoch ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertOnNewEpoch tracer iopts blkId slotNo epochNo newEpoch = do
  whenStrictJust (Generic.euProtoParams epochUpdate) $ \params ->
    lift $ insertEpochParam tracer blkId epochNo params (Generic.euNonce epochUpdate)
  whenStrictJust (Generic.neAdaPots newEpoch) $ \pots ->
    insertPots blkId slotNo epochNo pots
  whenStrictJust (Generic.neDRepState newEpoch) $ \dreps -> when (ioGov iopts) $ do
    let (drepSnapshot, ratifyState) = finishDRepPulser dreps
    lift $ insertDrepDistr epochNo drepSnapshot
    updateEnacted False epochNo (rsEnactState ratifyState)
  whenStrictJust (Generic.neEnacted newEpoch) $ \enactedSt ->
    when (ioGov iopts) $
      updateEnacted True epochNo enactedSt
  where
    epochUpdate :: Generic.EpochUpdate
    epochUpdate = Generic.neEpochUpdate newEpoch

-- -----------------------------------------------------------------------------

insertTx ::
  (MonadBaseControl IO m, MonadIO m) =>
  SyncEnv ->
  IsPoolMember ->
  DB.BlockId ->
  EpochNo ->
  SlotNo ->
  ApplyResult ->
  Word64 ->
  Generic.Tx ->
  BlockGroupedData ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) BlockGroupedData
insertTx syncEnv isMember blkId epochNo slotNo applyResult blockIndex tx grouped = do
  let !txHash = Generic.txHash tx
  let !mdeposits = if not (Generic.txValidContract tx) then Just (Coin 0) else lookupDepositsMap txHash (apDepositsMap applyResult)
  let !outSum = fromIntegral $ unCoin $ Generic.txOutSum tx
      !withdrawalSum = fromIntegral $ unCoin $ Generic.txWithdrawalSum tx
      hasConsumed = getHasConsumedOrPruneTxOut syncEnv
  disInOut <- liftIO $ getDisableInOutState syncEnv
  -- In some txs and with specific configuration we may be able to find necessary data within the tx body.
  -- In these cases we can avoid expensive queries.
  (resolvedInputs, fees', deposits) <- case (disInOut, mdeposits, unCoin <$> Generic.txFees tx) of
    (True, _, _) -> pure ([], 0, unCoin <$> mdeposits)
    (_, Just deposits, Just fees) -> do
      (resolvedInputs, _) <- splitLast <$> mapM (resolveTxInputs hasConsumed False (fst <$> groupedTxOut grouped)) (Generic.txInputs tx)
      pure (resolvedInputs, fees, Just (unCoin deposits))
    (_, Nothing, Just fees) -> do
      (resolvedInputs, amounts) <- splitLast <$> mapM (resolveTxInputs hasConsumed False (fst <$> groupedTxOut grouped)) (Generic.txInputs tx)
      if any isNothing amounts
        then pure (resolvedInputs, fees, Nothing)
        else
          let !inSum = sum $ map unDbLovelace $ catMaybes amounts
           in pure (resolvedInputs, fees, Just $ fromIntegral (inSum + withdrawalSum) - fromIntegral outSum - fromIntegral fees)
    (_, _, Nothing) -> do
      -- Nothing in fees means a phase 2 failure
      (resolvedInsFull, amounts) <- splitLast <$> mapM (resolveTxInputs hasConsumed True (fst <$> groupedTxOut grouped)) (Generic.txInputs tx)
      let !inSum = sum $ map unDbLovelace $ catMaybes amounts
          !diffSum = if inSum >= outSum then inSum - outSum else 0
          !fees = maybe diffSum (fromIntegral . unCoin) (Generic.txFees tx)
      pure (resolvedInsFull, fromIntegral fees, Just 0)
  let fees = fromIntegral fees'
  -- Insert transaction and get txId from the DB.
  !txId <-
    lift
      . DB.insertTx
      $ DB.Tx
        { DB.txHash = txHash
        , DB.txBlockId = blkId
        , DB.txBlockIndex = blockIndex
        , DB.txOutSum = DB.DbLovelace outSum
        , DB.txFee = DB.DbLovelace fees
        , DB.txDeposit = fromIntegral <$> deposits
        , DB.txSize = Generic.txSize tx
        , DB.txInvalidBefore = DbWord64 . unSlotNo <$> Generic.txInvalidBefore tx
        , DB.txInvalidHereafter = DbWord64 . unSlotNo <$> Generic.txInvalidHereafter tx
        , DB.txValidContract = Generic.txValidContract tx
        , DB.txScriptSize = sum $ Generic.txScriptSizes tx
        }

  if not (Generic.txValidContract tx)
    then do
      !txOutsGrouped <- mapM (prepareTxOut tracer cache iopts (txId, txHash)) (Generic.txOutputs tx)

      let !txIns = map (prepareTxIn txId Map.empty) resolvedInputs
      -- There is a custom semigroup instance for BlockGroupedData which uses addition for the values `fees` and `outSum`.
      -- Same happens bellow on last line of this function.
      pure (grouped <> BlockGroupedData txIns txOutsGrouped [] [] fees outSum)
    else do
      -- The following operations only happen if the script passes stage 2 validation (or the tx has
      -- no script).
      !txOutsGrouped <- mapM (prepareTxOut tracer cache iopts (txId, txHash)) (Generic.txOutputs tx)

      !redeemers <-
        Map.fromList
          <$> whenFalseMempty
            (ioPlutusExtra iopts)
            (mapM (insertRedeemer tracer disInOut (fst <$> groupedTxOut grouped) txId) (Generic.txRedeemer tx))

      when (ioPlutusExtra iopts) $ do
        mapM_ (insertDatum tracer cache txId) (Generic.txData tx)

        mapM_ (insertCollateralTxIn tracer txId) (Generic.txCollateralInputs tx)

        mapM_ (insertReferenceTxIn tracer txId) (Generic.txReferenceInputs tx)

        mapM_ (insertCollateralTxOut tracer cache iopts (txId, txHash)) (Generic.txCollateralOutputs tx)

      txMetadata <-
        whenFalseMempty (ioMetadata iopts) $
          prepareTxMetadata
            tracer
            txId
            iopts
            (Generic.txMetadata tx)
      mapM_
        (insertCertificate syncEnv isMember blkId txId epochNo slotNo redeemers)
        $ Generic.txCertificates tx
      when (ioShelley iopts) $
        mapM_ (insertWithdrawals tracer cache txId redeemers) $
          Generic.txWithdrawals tx
      when (ioShelley iopts) $
        mapM_ (lift . insertParamProposal blkId txId) $
          Generic.txParamProposal tx

      maTxMint <-
        whenFalseMempty (ioMetadata iopts) $
          prepareMaTxMint tracer cache txId $
            Generic.txMint tx

      when (ioPlutusExtra iopts) $
        mapM_ (lift . insertScript tracer txId) $
          Generic.txScripts tx

      when (ioPlutusExtra iopts) $
        mapM_ (insertExtraKeyWitness tracer txId) $
          Generic.txExtraKeyWitnesses tx

      when (ioGov iopts) $ do
        mapM_ (insertGovActionProposal cache blkId txId (getGovExpiresAt applyResult epochNo)) $ zip [0 ..] (Generic.txProposalProcedure tx)
        mapM_ (insertVotingProcedures tracer cache txId) (Generic.txVotingProcedure tx)

      let !txIns = map (prepareTxIn txId redeemers) resolvedInputs
      pure (grouped <> BlockGroupedData txIns txOutsGrouped txMetadata maTxMint fees outSum)
  where
    tracer = getTrace syncEnv
    cache = envCache syncEnv
    iopts = getInsertOptions syncEnv

prepareTxOut ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  InsertOptions ->
  (DB.TxId, ByteString) ->
  Generic.TxOut ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) (ExtendedTxOut, [MissingMaTxOut])
prepareTxOut tracer cache iopts (txId, txHash) (Generic.TxOut index addr addrRaw value maMap mScript dt) = do
  mSaId <- lift $ insertStakeAddressRefIfMissing tracer cache addr
  mDatumId <-
    whenFalseEmpty (ioPlutusExtra iopts) Nothing $
      Generic.whenInlineDatum dt $
        insertDatum tracer cache txId
  mScriptId <-
    whenFalseEmpty (ioPlutusExtra iopts) Nothing $
      whenMaybe mScript $
        lift . insertScript tracer txId
  let !txOut =
        DB.TxOut
          { DB.txOutTxId = txId
          , DB.txOutIndex = index
          , DB.txOutAddress = Generic.renderAddress addr
          , DB.txOutAddressRaw = addrRaw
          , DB.txOutAddressHasScript = hasScript
          , DB.txOutPaymentCred = Generic.maybePaymentCred addr
          , DB.txOutStakeAddressId = mSaId
          , DB.txOutValue = Generic.coinToDbLovelace value
          , DB.txOutDataHash = Generic.dataHashToBytes <$> Generic.getTxOutDatumHash dt
          , DB.txOutInlineDatumId = mDatumId
          , DB.txOutReferenceScriptId = mScriptId
          }
  let !eutxo = ExtendedTxOut txHash txOut
  !maTxOuts <- whenFalseMempty (ioMultiAssets iopts) $ prepareMaTxOuts tracer cache maMap
  pure (eutxo, maTxOuts)
  where
    hasScript :: Bool
    hasScript = maybe False Generic.hasCredScript (Generic.getPaymentCred addr)

insertCollateralTxOut ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  InsertOptions ->
  (DB.TxId, ByteString) ->
  Generic.TxOut ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertCollateralTxOut tracer cache iopts (txId, _txHash) (Generic.TxOut index addr addrRaw value maMap mScript dt) = do
  mSaId <- lift $ insertStakeAddressRefIfMissing tracer cache addr
  mDatumId <-
    whenFalseEmpty (ioPlutusExtra iopts) Nothing $
      Generic.whenInlineDatum dt $
        insertDatum tracer cache txId
  mScriptId <-
    whenFalseEmpty (ioPlutusExtra iopts) Nothing $
      whenMaybe mScript $
        lift . insertScript tracer txId
  _ <-
    lift
      . DB.insertCollateralTxOut
      $ DB.CollateralTxOut
        { DB.collateralTxOutTxId = txId
        , DB.collateralTxOutIndex = index
        , DB.collateralTxOutAddress = Generic.renderAddress addr
        , DB.collateralTxOutAddressRaw = addrRaw
        , DB.collateralTxOutAddressHasScript = hasScript
        , DB.collateralTxOutPaymentCred = Generic.maybePaymentCred addr
        , DB.collateralTxOutStakeAddressId = mSaId
        , DB.collateralTxOutValue = Generic.coinToDbLovelace value
        , DB.collateralTxOutDataHash = Generic.dataHashToBytes <$> Generic.getTxOutDatumHash dt
        , DB.collateralTxOutMultiAssetsDescr = textShow maMap
        , DB.collateralTxOutInlineDatumId = mDatumId
        , DB.collateralTxOutReferenceScriptId = mScriptId
        }
  pure ()
  where
    -- TODO: Is there any reason to add new tables for collateral multi-assets/multi-asset-outputs

    hasScript :: Bool
    hasScript = maybe False Generic.hasCredScript (Generic.getPaymentCred addr)

prepareTxIn ::
  DB.TxId ->
  Map Word64 DB.RedeemerId ->
  (Generic.TxIn, DB.TxId, Either Generic.TxIn DB.TxOutId) ->
  ExtendedTxIn
prepareTxIn txInId redeemers (txIn, txOutId, mTxOutId) =
  ExtendedTxIn
    { etiTxIn = txInDB
    , etiTxOutId = mTxOutId
    }
  where
    txInDB =
      DB.TxIn
        { DB.txInTxInId = txInId
        , DB.txInTxOutId = txOutId
        , DB.txInTxOutIndex = fromIntegral $ Generic.txInIndex txIn
        , DB.txInRedeemerId = mlookup (Generic.txInRedeemerIndex txIn) redeemers
        }

insertCollateralTxIn ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  Generic.TxIn ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertCollateralTxIn _tracer txInId (Generic.TxIn txId index _) = do
  txOutId <- liftLookupFail "insertCollateralTxIn" $ DB.queryTxId txId
  void
    . lift
    . DB.insertCollateralTxIn
    $ DB.CollateralTxIn
      { DB.collateralTxInTxInId = txInId
      , DB.collateralTxInTxOutId = txOutId
      , DB.collateralTxInTxOutIndex = fromIntegral index
      }

insertReferenceTxIn ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  Generic.TxIn ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertReferenceTxIn _tracer txInId (Generic.TxIn txId index _) = do
  txOutId <- liftLookupFail "insertReferenceTxIn" $ DB.queryTxId txId
  void
    . lift
    . DB.insertReferenceTxIn
    $ DB.ReferenceTxIn
      { DB.referenceTxInTxInId = txInId
      , DB.referenceTxInTxOutId = txOutId
      , DB.referenceTxInTxOutIndex = fromIntegral index
      }

insertCertificate ::
  (MonadBaseControl IO m, MonadIO m) =>
  SyncEnv ->
  IsPoolMember ->
  DB.BlockId ->
  DB.TxId ->
  EpochNo ->
  SlotNo ->
  Map Word64 DB.RedeemerId ->
  Generic.TxCertificate ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertCertificate syncEnv isMember blkId txId epochNo slotNo redeemers (Generic.TxCertificate ridx idx cert) =
  case cert of
    Left (ShelleyTxCertDelegCert deleg) ->
      when (ioShelley iopts) $ insertDelegCert tracer cache network txId idx mRedeemerId epochNo slotNo deleg
    Left (ShelleyTxCertPool pool) ->
      when (ioShelley iopts) $ insertPoolCert tracer cache isMember network epochNo blkId txId idx pool
    Left (ShelleyTxCertMir mir) ->
      when (ioShelley iopts) $ insertMirCert tracer cache network txId idx mir
    Left (ShelleyTxCertGenesisDeleg _gen) ->
      when (ioShelley iopts) $
        liftIO $
          logWarning tracer "insertCertificate: Unhandled DCertGenesis certificate"
    Right (ConwayTxCertDeleg deleg) ->
      when (ioShelley iopts) $ insertConwayDelegCert syncEnv txId idx mRedeemerId epochNo slotNo deleg
    Right (ConwayTxCertPool pool) ->
      when (ioShelley iopts) $ insertPoolCert tracer cache isMember network epochNo blkId txId idx pool
    Right (ConwayTxCertGov c) ->
      when (ioGov iopts) $ case c of
        ConwayRegDRep cred coin anchor ->
          lift $ insertDrepRegistration txId idx cred (Just coin) (strictMaybeToMaybe anchor)
        ConwayUnRegDRep cred coin ->
          lift $ insertDrepDeRegistration txId idx cred coin
        ConwayAuthCommitteeHotKey khCold khHot ->
          lift $ insertCommitteeRegistration txId idx khCold khHot
        ConwayResignCommitteeColdKey khCold anchor ->
          lift $ insertCommitteeDeRegistration txId idx khCold (strictMaybeToMaybe anchor)
        ConwayUpdateDRep cred anchor ->
          lift $ insertDrepRegistration txId idx cred Nothing (strictMaybeToMaybe anchor)
  where
    tracer = getTrace syncEnv
    cache = envCache syncEnv
    iopts = getInsertOptions syncEnv
    network = getNetwork syncEnv
    mRedeemerId = mlookup ridx redeemers

insertCommitteeRegistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.TxId ->
  Word16 ->
  Ledger.Credential 'ColdCommitteeRole StandardCrypto ->
  Ledger.Credential 'HotCommitteeRole StandardCrypto ->
  ReaderT SqlBackend m ()
insertCommitteeRegistration txId idx khCold khHot = do
  void
    . DB.insertCommitteeRegistration
    $ DB.CommitteeRegistration
      { DB.committeeRegistrationTxId = txId
      , DB.committeeRegistrationCertIndex = idx
      , DB.committeeRegistrationColdKey = Generic.unCredentialHash khCold
      , DB.committeeRegistrationHotKey = Generic.unCredentialHash khHot
      }

insertCommitteeDeRegistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.TxId ->
  Word16 ->
  Ledger.Credential 'ColdCommitteeRole StandardCrypto ->
  Maybe (Anchor StandardCrypto) ->
  ReaderT SqlBackend m ()
insertCommitteeDeRegistration txId idx khCold mAnchor = do
  votingAnchorId <- whenMaybe mAnchor $ insertAnchor txId
  void
    . DB.insertCommitteeDeRegistration
    $ DB.CommitteeDeRegistration
      { DB.committeeDeRegistrationTxId = txId
      , DB.committeeDeRegistrationCertIndex = idx
      , DB.committeeDeRegistrationColdKey = Generic.unCredentialHash khCold
      , DB.committeeDeRegistrationVotingAnchorId = votingAnchorId
      }

insertDrepRegistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.TxId ->
  Word16 ->
  Ledger.Credential 'DRepRole StandardCrypto ->
  Maybe Coin ->
  Maybe (Anchor StandardCrypto) ->
  ReaderT SqlBackend m ()
insertDrepRegistration txId idx cred mcoin mAnchor = do
  drepId <- insertCredDrepHash cred
  votingAnchorId <- whenMaybe mAnchor $ insertAnchor txId
  void
    . DB.insertDrepRegistration
    $ DB.DrepRegistration
      { DB.drepRegistrationTxId = txId
      , DB.drepRegistrationCertIndex = idx
      , DB.drepRegistrationDeposit = fromIntegral . unCoin <$> mcoin
      , DB.drepRegistrationVotingAnchorId = votingAnchorId
      , DB.drepRegistrationDrepHashId = drepId
      }

insertDrepDeRegistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.TxId ->
  Word16 ->
  Ledger.Credential 'DRepRole StandardCrypto ->
  Coin ->
  ReaderT SqlBackend m ()
insertDrepDeRegistration txId idx cred coin = do
  drepId <- insertCredDrepHash cred
  void
    . DB.insertDrepRegistration
    $ DB.DrepRegistration
      { DB.drepRegistrationTxId = txId
      , DB.drepRegistrationCertIndex = idx
      , DB.drepRegistrationDeposit = Just (-(fromIntegral $ unCoin coin))
      , DB.drepRegistrationVotingAnchorId = Nothing
      , DB.drepRegistrationDrepHashId = drepId
      }

insertPoolCert ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  IsPoolMember ->
  Ledger.Network ->
  EpochNo ->
  DB.BlockId ->
  DB.TxId ->
  Word16 ->
  Shelley.PoolCert StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert tracer cache isMember network epoch blkId txId idx pCert =
  case pCert of
    Shelley.RegPool pParams -> insertPoolRegister tracer cache isMember network epoch blkId txId idx pParams
    Shelley.RetirePool keyHash epochNum -> insertPoolRetire tracer txId cache epochNum idx keyHash

insertDelegCert ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  Ledger.Network ->
  DB.TxId ->
  Word16 ->
  Maybe DB.RedeemerId ->
  EpochNo ->
  SlotNo ->
  ShelleyDelegCert StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertDelegCert tracer cache network txId idx mRedeemerId epochNo slotNo dCert =
  case dCert of
    ShelleyRegCert cred -> insertStakeRegistration epochNo txId idx $ Generic.annotateStakingCred network cred
    ShelleyUnRegCert cred -> insertStakeDeregistration cache network epochNo txId idx mRedeemerId cred
    ShelleyDelegCert cred poolkh -> insertDelegation tracer cache network epochNo slotNo txId idx mRedeemerId cred poolkh

insertConwayDelegCert ::
  (MonadBaseControl IO m, MonadIO m) =>
  SyncEnv ->
  DB.TxId ->
  Word16 ->
  Maybe DB.RedeemerId ->
  EpochNo ->
  SlotNo ->
  ConwayDelegCert StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertConwayDelegCert syncEnv txId idx mRedeemerId epochNo slotNo dCert =
  case dCert of
    ConwayRegCert cred _dep -> insertStakeRegistration epochNo txId idx $ Generic.annotateStakingCred network cred
    ConwayUnRegCert cred _dep -> insertStakeDeregistration cache network epochNo txId idx mRedeemerId cred
    ConwayDelegCert cred delegatee -> insertDeleg cred delegatee
    ConwayRegDelegCert cred delegatee _dep -> do
      insertStakeRegistration epochNo txId idx $ Generic.annotateStakingCred network cred
      insertDeleg cred delegatee
  where
    insertDeleg cred = \case
      DelegStake poolkh -> insertDelegation trce cache network epochNo slotNo txId idx mRedeemerId cred poolkh
      DelegVote drep ->
        when (ioGov iopts) $
          insertDelegationVote cache network txId idx cred drep
      DelegStakeVote poolkh drep -> do
        insertDelegation trce cache network epochNo slotNo txId idx mRedeemerId cred poolkh
        when (ioGov iopts) $
          insertDelegationVote cache network txId idx cred drep

    trce = getTrace syncEnv
    cache = envCache syncEnv
    iopts = getInsertOptions syncEnv
    network = getNetwork syncEnv

insertPoolRegister ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  IsPoolMember ->
  Ledger.Network ->
  EpochNo ->
  DB.BlockId ->
  DB.TxId ->
  Word16 ->
  Shelley.PoolParams StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertPoolRegister _tracer cache isMember network (EpochNo epoch) blkId txId idx params = do
  poolHashId <- lift $ insertPoolKeyWithCache cache CacheNew (Shelley.ppId params)
  mdId <- case strictMaybeToMaybe $ Shelley.ppMetadata params of
    Just md -> Just <$> insertMetaDataRef poolHashId txId md
    Nothing -> pure Nothing

  epochActivationDelay <- mkEpochActivationDelay poolHashId

  saId <- lift $ queryOrInsertRewardAccount cache CacheNew (adjustNetworkTag $ Shelley.ppRewardAcnt params)
  poolUpdateId <-
    lift
      . DB.insertPoolUpdate
      $ DB.PoolUpdate
        { DB.poolUpdateHashId = poolHashId
        , DB.poolUpdateCertIndex = idx
        , DB.poolUpdateVrfKeyHash = hashToBytes (Shelley.ppVrf params)
        , DB.poolUpdatePledge = Generic.coinToDbLovelace (Shelley.ppPledge params)
        , DB.poolUpdateRewardAddrId = saId
        , DB.poolUpdateActiveEpochNo = epoch + epochActivationDelay
        , DB.poolUpdateMetaId = mdId
        , DB.poolUpdateMargin = realToFrac $ Ledger.unboundRational (Shelley.ppMargin params)
        , DB.poolUpdateFixedCost = Generic.coinToDbLovelace (Shelley.ppCost params)
        , DB.poolUpdateRegisteredTxId = txId
        }

  mapM_ (insertPoolOwner cache network poolUpdateId) $ toList (Shelley.ppOwners params)
  mapM_ (insertPoolRelay poolUpdateId) $ toList (Shelley.ppRelays params)
  where
    mkEpochActivationDelay :: MonadIO m => DB.PoolHashId -> ExceptT SyncNodeError (ReaderT SqlBackend m) Word64
    mkEpochActivationDelay poolHashId =
      if isMember (Shelley.ppId params)
        then pure 3
        else do
          -- if the pool is not registered at the end of the previous block, check for
          -- other registrations at the current block. If this is the first registration
          -- then it's +2, else it's +3.
          otherUpdates <- lift $ queryPoolUpdateByBlock blkId poolHashId
          pure $ if otherUpdates then 3 else 2

    -- Ignore the network in the `RewardAcnt` and use the provided one instead.
    -- This is a workaround for https://github.com/IntersectMBO/cardano-db-sync/issues/546
    adjustNetworkTag :: Ledger.RewardAcnt StandardCrypto -> Ledger.RewardAcnt StandardCrypto
    adjustNetworkTag (Shelley.RewardAcnt _ cred) = Shelley.RewardAcnt network cred

insertPoolRetire ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  Cache ->
  EpochNo ->
  Word16 ->
  Ledger.KeyHash 'Ledger.StakePool StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertPoolRetire trce txId cache epochNum idx keyHash = do
  poolId <- lift $ queryPoolKeyOrInsert "insertPoolRetire" trce cache CacheNew True keyHash
  void . lift . DB.insertPoolRetire $
    DB.PoolRetire
      { DB.poolRetireHashId = poolId
      , DB.poolRetireCertIndex = idx
      , DB.poolRetireAnnouncedTxId = txId
      , DB.poolRetireRetiringEpoch = unEpochNo epochNum
      }

insertMetaDataRef ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.PoolHashId ->
  DB.TxId ->
  Shelley.PoolMetadata ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) DB.PoolMetadataRefId
insertMetaDataRef poolId txId md =
  lift
    . DB.insertPoolMetadataRef
    $ DB.PoolMetadataRef
      { DB.poolMetadataRefPoolId = poolId
      , DB.poolMetadataRefUrl = PoolUrl $ Ledger.urlToText (Shelley.pmUrl md)
      , DB.poolMetadataRefHash = Shelley.pmHash md
      , DB.poolMetadataRefRegisteredTxId = txId
      }

-- | Insert a stake address if it is not already in the `stake_address` table. Regardless of
-- whether it is newly inserted or it is already there, we retrun the `StakeAddressId`.
insertStakeAddressRefIfMissing ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  Ledger.Addr StandardCrypto ->
  ReaderT SqlBackend m (Maybe DB.StakeAddressId)
insertStakeAddressRefIfMissing _trce cache addr =
  case addr of
    Ledger.AddrBootstrap {} -> pure Nothing
    Ledger.Addr nw _pcred sref ->
      case sref of
        Ledger.StakeRefBase cred -> do
          Just <$> queryOrInsertStakeAddress cache DontCacheNew nw cred
        Ledger.StakeRefPtr ptr -> do
          queryStakeRefPtr ptr
        Ledger.StakeRefNull -> pure Nothing

insertPoolOwner ::
  (MonadBaseControl IO m, MonadIO m) =>
  Cache ->
  Ledger.Network ->
  DB.PoolUpdateId ->
  Ledger.KeyHash 'Ledger.Staking StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertPoolOwner cache network poolUpdateId skh = do
  saId <- lift $ queryOrInsertStakeAddress cache CacheNew network (Ledger.KeyHashObj skh)
  void . lift . DB.insertPoolOwner $
    DB.PoolOwner
      { DB.poolOwnerAddrId = saId
      , DB.poolOwnerPoolUpdateId = poolUpdateId
      }

insertStakeRegistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  EpochNo ->
  DB.TxId ->
  Word16 ->
  Shelley.RewardAcnt StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertStakeRegistration epochNo txId idx rewardAccount = do
  -- We by-pass the cache here It's likely it won't hit.
  -- We don't store to the cache yet, since there are many addrresses
  -- which are registered and never used.
  saId <- lift $ insertStakeAddress rewardAccount Nothing
  void . lift . DB.insertStakeRegistration $
    DB.StakeRegistration
      { DB.stakeRegistrationAddrId = saId
      , DB.stakeRegistrationCertIndex = idx
      , DB.stakeRegistrationEpochNo = unEpochNo epochNo
      , DB.stakeRegistrationTxId = txId
      }

insertStakeDeregistration ::
  (MonadBaseControl IO m, MonadIO m) =>
  Cache ->
  Ledger.Network ->
  EpochNo ->
  DB.TxId ->
  Word16 ->
  Maybe DB.RedeemerId ->
  StakeCred ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertStakeDeregistration cache network epochNo txId idx mRedeemerId cred = do
  scId <- lift $ queryOrInsertStakeAddress cache EvictAndReturn network cred
  void . lift . DB.insertStakeDeregistration $
    DB.StakeDeregistration
      { DB.stakeDeregistrationAddrId = scId
      , DB.stakeDeregistrationCertIndex = idx
      , DB.stakeDeregistrationEpochNo = unEpochNo epochNo
      , DB.stakeDeregistrationTxId = txId
      , DB.stakeDeregistrationRedeemerId = mRedeemerId
      }

insertDelegation ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  Ledger.Network ->
  EpochNo ->
  SlotNo ->
  DB.TxId ->
  Word16 ->
  Maybe DB.RedeemerId ->
  StakeCred ->
  Ledger.KeyHash 'Ledger.StakePool StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertDelegation trce cache network (EpochNo epoch) slotNo txId idx mRedeemerId cred poolkh = do
  addrId <- lift $ queryOrInsertStakeAddress cache CacheNew network cred
  poolHashId <- lift $ queryPoolKeyOrInsert "insertDelegation" trce cache CacheNew True poolkh
  void . lift . DB.insertDelegation $
    DB.Delegation
      { DB.delegationAddrId = addrId
      , DB.delegationCertIndex = idx
      , DB.delegationPoolHashId = poolHashId
      , DB.delegationActiveEpochNo = epoch + 2 -- The first epoch where this delegation is valid.
      , DB.delegationTxId = txId
      , DB.delegationSlotNo = unSlotNo slotNo
      , DB.delegationRedeemerId = mRedeemerId
      }

insertDelegationVote ::
  (MonadBaseControl IO m, MonadIO m) =>
  Cache ->
  Ledger.Network ->
  DB.TxId ->
  Word16 ->
  StakeCred ->
  DRep StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertDelegationVote cache network txId idx cred drep = do
  addrId <- lift $ queryOrInsertStakeAddress cache CacheNew network cred
  drepId <- lift $ insertDrep drep
  void
    . lift
    . DB.insertDelegationVote
    $ DB.DelegationVote
      { DB.delegationVoteAddrId = addrId
      , DB.delegationVoteCertIndex = idx
      , DB.delegationVoteDrepHashId = drepId
      , DB.delegationVoteTxId = txId
      , DB.delegationVoteRedeemerId = Nothing
      }

insertMirCert ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  Ledger.Network ->
  DB.TxId ->
  Word16 ->
  Shelley.MIRCert StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertMirCert _tracer cache network txId idx mcert = do
  case Shelley.mirPot mcert of
    Shelley.ReservesMIR ->
      case Shelley.mirRewards mcert of
        Shelley.StakeAddressesMIR rwds -> mapM_ insertMirReserves $ Map.toList rwds
        Shelley.SendToOppositePotMIR xfrs -> insertPotTransfer (Ledger.toDeltaCoin xfrs)
    Shelley.TreasuryMIR -> do
      case Shelley.mirRewards mcert of
        Shelley.StakeAddressesMIR rwds -> mapM_ insertMirTreasury $ Map.toList rwds
        Shelley.SendToOppositePotMIR xfrs -> insertPotTransfer (invert $ Ledger.toDeltaCoin xfrs)
  where
    insertMirReserves ::
      (MonadBaseControl IO m, MonadIO m) =>
      (StakeCred, Ledger.DeltaCoin) ->
      ExceptT SyncNodeError (ReaderT SqlBackend m) ()
    insertMirReserves (cred, dcoin) = do
      addrId <- lift $ queryOrInsertStakeAddress cache CacheNew network cred
      void . lift . DB.insertReserve $
        DB.Reserve
          { DB.reserveAddrId = addrId
          , DB.reserveCertIndex = idx
          , DB.reserveTxId = txId
          , DB.reserveAmount = DB.deltaCoinToDbInt65 dcoin
          }

    insertMirTreasury ::
      (MonadBaseControl IO m, MonadIO m) =>
      (StakeCred, Ledger.DeltaCoin) ->
      ExceptT SyncNodeError (ReaderT SqlBackend m) ()
    insertMirTreasury (cred, dcoin) = do
      addrId <- lift $ queryOrInsertStakeAddress cache CacheNew network cred
      void . lift . DB.insertTreasury $
        DB.Treasury
          { DB.treasuryAddrId = addrId
          , DB.treasuryCertIndex = idx
          , DB.treasuryTxId = txId
          , DB.treasuryAmount = DB.deltaCoinToDbInt65 dcoin
          }

    insertPotTransfer ::
      (MonadBaseControl IO m, MonadIO m) =>
      Ledger.DeltaCoin ->
      ExceptT SyncNodeError (ReaderT SqlBackend m) ()
    insertPotTransfer dcoinTreasury =
      void
        . lift
        . DB.insertPotTransfer
        $ DB.PotTransfer
          { DB.potTransferCertIndex = idx
          , DB.potTransferTreasury = DB.deltaCoinToDbInt65 dcoinTreasury
          , DB.potTransferReserves = DB.deltaCoinToDbInt65 (invert dcoinTreasury)
          , DB.potTransferTxId = txId
          }

insertWithdrawals ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  DB.TxId ->
  Map Word64 DB.RedeemerId ->
  Generic.TxWithdrawal ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertWithdrawals _tracer cache txId redeemers txWdrl = do
  addrId <-
    lift $ queryOrInsertRewardAccount cache CacheNew $ Generic.txwRewardAccount txWdrl
  void . lift . DB.insertWithdrawal $
    DB.Withdrawal
      { DB.withdrawalAddrId = addrId
      , DB.withdrawalTxId = txId
      , DB.withdrawalAmount = Generic.coinToDbLovelace $ Generic.txwAmount txWdrl
      , DB.withdrawalRedeemerId = mlookup (Generic.txwRedeemerIndex txWdrl) redeemers
      }

insertPoolRelay ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.PoolUpdateId ->
  Shelley.StakePoolRelay ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertPoolRelay updateId relay =
  void
    . lift
    . DB.insertPoolRelay
    $ case relay of
      Shelley.SingleHostAddr mPort mIpv4 mIpv6 ->
        DB.PoolRelay -- An IPv4 and/or IPv6 address
          { DB.poolRelayUpdateId = updateId
          , DB.poolRelayIpv4 = textShow <$> strictMaybeToMaybe mIpv4
          , DB.poolRelayIpv6 = textShow <$> strictMaybeToMaybe mIpv6
          , DB.poolRelayDnsName = Nothing
          , DB.poolRelayDnsSrvName = Nothing
          , DB.poolRelayPort = Ledger.portToWord16 <$> strictMaybeToMaybe mPort
          }
      Shelley.SingleHostName mPort name ->
        DB.PoolRelay -- An A or AAAA DNS record
          { DB.poolRelayUpdateId = updateId
          , DB.poolRelayIpv4 = Nothing
          , DB.poolRelayIpv6 = Nothing
          , DB.poolRelayDnsName = Just (Ledger.dnsToText name)
          , DB.poolRelayDnsSrvName = Nothing
          , DB.poolRelayPort = Ledger.portToWord16 <$> strictMaybeToMaybe mPort
          }
      Shelley.MultiHostName name ->
        DB.PoolRelay -- An SRV DNS record
          { DB.poolRelayUpdateId = updateId
          , DB.poolRelayIpv4 = Nothing
          , DB.poolRelayIpv6 = Nothing
          , DB.poolRelayDnsName = Nothing
          , DB.poolRelayDnsSrvName = Just (Ledger.dnsToText name)
          , DB.poolRelayPort = Nothing
          }

insertParamProposal ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.BlockId ->
  DB.TxId ->
  ParamProposal ->
  ReaderT SqlBackend m DB.ParamProposalId
insertParamProposal blkId txId pp = do
  cmId <- maybe (pure Nothing) (fmap Just . insertCostModel blkId) (pppCostmdls pp)
  DB.insertParamProposal $
    DB.ParamProposal
      { DB.paramProposalRegisteredTxId = txId
      , DB.paramProposalEpochNo = unEpochNo <$> pppEpochNo pp
      , DB.paramProposalKey = pppKey pp
      , DB.paramProposalMinFeeA = fromIntegral <$> pppMinFeeA pp
      , DB.paramProposalMinFeeB = fromIntegral <$> pppMinFeeB pp
      , DB.paramProposalMaxBlockSize = fromIntegral <$> pppMaxBlockSize pp
      , DB.paramProposalMaxTxSize = fromIntegral <$> pppMaxTxSize pp
      , DB.paramProposalMaxBhSize = fromIntegral <$> pppMaxBhSize pp
      , DB.paramProposalKeyDeposit = Generic.coinToDbLovelace <$> pppKeyDeposit pp
      , DB.paramProposalPoolDeposit = Generic.coinToDbLovelace <$> pppPoolDeposit pp
      , DB.paramProposalMaxEpoch = unEpochNo <$> pppMaxEpoch pp
      , DB.paramProposalOptimalPoolCount = fromIntegral <$> pppOptimalPoolCount pp
      , DB.paramProposalInfluence = fromRational <$> pppInfluence pp
      , DB.paramProposalMonetaryExpandRate = toDouble <$> pppMonetaryExpandRate pp
      , DB.paramProposalTreasuryGrowthRate = toDouble <$> pppTreasuryGrowthRate pp
      , DB.paramProposalDecentralisation = toDouble <$> pppDecentralisation pp
      , DB.paramProposalEntropy = Generic.nonceToBytes =<< pppEntropy pp
      , DB.paramProposalProtocolMajor = getVersion . Ledger.pvMajor <$> pppProtocolVersion pp
      , DB.paramProposalProtocolMinor = fromIntegral . Ledger.pvMinor <$> pppProtocolVersion pp
      , DB.paramProposalMinUtxoValue = Generic.coinToDbLovelace <$> pppMinUtxoValue pp
      , DB.paramProposalMinPoolCost = Generic.coinToDbLovelace <$> pppMinPoolCost pp
      , -- New for Alonzo
        DB.paramProposalCoinsPerUtxoSize = Generic.coinToDbLovelace <$> pppCoinsPerUtxo pp
      , DB.paramProposalCostModelId = cmId
      , DB.paramProposalPriceMem = realToFrac <$> pppPriceMem pp
      , DB.paramProposalPriceStep = realToFrac <$> pppPriceStep pp
      , DB.paramProposalMaxTxExMem = DbWord64 <$> pppMaxTxExMem pp
      , DB.paramProposalMaxTxExSteps = DbWord64 <$> pppMaxTxExSteps pp
      , DB.paramProposalMaxBlockExMem = DbWord64 <$> pppMaxBlockExMem pp
      , DB.paramProposalMaxBlockExSteps = DbWord64 <$> pppMaxBlockExSteps pp
      , DB.paramProposalMaxValSize = DbWord64 . fromIntegral <$> pppMaxValSize pp
      , DB.paramProposalCollateralPercent = fromIntegral <$> pppCollateralPercentage pp
      , DB.paramProposalMaxCollateralInputs = fromIntegral <$> pppMaxCollateralInputs pp
      , -- New for Conway
        DB.paramProposalPvtMotionNoConfidence = toDouble . pvtMotionNoConfidence <$> pppPoolVotingThresholds pp
      , DB.paramProposalPvtCommitteeNormal = toDouble . pvtCommitteeNormal <$> pppPoolVotingThresholds pp
      , DB.paramProposalPvtCommitteeNoConfidence = toDouble . pvtCommitteeNoConfidence <$> pppPoolVotingThresholds pp
      , DB.paramProposalPvtHardForkInitiation = toDouble . pvtHardForkInitiation <$> pppPoolVotingThresholds pp
      , DB.paramProposalDvtMotionNoConfidence = toDouble . dvtMotionNoConfidence <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtCommitteeNormal = toDouble . dvtCommitteeNormal <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtCommitteeNoConfidence = toDouble . dvtCommitteeNoConfidence <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtUpdateToConstitution = toDouble . dvtUpdateToConstitution <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtHardForkInitiation = toDouble . dvtHardForkInitiation <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtPPNetworkGroup = toDouble . dvtPPNetworkGroup <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtPPEconomicGroup = toDouble . dvtPPEconomicGroup <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtPPTechnicalGroup = toDouble . dvtPPTechnicalGroup <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtPPGovGroup = toDouble . dvtPPGovGroup <$> pppDRepVotingThresholds pp
      , DB.paramProposalDvtTreasuryWithdrawal = toDouble . dvtTreasuryWithdrawal <$> pppDRepVotingThresholds pp
      , DB.paramProposalCommitteeMinSize = DbWord64 . fromIntegral <$> pppCommitteeMinSize pp
      , DB.paramProposalCommitteeMaxTermLength = DbWord64 . fromIntegral <$> pppCommitteeMaxTermLength pp
      , DB.paramProposalGovActionLifetime = unEpochNo <$> pppGovActionLifetime pp
      , DB.paramProposalGovActionDeposit = DbWord64 . fromIntegral <$> pppGovActionDeposit pp
      , DB.paramProposalDrepDeposit = DbWord64 . fromIntegral <$> pppDRepDeposit pp
      , DB.paramProposalDrepActivity = unEpochNo <$> pppDRepActivity pp
      }

toDouble :: Ledger.UnitInterval -> Double
toDouble = Generic.unitIntervalToDouble

insertRedeemer ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Bool ->
  [ExtendedTxOut] ->
  DB.TxId ->
  (Word64, Generic.TxRedeemer) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) (Word64, DB.RedeemerId)
insertRedeemer tracer disInOut groupedOutputs txId (rix, redeemer) = do
  tdId <- insertRedeemerData tracer txId $ Generic.txRedeemerData redeemer
  scriptHash <- findScriptHash
  rid <-
    lift
      . DB.insertRedeemer
      $ DB.Redeemer
        { DB.redeemerTxId = txId
        , DB.redeemerUnitMem = Generic.txRedeemerMem redeemer
        , DB.redeemerUnitSteps = Generic.txRedeemerSteps redeemer
        , DB.redeemerFee = DB.DbLovelace . fromIntegral . unCoin <$> Generic.txRedeemerFee redeemer
        , DB.redeemerPurpose = mkPurpose $ Generic.txRedeemerPurpose redeemer
        , DB.redeemerIndex = Generic.txRedeemerIndex redeemer
        , DB.redeemerScriptHash = scriptHash
        , DB.redeemerRedeemerDataId = tdId
        }
  pure (rix, rid)
  where
    mkPurpose :: Ledger.Tag -> DB.ScriptPurpose
    mkPurpose tag =
      case tag of
        Ledger.Spend -> DB.Spend
        Ledger.Mint -> DB.Mint
        Ledger.Cert -> DB.Cert
        Ledger.Rewrd -> DB.Rewrd

    findScriptHash ::
      (MonadBaseControl IO m, MonadIO m) =>
      ExceptT SyncNodeError (ReaderT SqlBackend m) (Maybe ByteString)
    findScriptHash =
      case (disInOut, Generic.txRedeemerScriptHash redeemer) of
        (True, _) -> pure Nothing
        (_, Nothing) -> pure Nothing
        (_, Just (Right bs)) -> pure $ Just bs
        (_, Just (Left txIn)) -> resolveScriptHash groupedOutputs txIn

insertDatum ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  DB.TxId ->
  Generic.PlutusData ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) DB.DatumId
insertDatum tracer cache txId txd = do
  mDatumId <- lift $ queryDatum cache $ Generic.txDataHash txd
  case mDatumId of
    Just datumId -> pure datumId
    Nothing -> do
      value <- safeDecodeToJson tracer "insertDatum" $ Generic.txDataValue txd
      lift $
        insertDatumAndCache cache (Generic.txDataHash txd) $
          DB.Datum
            { DB.datumHash = Generic.dataHashToBytes $ Generic.txDataHash txd
            , DB.datumTxId = txId
            , DB.datumValue = value
            , DB.datumBytes = Generic.txDataBytes txd
            }

insertRedeemerData ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  Generic.PlutusData ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) DB.RedeemerDataId
insertRedeemerData tracer txId txd = do
  mRedeemerDataId <- lift $ DB.queryRedeemerData $ Generic.dataHashToBytes $ Generic.txDataHash txd
  case mRedeemerDataId of
    Just redeemerDataId -> pure redeemerDataId
    Nothing -> do
      value <- safeDecodeToJson tracer "insertRedeemerData" $ Generic.txDataValue txd
      lift
        . DB.insertRedeemerData
        $ DB.RedeemerData
          { DB.redeemerDataHash = Generic.dataHashToBytes $ Generic.txDataHash txd
          , DB.redeemerDataTxId = txId
          , DB.redeemerDataValue = value
          , DB.redeemerDataBytes = Generic.txDataBytes txd
          }

prepareTxMetadata ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  InsertOptions ->
  Maybe (Map Word64 TxMetadataValue) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) [DB.TxMetadata]
prepareTxMetadata tracer txId inOpts mmetadata = do
  case mmetadata of
    Nothing -> pure []
    Just metadata -> mapMaybeM prepare $ Map.toList metadata
  where
    prepare ::
      (MonadBaseControl IO m, MonadIO m) =>
      (Word64, TxMetadataValue) ->
      ExceptT SyncNodeError (ReaderT SqlBackend m) (Maybe DB.TxMetadata)
    prepare (key, md) = do
      case ioKeepMetadataNames inOpts of
        Strict.Just metadataNames -> do
          let isMatchingKey = key `elem` metadataNames
          if isMatchingKey
            then mkDbTxMetadata (key, md)
            else pure Nothing
        -- if we have TxMetadata and keepMetadataNames is Nothing then we want to keep all metadata
        Strict.Nothing -> mkDbTxMetadata (key, md)

    mkDbTxMetadata ::
      (MonadBaseControl IO m, MonadIO m) =>
      (Word64, TxMetadataValue) ->
      ExceptT SyncNodeError (ReaderT SqlBackend m) (Maybe DB.TxMetadata)
    mkDbTxMetadata (key, md) = do
      let jsonbs = LBS.toStrict $ Aeson.encode (metadataValueToJsonNoSchema md)
          singleKeyCBORMetadata = serialiseTxMetadataToCbor $ Map.singleton key md
      mjson <- safeDecodeToJson tracer "prepareTxMetadata" jsonbs
      pure $
        Just $
          DB.TxMetadata
            { DB.txMetadataKey = DbWord64 key
            , DB.txMetadataJson = mjson
            , DB.txMetadataBytes = singleKeyCBORMetadata
            , DB.txMetadataTxId = txId
            }

insertCostModel ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.BlockId ->
  Map Language Ledger.CostModel ->
  ReaderT SqlBackend m DB.CostModelId
insertCostModel _blkId cms =
  DB.insertCostModel $
    DB.CostModel
      { DB.costModelHash = Crypto.abstractHashToBytes $ Crypto.serializeCborHash $ Ledger.CostModels cms mempty mempty
      , DB.costModelCosts = Text.decodeUtf8 $ LBS.toStrict $ Aeson.encode cms
      }

insertEpochParam ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.BlockId ->
  EpochNo ->
  Generic.ProtoParams ->
  Ledger.Nonce ->
  ReaderT SqlBackend m ()
insertEpochParam _tracer blkId (EpochNo epoch) params nonce = do
  cmId <- maybe (pure Nothing) (fmap Just . insertCostModel blkId) (Generic.ppCostmdls params)
  void
    . DB.insertEpochParam
    $ DB.EpochParam
      { DB.epochParamEpochNo = epoch
      , DB.epochParamMinFeeA = fromIntegral (Generic.ppMinfeeA params)
      , DB.epochParamMinFeeB = fromIntegral (Generic.ppMinfeeB params)
      , DB.epochParamMaxBlockSize = fromIntegral (Generic.ppMaxBBSize params)
      , DB.epochParamMaxTxSize = fromIntegral (Generic.ppMaxTxSize params)
      , DB.epochParamMaxBhSize = fromIntegral (Generic.ppMaxBHSize params)
      , DB.epochParamKeyDeposit = Generic.coinToDbLovelace (Generic.ppKeyDeposit params)
      , DB.epochParamPoolDeposit = Generic.coinToDbLovelace (Generic.ppPoolDeposit params)
      , DB.epochParamMaxEpoch = unEpochNo (Generic.ppMaxEpoch params)
      , DB.epochParamOptimalPoolCount = fromIntegral (Generic.ppOptialPoolCount params)
      , DB.epochParamInfluence = fromRational (Generic.ppInfluence params)
      , DB.epochParamMonetaryExpandRate = toDouble (Generic.ppMonetaryExpandRate params)
      , DB.epochParamTreasuryGrowthRate = toDouble (Generic.ppTreasuryGrowthRate params)
      , DB.epochParamDecentralisation = toDouble (Generic.ppDecentralisation params)
      , DB.epochParamExtraEntropy = Generic.nonceToBytes $ Generic.ppExtraEntropy params
      , DB.epochParamProtocolMajor = getVersion $ Ledger.pvMajor (Generic.ppProtocolVersion params)
      , DB.epochParamProtocolMinor = fromIntegral $ Ledger.pvMinor (Generic.ppProtocolVersion params)
      , DB.epochParamMinUtxoValue = Generic.coinToDbLovelace (Generic.ppMinUTxOValue params)
      , DB.epochParamMinPoolCost = Generic.coinToDbLovelace (Generic.ppMinPoolCost params)
      , DB.epochParamNonce = Generic.nonceToBytes nonce
      , DB.epochParamCoinsPerUtxoSize = Generic.coinToDbLovelace <$> Generic.ppCoinsPerUtxo params
      , DB.epochParamCostModelId = cmId
      , DB.epochParamPriceMem = realToFrac <$> Generic.ppPriceMem params
      , DB.epochParamPriceStep = realToFrac <$> Generic.ppPriceStep params
      , DB.epochParamMaxTxExMem = DbWord64 <$> Generic.ppMaxTxExMem params
      , DB.epochParamMaxTxExSteps = DbWord64 <$> Generic.ppMaxTxExSteps params
      , DB.epochParamMaxBlockExMem = DbWord64 <$> Generic.ppMaxBlockExMem params
      , DB.epochParamMaxBlockExSteps = DbWord64 <$> Generic.ppMaxBlockExSteps params
      , DB.epochParamMaxValSize = DbWord64 . fromIntegral <$> Generic.ppMaxValSize params
      , DB.epochParamCollateralPercent = fromIntegral <$> Generic.ppCollateralPercentage params
      , DB.epochParamMaxCollateralInputs = fromIntegral <$> Generic.ppMaxCollateralInputs params
      , DB.epochParamPvtMotionNoConfidence = toDouble . pvtMotionNoConfidence <$> Generic.ppPoolVotingThresholds params
      , DB.epochParamPvtCommitteeNormal = toDouble . pvtCommitteeNormal <$> Generic.ppPoolVotingThresholds params
      , DB.epochParamPvtCommitteeNoConfidence = toDouble . pvtCommitteeNoConfidence <$> Generic.ppPoolVotingThresholds params
      , DB.epochParamPvtHardForkInitiation = toDouble . pvtHardForkInitiation <$> Generic.ppPoolVotingThresholds params
      , DB.epochParamDvtMotionNoConfidence = toDouble . dvtMotionNoConfidence <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtCommitteeNormal = toDouble . dvtCommitteeNormal <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtCommitteeNoConfidence = toDouble . dvtCommitteeNoConfidence <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtUpdateToConstitution = toDouble . dvtUpdateToConstitution <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtHardForkInitiation = toDouble . dvtHardForkInitiation <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtPPNetworkGroup = toDouble . dvtPPNetworkGroup <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtPPEconomicGroup = toDouble . dvtPPEconomicGroup <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtPPTechnicalGroup = toDouble . dvtPPTechnicalGroup <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtPPGovGroup = toDouble . dvtPPGovGroup <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamDvtTreasuryWithdrawal = toDouble . dvtTreasuryWithdrawal <$> Generic.ppDRepVotingThresholds params
      , DB.epochParamCommitteeMinSize = DbWord64 . fromIntegral <$> Generic.ppCommitteeMinSize params
      , DB.epochParamCommitteeMaxTermLength = DbWord64 . fromIntegral <$> Generic.ppCommitteeMaxTermLength params
      , DB.epochParamGovActionLifetime = unEpochNo <$> Generic.ppGovActionLifetime params
      , DB.epochParamGovActionDeposit = DbWord64 . fromIntegral <$> Generic.ppGovActionDeposit params
      , DB.epochParamDrepDeposit = DbWord64 . fromIntegral <$> Generic.ppDRepDeposit params
      , DB.epochParamDrepActivity = unEpochNo <$> Generic.ppDRepActivity params
      , DB.epochParamBlockId = blkId
      }

prepareMaTxMint ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  DB.TxId ->
  MultiAsset StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) [DB.MaTxMint]
prepareMaTxMint _tracer cache txId (MultiAsset mintMap) =
  concatMapM (lift . prepareOuter) $ Map.toList mintMap
  where
    prepareOuter ::
      (MonadBaseControl IO m, MonadIO m) =>
      (PolicyID StandardCrypto, Map AssetName Integer) ->
      ReaderT SqlBackend m [DB.MaTxMint]
    prepareOuter (policy, aMap) =
      mapM (prepareInner policy) $ Map.toList aMap

    prepareInner ::
      (MonadBaseControl IO m, MonadIO m) =>
      PolicyID StandardCrypto ->
      (AssetName, Integer) ->
      ReaderT SqlBackend m DB.MaTxMint
    prepareInner policy (aname, amount) = do
      maId <- insertMultiAsset cache policy aname
      pure $
        DB.MaTxMint
          { DB.maTxMintIdent = maId
          , DB.maTxMintQuantity = DB.integerToDbInt65 amount
          , DB.maTxMintTxId = txId
          }

prepareMaTxOuts ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  Cache ->
  Map (PolicyID StandardCrypto) (Map AssetName Integer) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) [MissingMaTxOut]
prepareMaTxOuts _tracer cache maMap =
  concatMapM (lift . prepareOuter) $ Map.toList maMap
  where
    prepareOuter ::
      (MonadBaseControl IO m, MonadIO m) =>
      (PolicyID StandardCrypto, Map AssetName Integer) ->
      ReaderT SqlBackend m [MissingMaTxOut]
    prepareOuter (policy, aMap) =
      mapM (prepareInner policy) $ Map.toList aMap

    prepareInner ::
      (MonadBaseControl IO m, MonadIO m) =>
      PolicyID StandardCrypto ->
      (AssetName, Integer) ->
      ReaderT SqlBackend m MissingMaTxOut
    prepareInner policy (aname, amount) = do
      maId <- insertMultiAsset cache policy aname
      pure $
        MissingMaTxOut
          { mmtoIdent = maId
          , mmtoQuantity = DbWord64 (fromIntegral amount)
          }

insertMultiAsset ::
  (MonadBaseControl IO m, MonadIO m) =>
  Cache ->
  PolicyID StandardCrypto ->
  AssetName ->
  ReaderT SqlBackend m DB.MultiAssetId
insertMultiAsset cache policy aName = do
  mId <- queryMAWithCache cache policy aName
  case mId of
    Right maId -> pure maId
    Left (policyBs, assetNameBs) ->
      DB.insertMultiAssetUnchecked $
        DB.MultiAsset
          { DB.multiAssetPolicy = policyBs
          , DB.multiAssetName = assetNameBs
          , DB.multiAssetFingerprint = DB.unAssetFingerprint (DB.mkAssetFingerprint policyBs assetNameBs)
          }

insertScript ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  Generic.TxScript ->
  ReaderT SqlBackend m DB.ScriptId
insertScript tracer txId script = do
  mScriptId <- DB.queryScript $ Generic.txScriptHash script
  case mScriptId of
    Just scriptId -> pure scriptId
    Nothing -> do
      json <- scriptConvert script
      DB.insertScript $
        DB.Script
          { DB.scriptTxId = txId
          , DB.scriptHash = Generic.txScriptHash script
          , DB.scriptType = Generic.txScriptType script
          , DB.scriptSerialisedSize = Generic.txScriptPlutusSize script
          , DB.scriptJson = json
          , DB.scriptBytes = Generic.txScriptCBOR script
          }
  where
    scriptConvert :: MonadIO m => Generic.TxScript -> m (Maybe Text)
    scriptConvert s =
      maybe (pure Nothing) (safeDecodeToJson tracer "insertScript") (Generic.txScriptJson s)

insertExtraKeyWitness ::
  (MonadBaseControl IO m, MonadIO m) =>
  Trace IO Text ->
  DB.TxId ->
  ByteString ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertExtraKeyWitness _tracer txId keyHash = do
  void
    . lift
    . DB.insertExtraKeyWitness
    $ DB.ExtraKeyWitness
      { DB.extraKeyWitnessHash = keyHash
      , DB.extraKeyWitnessTxId = txId
      }

insertPots ::
  (MonadBaseControl IO m, MonadIO m) =>
  DB.BlockId ->
  SlotNo ->
  EpochNo ->
  Shelley.AdaPots ->
  ExceptT e (ReaderT SqlBackend m) ()
insertPots blockId slotNo epochNo pots =
  void
    . lift
    $ DB.insertAdaPots
    $ mkAdaPots blockId slotNo epochNo pots

mkAdaPots ::
  DB.BlockId ->
  SlotNo ->
  EpochNo ->
  Shelley.AdaPots ->
  DB.AdaPots
mkAdaPots blockId slotNo epochNo pots =
  DB.AdaPots
    { DB.adaPotsSlotNo = unSlotNo slotNo
    , DB.adaPotsEpochNo = unEpochNo epochNo
    , DB.adaPotsTreasury = Generic.coinToDbLovelace $ Shelley.treasuryAdaPot pots
    , DB.adaPotsReserves = Generic.coinToDbLovelace $ Shelley.reservesAdaPot pots
    , DB.adaPotsRewards = Generic.coinToDbLovelace $ Shelley.rewardsAdaPot pots
    , DB.adaPotsUtxo = Generic.coinToDbLovelace $ Shelley.utxoAdaPot pots
    , DB.adaPotsDeposits = Generic.coinToDbLovelace $ Shelley.depositsAdaPot pots
    , DB.adaPotsFees = Generic.coinToDbLovelace $ Shelley.feesAdaPot pots
    , DB.adaPotsBlockId = blockId
    }

insertGovActionProposal ::
  (MonadIO m, MonadBaseControl IO m) =>
  Cache ->
  DB.BlockId ->
  DB.TxId ->
  Maybe EpochNo ->
  (Word64, ProposalProcedure StandardConway) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertGovActionProposal cache blkId txId govExpiresAt (index, pp) = do
  addrId <-
    lift $ queryOrInsertRewardAccount cache CacheNew $ pProcReturnAddr pp
  votingAnchorId <- lift $ insertAnchor txId $ pProcAnchor pp
  mParamProposalId <- lift $
    case pProcGovAction pp of
      ParameterChange _ pparams ->
        Just <$> insertParamProposal blkId txId (convertConwayParamProposal pparams)
      _ -> pure Nothing
  prevGovActionDBId <- case mprevGovAction of
    Nothing -> pure Nothing
    Just prevGovActionId -> Just <$> resolveGovActionProposal prevGovActionId
  govActionProposalId <-
    lift $
      DB.insertGovActionProposal $
        DB.GovActionProposal
          { DB.govActionProposalTxId = txId
          , DB.govActionProposalIndex = index
          , DB.govActionProposalPrevGovActionProposal = prevGovActionDBId
          , DB.govActionProposalDeposit = Generic.coinToDbLovelace $ pProcDeposit pp
          , DB.govActionProposalReturnAddress = addrId
          , DB.govActionProposalExpiration = unEpochNo <$> govExpiresAt
          , DB.govActionProposalVotingAnchorId = Just votingAnchorId
          , DB.govActionProposalType = Generic.toGovAction $ pProcGovAction pp
          , DB.govActionProposalDescription = Text.decodeUtf8 $ LBS.toStrict $ Aeson.encode (pProcGovAction pp)
          , DB.govActionProposalParamProposal = mParamProposalId
          , DB.govActionProposalRatifiedEpoch = Nothing
          , DB.govActionProposalEnactedEpoch = Nothing
          , DB.govActionProposalDroppedEpoch = Nothing
          , DB.govActionProposalExpiredEpoch = Nothing
          }
  case pProcGovAction pp of
    TreasuryWithdrawals mp -> lift $ mapM_ (insertTreasuryWithdrawal govActionProposalId) (Map.toList mp)
    UpdateCommittee _ removed added q -> lift $ insertNewCommittee govActionProposalId removed added q
    NewConstitution _ constitution -> lift $ insertConstitution txId govActionProposalId constitution
    _ -> pure ()
  where
    mprevGovAction :: Maybe (GovActionId StandardCrypto) = case pProcGovAction pp of
      ParameterChange prv _ -> unPrevGovActionId <$> strictMaybeToMaybe prv
      HardForkInitiation prv _ -> unPrevGovActionId <$> strictMaybeToMaybe prv
      NoConfidence prv -> unPrevGovActionId <$> strictMaybeToMaybe prv
      UpdateCommittee prv _ _ _ -> unPrevGovActionId <$> strictMaybeToMaybe prv
      NewConstitution prv _ -> unPrevGovActionId <$> strictMaybeToMaybe prv
      _ -> Nothing

    insertTreasuryWithdrawal gaId (rwdAcc, coin) = do
      addrId <-
        queryOrInsertRewardAccount cache CacheNew rwdAcc
      DB.insertTreasuryWithdrawal $
        DB.TreasuryWithdrawal
          { DB.treasuryWithdrawalGovActionProposalId = gaId
          , DB.treasuryWithdrawalStakeAddressId = addrId
          , DB.treasuryWithdrawalAmount = Generic.coinToDbLovelace coin
          }

    insertNewCommittee gaId removed added q = do
      void . DB.insertNewCommittee $
        DB.NewCommittee
          { DB.newCommitteeGovActionProposalId = gaId
          , DB.newCommitteeQuorumNominator = fromIntegral $ numerator r
          , DB.newCommitteeQuorumDenominator = fromIntegral $ denominator r
          , DB.newCommitteeDeletedMembers = textShow removed
          , DB.newCommitteeAddedMembers = textShow added
          }
      where
        r = unboundRational q -- TODO work directly with Ratio Word64. This is not currently supported in ledger

insertAnchor :: (MonadIO m, MonadBaseControl IO m) => DB.TxId -> Anchor StandardCrypto -> ReaderT SqlBackend m DB.VotingAnchorId
insertAnchor txId anchor =
  DB.insertAnchor $
    DB.VotingAnchor
      { DB.votingAnchorTxId = txId
      , DB.votingAnchorUrl = DB.VoteUrl $ Ledger.urlToText $ anchorUrl anchor -- TODO: Conway check unicode and size of URL
      , DB.votingAnchorDataHash = Generic.safeHashToByteString $ anchorDataHash anchor
      }

insertConstitution :: (MonadIO m, MonadBaseControl IO m) => DB.TxId -> DB.GovActionProposalId -> Constitution StandardConway -> ReaderT SqlBackend m ()
insertConstitution txId gapId constitution = do
  votingAnchorId <- insertAnchor txId $ constitutionAnchor constitution
  void . DB.insertConstitution $
    DB.Constitution
      { DB.constitutionGovActionProposalId = gapId
      , DB.constitutionVotingAnchorId = votingAnchorId
      , DB.constitutionScriptHash = Generic.unScriptHash <$> strictMaybeToMaybe (constitutionScript constitution)
      }

insertVotingProcedures ::
  (MonadIO m, MonadBaseControl IO m) =>
  Trace IO Text ->
  Cache ->
  DB.TxId ->
  (Voter StandardCrypto, [(GovActionId StandardCrypto, VotingProcedure StandardConway)]) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertVotingProcedures trce cache txId (voter, actions) =
  mapM_ (insertVotingProcedure trce cache txId voter) (zip [0 ..] actions)

insertVotingProcedure ::
  (MonadIO m, MonadBaseControl IO m) =>
  Trace IO Text ->
  Cache ->
  DB.TxId ->
  Voter StandardCrypto ->
  (Word16, (GovActionId StandardCrypto, VotingProcedure StandardConway)) ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) ()
insertVotingProcedure trce cache txId voter (index, (gaId, vp)) = do
  govActionId <- resolveGovActionProposal gaId
  votingAnchorId <- whenMaybe (strictMaybeToMaybe $ vProcAnchor vp) $ lift . insertAnchor txId
  (mCommitteeVoter, mDRepVoter, mStakePoolVoter) <- case voter of
    CommitteeVoter cred ->
      pure (Just $ Generic.unCredentialHash cred, Nothing, Nothing)
    DRepVoter cred -> do
      drep <- lift $ insertCredDrepHash cred
      pure (Nothing, Just drep, Nothing)
    StakePoolVoter poolkh -> do
      poolHashId <- lift $ queryPoolKeyOrInsert "insertVotingProcedure" trce cache CacheNew False poolkh
      pure (Nothing, Nothing, Just poolHashId)
  void
    . lift
    . DB.insertVotingProcedure
    $ DB.VotingProcedure
      { DB.votingProcedureTxId = txId
      , DB.votingProcedureIndex = index
      , DB.votingProcedureGovActionProposalId = govActionId
      , DB.votingProcedureCommitteeVoter = mCommitteeVoter
      , DB.votingProcedureDrepVoter = mDRepVoter
      , DB.votingProcedurePoolVoter = mStakePoolVoter
      , DB.votingProcedureVoterRole = Generic.toVoterRole voter
      , DB.votingProcedureVote = Generic.toVote $ vProcVote vp
      , DB.votingProcedureVotingAnchorId = votingAnchorId
      }

resolveGovActionProposal ::
  MonadIO m =>
  GovActionId StandardCrypto ->
  ExceptT SyncNodeError (ReaderT SqlBackend m) DB.GovActionProposalId
resolveGovActionProposal gaId = do
  gaTxId <-
    liftLookupFail "resolveGovActionProposal.queryTxId" $
      DB.queryTxId $
        Generic.unTxHash $
          gaidTxId gaId
  let (GovActionIx index) = gaidGovActionIx gaId
  liftLookupFail "resolveGovActionProposal.queryGovActionProposalId" $
    DB.queryGovActionProposalId gaTxId (fromIntegral index) -- TODO: Use Word32?

insertDrep :: (MonadBaseControl IO m, MonadIO m) => DRep StandardCrypto -> ReaderT SqlBackend m DB.DrepHashId
insertDrep = \case
  DRepCredential cred -> insertCredDrepHash cred
  DRepAlwaysAbstain -> DB.insertAlwaysAbstainDrep
  DRepAlwaysNoConfidence -> DB.insertAlwaysNoConfidence

insertCredDrepHash :: (MonadBaseControl IO m, MonadIO m) => Ledger.Credential 'DRepRole StandardCrypto -> ReaderT SqlBackend m DB.DrepHashId
insertCredDrepHash cred = do
  DB.insertDrepHash
    DB.DrepHash
      { DB.drepHashRaw = Just bs
      , DB.drepHashView = serialiseDrepToBech32 bs
      , DB.drepHashHasScript = Generic.hasCredScript cred
      }
  where
    bs = Generic.unCredentialHash cred

insertDrepDistr :: forall m. (MonadBaseControl IO m, MonadIO m) => EpochNo -> PulsingSnapshot StandardConway -> ReaderT SqlBackend m ()
insertDrepDistr e pSnapshot = do
  drepsDB <- mapM mkEntry (Map.toList $ psDRepDistr pSnapshot)
  DB.insertManyDrepDistr drepsDB
  where
    mkEntry :: (DRep StandardCrypto, Ledger.CompactForm Coin) -> ReaderT SqlBackend m DB.DrepDistr
    mkEntry (drep, coin) = do
      drepId <- insertDrep drep
      pure $
        DB.DrepDistr
          { DB.drepDistrHashId = drepId
          , DB.drepDistrAmount = fromIntegral $ unCoin $ fromCompact coin
          , DB.drepDistrEpochNo = unEpochNo e
          , DB.drepDistrActiveUntil = unEpochNo <$> isActiveEpochNo drep
          }

    isActiveEpochNo :: DRep StandardCrypto -> Maybe EpochNo
    isActiveEpochNo = \case
      DRepAlwaysAbstain -> Nothing
      DRepAlwaysNoConfidence -> Nothing
      DRepCredential cred -> drepExpiry <$> Map.lookup cred (psDRepState pSnapshot)

updateEnacted :: forall m. (MonadBaseControl IO m, MonadIO m) => Bool -> EpochNo -> EnactState StandardConway -> ExceptT SyncNodeError (ReaderT SqlBackend m) ()
updateEnacted isEnacted epochNo enactedState = do
  whenJust (strictMaybeToMaybe (enactedState ^. ensPrevPParamUpdateL)) $ \prevId -> do
    gaId <- resolveGovActionProposal $ getPrevId prevId
    if isEnacted
      then lift $ DB.updateGovActionEnacted gaId (unEpochNo epochNo)
      else lift $ DB.updateGovActionRatified gaId (unEpochNo epochNo)
  where
    getPrevId (PrevGovActionId gai) = gai
