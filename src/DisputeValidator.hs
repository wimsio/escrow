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

module DisputeValidator where

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
import PlutusTx.Prelude as P hiding (Semigroup(..))

import qualified Codec.Serialise        as Serialise
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8  as C8
import qualified Data.ByteString.Lazy   as LBS

import EscrowSplitTypes
import EscrowSplitCommon

--------------------------------------------------------------------------------
-- Dispute helpers
--------------------------------------------------------------------------------

{-# INLINABLE validDisputeDatum #-}
validDisputeDatum :: DisputeDatum -> Bool
validDisputeDatum d =
     ddAmount d > 0
  && ddPlatformFeeRate d > 0
  && ddPlatformFeeRate d <= 10000
  && ddReviewerFeeRate d > 0
  && ddReviewerFeeRate d <= 10000
  && ddPlatformFeeRate d + ddReviewerFeeRate d <= 10000

{-# INLINABLE platformFeeOfDispute #-}
platformFeeOfDispute :: DisputeDatum -> Integer
platformFeeOfDispute d = feeOf (ddAmount d) (ddPlatformFeeRate d)

{-# INLINABLE reviewerFeePoolOfDispute #-}
reviewerFeePoolOfDispute :: DisputeDatum -> Integer
reviewerFeePoolOfDispute d = feeOf (ddAmount d) (ddReviewerFeeRate d)

{-# INLINABLE matchingProjectInputPresentD #-}
matchingProjectInputPresentD :: PlutusV2.TxInfo -> DisputeDatum -> Bool
matchingProjectInputPresentD info d =
  P.foldr
    (\i acc ->
      let o = PlutusV2.txInInfoResolved i
      in acc ||
          (    isOutputAtScript (ddProjectValidatorHash d) o
            && case decodeProjectDatum o of
                 Just pd ->
                      pdProjectId pd == ddProjectId d
                   && pdCurrentIndex pd == ddIndex d
                   && pdClient pd == ddClient d
                   && pdFreelancer pd == ddFreelancer d
                 Nothing -> False
          )
    )
    False
    (PlutusV2.txInfoInputs info)

{-# INLINABLE closeDispute #-}
closeDispute :: PlutusV2.ScriptContext -> Bool
closeDispute ctx =
  case assertNoContinuingOutput ctx of
    () -> True

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------

{-# INLINABLE mkDisputeValidator #-}
mkDisputeValidator :: DisputeDatum -> DisputeAction -> PlutusV2.ScriptContext -> Bool
mkDisputeValidator old action ctx =
  let
    info = PlutusV2.scriptContextTxInfo ctx
    platformFee = platformFeeOfDispute old
    reviewerFeePool = reviewerFeePoolOfDispute old
    reviewerFeeEach = divide reviewerFeePool 2
    freelancerNet = ddAmount old - platformFee - reviewerFeePool
    freelancerSplit = divide (ddAmount old) 2
    clientSplit = ddAmount old - freelancerSplit
  in
       traceIfFalse "D1" (validDisputeDatum old)
    && traceIfFalse "D2" (lovelaceOf (PlutusV2.txOutValue (findOwnInputOrFail ctx)) >= ddAmount old)
    && traceIfFalse "D3" (matchingProjectInputPresentD info old)
    && case action of

      DResolveToFreelancer ->
           traceIfFalse "D4" (reviewerSignedCount info (ddReviewers old) == 2)
        && traceIfFalse "D5" (reviewerFeeEach > 0)
        && traceIfFalse "D6" (beforeDeadline info (ddDisputeDeadline old))
        && closeDispute ctx
        && traceIfFalse "D7" (signedReviewersPaid info (ddReviewers old) reviewerFeeEach)
        && traceIfFalse "D8" (valuePaidToPkh info (ddFreelancer old) >= freelancerNet)
        && traceIfFalse "D9" (valuePaidToPkh info (ddPlatform old) >= platformFee)

      DResolveToClient ->
           traceIfFalse "D10" (reviewerSignedCount info (ddReviewers old) == 2)
        && traceIfFalse "D11" (reviewerFeeEach > 0)
        && traceIfFalse "D12" (beforeDeadline info (ddDisputeDeadline old))
        && closeDispute ctx
        && traceIfFalse "D13" (signedReviewersPaid info (ddReviewers old) reviewerFeeEach)
        && traceIfFalse "D14" (valuePaidToPkh info (ddClient old) >= ddAmount old - reviewerFeePool)

      DSplitAfterTimeout ->
           traceIfFalse "D15" (signedBy info (ddClient old) || signedBy info (ddFreelancer old))
        && traceIfFalse "D16" (afterDeadline info (ddDisputeDeadline old))
        && closeDispute ctx
        && traceIfFalse "D17" (valuePaidToPkh info (ddFreelancer old) >= freelancerSplit)
        && traceIfFalse "D18" (valuePaidToPkh info (ddClient old) >= clientSplit)

--------------------------------------------------------------------------------
-- Boilerplate
--------------------------------------------------------------------------------

{-# INLINABLE mkWrapped #-}
mkWrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
mkWrapped d r c =
  check $
    mkDisputeValidator
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
          [ C8.pack "{\n  \"type\": \"PlutusScriptV2\",\n  \"description\": \"Dispute Validator\",\n  \"cborHex\": \""
          , hex
          , C8.pack "\"\n}\n"
          ]
  LBS.writeFile fp json

exportDisputeScript :: H.IO ()
exportDisputeScript =
  writeValidatorEnvelope "./assets/dispute-validator.plutus" validator

-- Error index:
-- D1 invalid dispute datum
-- D2 dispute underfunded
-- D3 project input missing
-- D4 exactly two reviewer signatures required for freelancer resolution
-- D5 reviewer fee invalid
-- D6 dispute deadline passed
-- D7 signed reviewers underpaid
-- D8 freelancer underpaid
-- D9 platform underpaid
-- D10 exactly two reviewer signatures required for client resolution
-- D11 reviewer fee invalid
-- D12 dispute deadline passed
-- D13 signed reviewers underpaid
-- D14 client underpaid
-- D15 client/freelancer signature missing for timeout split
-- D16 dispute deadline not passed
-- D17 freelancer split underpaid
-- D18 client split underpaid
