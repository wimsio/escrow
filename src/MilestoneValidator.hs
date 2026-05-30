{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module MilestoneValidator where

import qualified Prelude as H

import qualified Plutus.V2.Ledger.Api as PlutusV2
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , Validator
  , mkValidatorScript
  , unValidatorScript
  )
import qualified PlutusTx
import PlutusTx (compile, unsafeFromBuiltinData)
import PlutusTx.Builtins as Builtins
import PlutusTx.Prelude as P hiding (Semigroup(..))

import qualified Codec.Serialise        as Serialise
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8  as C8
import qualified Data.ByteString.Lazy   as LBS

import EscrowSplitTypes
import EscrowSplitCommon

--------------------------------------------------------------------------------
-- Milestone helpers
--------------------------------------------------------------------------------

{-# INLINABLE validMilestoneDatum #-}
validMilestoneDatum :: MilestoneDatum -> Bool
validMilestoneDatum d =
     mdAmount d > 0
  && mdRevisionCount d >= 0
  && mdMaxRevisions d >= 0
  && mdSubmitDeadline d <= mdReviewDeadline d
  && mdReviewDeadline d <= mdRevisionDeadline d
  && mdRevisionDeadline d <= mdDisputeDeadline d


{-# INLINABLE requireMilestoneContinuing #-}
requireMilestoneContinuing :: PlutusV2.ScriptContext -> MilestoneDatum -> Bool
requireMilestoneContinuing ctx expected =
  let
    inRef = findOwnInputOrFail ctx
    outRef = getSingleContinuingOutput ctx
  in
       traceIfFalse "M1" (datumMatches expected outRef)
    && traceIfFalse "M2" (PlutusV2.txOutValue outRef == PlutusV2.txOutValue inRef)

{-# INLINABLE closeMilestoneWithNoContinuing #-}
closeMilestoneWithNoContinuing :: PlutusV2.ScriptContext -> Bool
closeMilestoneWithNoContinuing ctx =
  case assertNoContinuingOutput ctx of
    () -> True

{-# INLINABLE projectInputPresent #-}
projectInputPresent :: PlutusV2.TxInfo -> MilestoneDatum -> Bool
projectInputPresent info d = hasInputFromScript info (mdProjectValidatorHash d)

{-# INLINABLE disputeDatumFromMilestone #-}
disputeDatumFromMilestone :: MilestoneDatum -> BuiltinByteString -> DisputeDatum
disputeDatumFromMilestone d subHash =
  DisputeDatum
    { ddProjectId            = mdProjectId d
    , ddIndex                = mdIndex d
    , ddClient               = mdClient d
    , ddFreelancer           = mdFreelancer d
    , ddReviewers            = mdReviewers d
    , ddPlatform             = mdPlatform d
    , ddPlatformFeeRate      = mdPlatformFeeRate d
    , ddReviewerFeeRate      = mdReviewerFeeRate d
    , ddDisputeDeadline      = mdDisputeDeadline d
    , ddAmount               = mdAmount d
    , ddSubmissionHash       = subHash
    , ddProjectValidatorHash = mdProjectValidatorHash d
    }

{-# INLINABLE disputeOutputCreated #-}
disputeOutputCreated :: PlutusV2.TxInfo -> MilestoneDatum -> BuiltinByteString -> Bool
disputeOutputCreated info d subHash =
  let dd = disputeDatumFromMilestone d subHash
  in
    P.foldr
      (\o acc ->
        acc ||
          (    isOutputAtScript (mdDisputeValidatorHash d) o
            && datumMatches dd o
            && lovelaceOf (PlutusV2.txOutValue o) == mdAmount d
          )
      )
      False
      (PlutusV2.txInfoOutputs info)

{-# INLINABLE validExtensionOrdering #-}
validExtensionOrdering :: PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> Bool
validExtensionOrdering s r rv d =
     s <= r
  && r <= rv
  && rv <= d

{-# INLINABLE extensionMovesForward #-}
extensionMovesForward :: MilestoneDatum -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> Bool
extensionMovesForward old s r rv d =
     s  >= mdSubmitDeadline old
  && r  >= mdReviewDeadline old
  && rv >= mdRevisionDeadline old
  && d  >= mdDisputeDeadline old
  && (    s  > mdSubmitDeadline old
       || r  > mdReviewDeadline old
       || rv > mdRevisionDeadline old
       || d  > mdDisputeDeadline old
     )

{-# INLINABLE extensionReactivates #-}
extensionReactivates :: MilestoneDatum -> PlutusV2.TxInfo -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> PlutusV2.POSIXTime -> Bool
extensionReactivates old info s r rv =
  let now = fromLowerBound (PlutusV2.txInfoValidRange info)
  in
    case mdStatus old of
      MilestonePending -> s > now
      MilestoneSubmitted _ -> r > now
      MilestoneNeedsRevision _ -> rv > now

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------
{-# INLINABLE mkMilestoneValidator #-}
mkMilestoneValidator :: MilestoneDatum -> MilestoneAction -> PlutusV2.ScriptContext -> Bool
mkMilestoneValidator old action ctx =
  let
    info = PlutusV2.scriptContextTxInfo ctx
    inRef = findOwnInputOrFail ctx
    platformFee = feeOf (mdAmount old) (mdPlatformFeeRate old)
    freelancerNet = mdAmount old - platformFee
  in
       traceIfFalse "M3" (validMilestoneDatum old)
    && traceIfFalse "M4" (lovelaceOf (PlutusV2.txOutValue inRef) >= mdAmount old)
    && case action of

      MSubmitWork subHash ->
           traceIfFalse "M5" (signedBy info (mdFreelancer old))
        && traceIfFalse "M6" (subHash /= Builtins.emptyByteString)
        && let
             deadline =
               case mdStatus old of
                 MilestonePending -> mdSubmitDeadline old
                 MilestoneNeedsRevision _ -> mdRevisionDeadline old
                 _ -> traceError "M9"
           in
                traceIfFalse "M7" (beforeDeadline info deadline)
             && requireMilestoneContinuing ctx
                  (old { mdStatus = MilestoneSubmitted subHash })

      MClientReject ->
           traceIfFalse "M10" (signedBy info (mdClient old))
        && traceIfFalse "M11" (beforeDeadline info (mdReviewDeadline old))
        && case mdStatus old of
             MilestoneSubmitted h ->
                  traceIfFalse "M12" (mdRevisionCount old < mdMaxRevisions old)
               && requireMilestoneContinuing ctx
                    (old
                      { mdStatus = MilestoneNeedsRevision h
                      , mdRevisionCount = mdRevisionCount old + 1
                      }
                    )
             _ -> traceError "M13"

      MExtendDeadlines s r rv d ->
           traceIfFalse "M14" (signedBy info (mdClient old) && signedBy info (mdFreelancer old))
        && traceIfFalse "M15" (not (mdExtensionUsed old))
        && traceIfFalse "M16" (validExtensionOrdering s r rv d)
        && traceIfFalse "M17" (extensionMovesForward old s r rv d)
        && traceIfFalse "M18" (extensionReactivates old info s r rv)
        && requireMilestoneContinuing ctx
             (old
               { mdSubmitDeadline = s
               , mdReviewDeadline = r
               , mdRevisionDeadline = rv
               , mdDisputeDeadline = d
               , mdExtensionUsed = True
               }
             )

      MClientAccept ->
           traceIfFalse "M19" (signedBy info (mdClient old))
        && traceIfFalse "M20" (projectInputPresent info old)
        && case mdStatus old of
             MilestoneSubmitted _ ->
                  closeMilestoneWithNoContinuing ctx
               && traceIfFalse "M21" (valuePaidToPkh info (mdFreelancer old) >= freelancerNet)
               && traceIfFalse "M22" (valuePaidToPkh info (mdPlatform old) >= platformFee)
             _ -> traceError "M23"

      MClientRefundAfterMissedDeadline ->
           traceIfFalse "M24" (signedBy info (mdClient old))
        && traceIfFalse "M25" (projectInputPresent info old)
        && let
             deadline =
               case mdStatus old of
                 MilestonePending -> mdSubmitDeadline old
                 MilestoneNeedsRevision _ -> mdRevisionDeadline old
                 _ -> traceError "M30"
           in
                traceIfFalse "M26" (afterDeadline info deadline)
             && closeMilestoneWithNoContinuing ctx
             && traceIfFalse "M27" (valuePaidToPkh info (mdClient old) >= mdAmount old)

      MFreelancerClaimAfterReviewTimeout ->
           traceIfFalse "M31" (signedBy info (mdFreelancer old))
        && traceIfFalse "M32" (projectInputPresent info old)
        && traceIfFalse "M33" (afterDeadline info (mdReviewDeadline old))
        && case mdStatus old of
             MilestoneSubmitted _ ->
                  closeMilestoneWithNoContinuing ctx
               && traceIfFalse "M34" (valuePaidToPkh info (mdFreelancer old) >= freelancerNet)
               && traceIfFalse "M35" (valuePaidToPkh info (mdPlatform old) >= platformFee)
             _ -> traceError "M36"

      MRaiseDispute ->
           traceIfFalse "M37" (signedBy info (mdClient old) || signedBy info (mdFreelancer old))
        && case mdStatus old of
             MilestoneSubmitted h ->
                  traceIfFalse "M38" (beforeDeadline info (mdReviewDeadline old))
               && closeMilestoneWithNoContinuing ctx
               && traceIfFalse "M39" (disputeOutputCreated info old h)

             MilestoneNeedsRevision h ->
                  traceIfFalse "M38" (beforeDeadline info (mdRevisionDeadline old))
               && closeMilestoneWithNoContinuing ctx
               && traceIfFalse "M39" (disputeOutputCreated info old h)

             _ -> traceError "M42"
             
--------------------------------------------------------------------------------
-- Boilerplate
--------------------------------------------------------------------------------

{-# INLINABLE mkWrapped #-}
mkWrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
mkWrapped d r c =
  check $
    mkMilestoneValidator
      (unsafeFromBuiltinData d)
      (unsafeFromBuiltinData r)
      (unsafeFromBuiltinData c)

validator :: Validator
validator = mkValidatorScript $$(PlutusTx.compile [|| mkWrapped ||])

script :: PlutusV2.Script
script = unValidatorScript validator

--------------------------------------------------------------------------------
-- Serialisation / export
--------------------------------------------------------------------------------

serialiseToCBOR :: Validator -> LBS.ByteString
serialiseToCBOR v = Serialise.serialise (unValidatorScript v)

serialiseToCBORBytes :: Validator -> BS.ByteString
serialiseToCBORBytes = LBS.toStrict . serialiseToCBOR

writeValidatorEnvelope :: H.FilePath -> Validator -> H.IO ()
writeValidatorEnvelope fp v = do
  let cbor = serialiseToCBORBytes v
      hex  = B16.encode cbor
      json = LBS.fromStrict $
        C8.concat
          [ C8.pack "{\n  \"type\": \"PlutusScriptV2\",\n  \"description\": \"Milestone Validator\",\n  \"cborHex\": \""
          , hex
          , C8.pack "\"\n}\n"
          ]
  LBS.writeFile fp json

exportMilestoneScript :: H.IO ()
exportMilestoneScript =
  writeValidatorEnvelope "./assets/milestone-validator.plutus" validator

-- Error index:
-- M1 continuing milestone datum mismatch
-- M2 continuing milestone value changed
-- M3 invalid milestone datum
-- M4 milestone underfunded
-- M5 freelancer signature missing
-- M6 empty submission hash
-- M7 submit deadline passed
-- M8 revision deadline passed
-- M9 milestone cannot submit
-- M10 client signature missing for rejection
-- M11 review deadline passed
-- M12 max revisions reached
-- M13 milestone not submitted
-- M14 extension requires client and freelancer
-- M15 extension already used
-- M16 invalid extension ordering
-- M17 extension did not move forward
-- M18 extension does not reactivate current state
-- M19 client signature missing for accept
-- M20 project input missing
-- M21 freelancer underpaid
-- M22 platform underpaid
-- M23 milestone not submitted
-- M24 client signature missing for refund
-- M25 project input missing for refund
-- M26 submit deadline not passed
-- M27 client underpaid from pending refund
-- M28 revision deadline not passed
-- M29 client underpaid from revision refund
-- M30 invalid refund state
-- M31 freelancer signature missing for timeout claim
-- M32 project input missing for timeout claim
-- M33 review deadline not passed
-- M34 freelancer underpaid on timeout claim
-- M35 platform underpaid on timeout claim
-- M36 milestone not submitted
-- M37 client/freelancer signature missing for dispute
-- M38 review deadline passed for dispute
-- M39 dispute output missing from submitted
-- M40 revision deadline passed for dispute
-- M41 dispute output missing from revision
-- M42 invalid dispute state
