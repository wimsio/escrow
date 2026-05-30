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

module ProjectEscrowValidator where

import qualified Prelude as H

import Plutus.V1.Ledger.Value (Value)
import qualified Plutus.V2.Ledger.Api as PlutusV2
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , Validator
  , mkValidatorScript
  , unValidatorScript
  )
import qualified PlutusTx
import PlutusTx (compile, unsafeFromBuiltinData)
import PlutusTx.Prelude as P hiding (Semigroup(..))

import qualified Codec.Serialise        as Serialise
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8  as C8
import qualified Data.ByteString.Lazy   as LBS

import EscrowSplitTypes
import EscrowSplitCommon

--------------------------------------------------------------------------------
-- Project helpers
--------------------------------------------------------------------------------

{-# INLINABLE isAwaiting #-}
isAwaiting :: ProjectStatus -> Bool
isAwaiting s =
  case s of
    ProjectAwaitingFreelancer -> True
    _ -> False

{-# INLINABLE isActiveProject #-}
isActiveProject :: ProjectStatus -> Bool
isActiveProject s =
  case s of
    ProjectActive -> True
    _ -> False

{-# INLINABLE validProjectDatum #-}
validProjectDatum :: ProjectDatum -> Bool
validProjectDatum d =
     pdPlatformFeeRate d > 0
  && pdPlatformFeeRate d <= 10000
  && pdReviewerFeeRate d > 0
  && pdReviewerFeeRate d <= 10000
  && pdPlatformFeeRate d + pdReviewerFeeRate d <= 10000
  && pdMaxRevisions d >= 0
  && pdCurrentIndex d >= 0
  && hasMilestoneTerms (pdCurrentIndex d) (pdMilestones d)
  && validParties (pdClient d) (pdFreelancer d) (pdPlatform d) (pdReviewers d)
  && validThreadToken (pdProjectThreadCs d) (pdProjectThreadTn d)

{-# INLINABLE termToMilestoneDatum #-}
termToMilestoneDatum :: ProjectDatum -> Integer -> MilestoneTerms -> MilestoneDatum
termToMilestoneDatum p idx mt =
  MilestoneDatum
    { mdProjectId            = pdProjectId p
    , mdIndex                = idx
    , mdClient               = pdClient p
    , mdFreelancer           = pdFreelancer p
    , mdReviewers            = pdReviewers p
    , mdPlatform             = pdPlatform p
    , mdPlatformFeeRate      = pdPlatformFeeRate p
    , mdReviewerFeeRate      = pdReviewerFeeRate p
    , mdMaxRevisions         = pdMaxRevisions p
    , mdSubmitDeadline       = mtSubmitDeadline mt
    , mdReviewDeadline       = mtReviewDeadline mt
    , mdRevisionDeadline     = mtRevisionDeadline mt
    , mdDisputeDeadline      = mtDisputeDeadline mt
    , mdAmount               = mtAmount mt
    , mdStatus               = MilestonePending
    , mdRevisionCount        = 0
    , mdExtensionUsed        = False
    , mdProjectValidatorHash = pdProjectValidatorHash p
    , mdDisputeValidatorHash = pdDisputeValidatorHash p
    }

{-# INLINABLE milestoneOutputCreated #-}
milestoneOutputCreated :: PlutusV2.TxInfo -> ProjectDatum -> Integer -> MilestoneTerms -> Bool
milestoneOutputCreated info p idx mt =
  let
    md = termToMilestoneDatum p idx mt
    vh = pdMilestoneValidatorHash p

    count =
      P.foldr
        (\o acc ->
          if    isOutputAtScript vh o
             && datumMatches md o
             && lovelaceOf (PlutusV2.txOutValue o) == mtAmount mt
          then acc + 1
          else acc
        )
        0
        (PlutusV2.txInfoOutputs info)
  in
    count == 1

{-# INLINABLE matchingMilestoneInput #-}
matchingMilestoneInput :: PlutusV2.TxInfo -> ProjectDatum -> Integer -> Integer -> Bool
matchingMilestoneInput info p idx amt =
  P.foldr
    (\i acc ->
      let o = PlutusV2.txInInfoResolved i
      in acc ||
          (    isOutputAtScript (pdMilestoneValidatorHash p) o
            && lovelaceOf (PlutusV2.txOutValue o) >= amt
            && case decodeMilestoneDatum o of
                 Just md ->
                      mdProjectId md == pdProjectId p
                   && mdIndex md == idx
                   && mdAmount md == amt
                 Nothing -> False
          )
    )
    False
    (PlutusV2.txInfoInputs info)

{-# INLINABLE matchingDisputeInput #-}
matchingDisputeInput :: PlutusV2.TxInfo -> ProjectDatum -> Integer -> Integer -> Bool
matchingDisputeInput info p idx amt =
  P.foldr
    (\i acc ->
      let o = PlutusV2.txInInfoResolved i
      in acc ||
          (    isOutputAtScript (pdDisputeValidatorHash p) o
            && lovelaceOf (PlutusV2.txOutValue o) >= amt
            && case decodeDisputeDatum o of
                 Just dd ->
                      ddProjectId dd == pdProjectId p
                   && ddIndex dd == idx
                   && ddClient dd == pdClient p
                   && ddAmount dd == amt
                 Nothing -> False
          )
    )
    False
    (PlutusV2.txInfoInputs info)

{-# INLINABLE requireProjectContinuing #-}
requireProjectContinuing :: PlutusV2.ScriptContext -> ProjectDatum -> ProjectDatum -> Integer -> Bool
requireProjectContinuing ctx old expected releasedAda =
  let
    inRef = findOwnInputOrFail ctx
    outRef = getSingleContinuingOutput ctx
    adaIn = lovelaceOf (PlutusV2.txOutValue inRef)
    adaOut = lovelaceOf (PlutusV2.txOutValue outRef)
    minExpectedAda = adaIn - releasedAda
  in
       traceIfFalse "P1" (releasedAda >= 0)
    && traceIfFalse "P2" (releasedAda <= adaIn)
    && traceIfFalse "P3" (datumMatches expected outRef)
    && traceIfFalse "P4" (adaOut >= minExpectedAda)
    && traceIfFalse "P5" (threadPreserved inRef outRef (pdProjectThreadCs old) (pdProjectThreadTn old))

{-# INLINABLE closeProjectToClient #-}
closeProjectToClient :: PlutusV2.ScriptContext -> ProjectDatum -> Integer -> Bool
closeProjectToClient ctx old minClientAda =
  let info = PlutusV2.scriptContextTxInfo ctx
  in
    case assertNoContinuingOutput ctx of
      () ->
           traceIfFalse "P6" (valuePaidToPkh info (pdClient old) >= minClientAda)
        && traceIfFalse "P7" (threadReturned info (pdClient old) (pdPlatform old) (pdProjectThreadCs old) (pdProjectThreadTn old))

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------

{-# INLINABLE mkProjectValidator #-}
mkProjectValidator :: ProjectDatum -> ProjectAction -> PlutusV2.ScriptContext -> Bool
mkProjectValidator old action ctx =
  let
    info = PlutusV2.scriptContextTxInfo ctx
    inRef = findOwnInputOrFail ctx
    adaIn = lovelaceOf (PlutusV2.txOutValue inRef)
    idx = pdCurrentIndex old
    currentTerms =
      case getMilestoneTerms idx (pdMilestones old) of
        Just mt -> mt
        Nothing -> traceError "P8"
    currentAmount = mtAmount currentTerms
    nextIdx = idx + 1
    inputFromCurrentWork =
         matchingMilestoneInput info old idx currentAmount
      || matchingDisputeInput info old idx currentAmount
  in
       traceIfFalse "P9" (validProjectDatum old)
    && traceIfFalse "P10" (assetCount (PlutusV2.txOutValue inRef) (pdProjectThreadCs old) (pdProjectThreadTn old) == 1)
    && case action of

      PFreelancerAccept ->
           traceIfFalse "P11" (isAwaiting (pdStatus old))
        && traceIfFalse "P12" (signedBy info (pdFreelancer old))
        && traceIfFalse "P13" (beforeDeadline info (pdAcceptDeadline old))
        && traceIfFalse "P14" (validTerms currentTerms)
        && traceIfFalse "P15" (milestoneOutputCreated info old idx currentTerms)
        && requireProjectContinuing
             ctx
             old
             (old { pdStatus = ProjectActive })
             currentAmount

      PCancelBeforeAcceptance ->
           traceIfFalse "P16" (isAwaiting (pdStatus old))
        && traceIfFalse "P17" (signedBy info (pdClient old))
        && closeProjectToClient ctx old adaIn

      PAdvanceAfterMilestone ->
           traceIfFalse "P18" (isActiveProject (pdStatus old))
        && traceIfFalse "P19" inputFromCurrentWork
        && if hasMilestoneTerms nextIdx (pdMilestones old)
             then
               let
                 nextTerms =
                   case getMilestoneTerms nextIdx (pdMilestones old) of
                     Just mt -> mt
                     Nothing -> traceError "P20"
                 expected = old { pdCurrentIndex = nextIdx }
               in
                    traceIfFalse "P21" (validTerms nextTerms)
                 && traceIfFalse "P22" (milestoneOutputCreated info old nextIdx nextTerms)
                 && requireProjectContinuing ctx old expected (mtAmount nextTerms)
             else
               closeProjectToClient ctx old adaIn

      PCloseToClient ->
           traceIfFalse "P23" (isActiveProject (pdStatus old))
        && traceIfFalse "P24" inputFromCurrentWork
        && closeProjectToClient ctx old adaIn

--------------------------------------------------------------------------------
-- Boilerplate
--------------------------------------------------------------------------------

{-# INLINABLE mkWrapped #-}
mkWrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
mkWrapped d r c =
  check $
    mkProjectValidator
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
          [ C8.pack "{\n  \"type\": \"PlutusScriptV2\",\n  \"description\": \"Project Escrow Validator\",\n  \"cborHex\": \""
          , hex
          , C8.pack "\"\n}\n"
          ]
  LBS.writeFile fp json

exportProjectScript :: H.IO ()
exportProjectScript =
  writeValidatorEnvelope "./assets/project-escrow-validator.plutus" validator

-- Error index:
-- P1 released ADA negative
-- P2 released ADA too large
-- P3 continuing project datum mismatch
-- P4 wrong remaining project ADA
-- P5 project thread token not preserved
-- P6 client underpaid
-- P7 project thread token not returned
-- P8 invalid current milestone index
-- P9 invalid project datum
-- P10 project thread token missing from input
-- P11 project not awaiting freelancer
-- P12 freelancer signature missing
-- P13 acceptance deadline passed
-- P14 invalid current milestone terms
-- P15 milestone output not created correctly
-- P16 project not awaiting cancellation
-- P17 client signature missing
-- P18 project not active
-- P19 matching milestone/dispute input missing
-- P20 invalid next milestone index
-- P21 invalid next milestone terms
-- P22 next milestone output not created correctly
-- P23 project not active for close-to-client
-- P24 matching work/dispute input missing for close-to-client
