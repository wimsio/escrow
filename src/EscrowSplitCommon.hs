{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module EscrowSplitCommon where

import Plutus.V1.Ledger.Value
  ( CurrencySymbol(..)
  , TokenName(..)
  , Value
  , adaSymbol
  , adaToken
  , valueOf
  )
import qualified Plutus.V2.Ledger.Api as PlutusV2
import Plutus.V2.Ledger.Contexts
  ( findOwnInput
  , getContinuingOutputs
  , txSignedBy
  )
import qualified PlutusTx
import PlutusTx.Prelude as P hiding (Semigroup(..))

import EscrowSplitTypes

--------------------------------------------------------------------------------
-- Small shared helpers
--------------------------------------------------------------------------------

{-# INLINABLE lovelaceOf #-}
lovelaceOf :: Value -> Integer
lovelaceOf v = valueOf v adaSymbol adaToken

{-# INLINABLE assetCount #-}
assetCount :: Value -> CurrencySymbol -> TokenName -> Integer
assetCount v cs tn = valueOf v cs tn

{-# INLINABLE feeOf #-}
feeOf :: Integer -> Integer -> Integer
feeOf amount rate = divide (amount * rate) 10000

{-# INLINABLE signedBy #-}
signedBy :: PlutusV2.TxInfo -> PlutusV2.PubKeyHash -> Bool
signedBy info pkh = txSignedBy info pkh

{-# INLINABLE valuePaidToPkh #-}
valuePaidToPkh :: PlutusV2.TxInfo -> PlutusV2.PubKeyHash -> Integer
valuePaidToPkh info pkh =
  P.foldr
    (\o acc ->
      case PlutusV2.addressCredential (PlutusV2.txOutAddress o) of
        PlutusV2.PubKeyCredential pkh' ->
          if pkh' == pkh
            then acc + lovelaceOf (PlutusV2.txOutValue o)
            else acc
        _ -> acc
    )
    0
    (PlutusV2.txInfoOutputs info)

{-# INLINABLE tokenPaidToPkh #-}
tokenPaidToPkh ::
  PlutusV2.TxInfo ->
  PlutusV2.PubKeyHash ->
  CurrencySymbol ->
  TokenName ->
  Integer
tokenPaidToPkh info pkh cs tn =
  P.foldr
    (\o acc ->
      case PlutusV2.addressCredential (PlutusV2.txOutAddress o) of
        PlutusV2.PubKeyCredential pkh' ->
          if pkh' == pkh
            then acc + valueOf (PlutusV2.txOutValue o) cs tn
            else acc
        _ -> acc
    )
    0
    (PlutusV2.txInfoOutputs info)

--------------------------------------------------------------------------------
-- Time helpers
--------------------------------------------------------------------------------

{-# INLINABLE fromLowerBound #-}
fromLowerBound :: PlutusV2.POSIXTimeRange -> PlutusV2.POSIXTime
fromLowerBound rng =
  case PlutusV2.ivFrom rng of
    PlutusV2.LowerBound (PlutusV2.Finite t) _ -> t
    _ -> traceError "E1"

{-# INLINABLE toUpperBound #-}
toUpperBound :: PlutusV2.POSIXTimeRange -> PlutusV2.POSIXTime
toUpperBound rng =
  case PlutusV2.ivTo rng of
    PlutusV2.UpperBound (PlutusV2.Finite t) _ -> t
    _ -> traceError "E2"

{-# INLINABLE beforeDeadline #-}
beforeDeadline :: PlutusV2.TxInfo -> PlutusV2.POSIXTime -> Bool
beforeDeadline info dl = toUpperBound (PlutusV2.txInfoValidRange info) <= dl

{-# INLINABLE afterDeadline #-}
afterDeadline :: PlutusV2.TxInfo -> PlutusV2.POSIXTime -> Bool
afterDeadline info dl = fromLowerBound (PlutusV2.txInfoValidRange info) >= dl

--------------------------------------------------------------------------------
-- Tx / datum helpers
--------------------------------------------------------------------------------

{-# INLINABLE findOwnInputOrFail #-}
findOwnInputOrFail :: PlutusV2.ScriptContext -> PlutusV2.TxOut
findOwnInputOrFail ctx =
  case findOwnInput ctx of
    Nothing -> traceError "E3"
    Just i  -> PlutusV2.txInInfoResolved i

{-# INLINABLE getSingleContinuingOutput #-}
getSingleContinuingOutput :: PlutusV2.ScriptContext -> PlutusV2.TxOut
getSingleContinuingOutput ctx =
  case getContinuingOutputs ctx of
    [o] -> o
    _   -> traceError "E4"

{-# INLINABLE assertNoContinuingOutput #-}
assertNoContinuingOutput :: PlutusV2.ScriptContext -> ()
assertNoContinuingOutput ctx =
  case getContinuingOutputs ctx of
    [] -> ()
    _  -> traceError "E5"

{-# INLINABLE datumMatches #-}
datumMatches :: PlutusTx.ToData a => a -> PlutusV2.TxOut -> Bool
datumMatches expected outRef =
  case PlutusV2.txOutDatum outRef of
    PlutusV2.OutputDatum (PlutusV2.Datum d) ->
      d == PlutusTx.toBuiltinData expected
    _ -> False

{-# INLINABLE decodeProjectDatum #-}
decodeProjectDatum :: PlutusV2.TxOut -> Maybe ProjectDatum
decodeProjectDatum outRef =
  case PlutusV2.txOutDatum outRef of
    PlutusV2.OutputDatum (PlutusV2.Datum d) -> PlutusTx.fromBuiltinData d
    _ -> Nothing

{-# INLINABLE decodeMilestoneDatum #-}
decodeMilestoneDatum :: PlutusV2.TxOut -> Maybe MilestoneDatum
decodeMilestoneDatum outRef =
  case PlutusV2.txOutDatum outRef of
    PlutusV2.OutputDatum (PlutusV2.Datum d) -> PlutusTx.fromBuiltinData d
    _ -> Nothing

{-# INLINABLE decodeDisputeDatum #-}
decodeDisputeDatum :: PlutusV2.TxOut -> Maybe DisputeDatum
decodeDisputeDatum outRef =
  case PlutusV2.txOutDatum outRef of
    PlutusV2.OutputDatum (PlutusV2.Datum d) -> PlutusTx.fromBuiltinData d
    _ -> Nothing

{-# INLINABLE scriptHashOfOutput #-}
scriptHashOfOutput :: PlutusV2.TxOut -> Maybe PlutusV2.ValidatorHash
scriptHashOfOutput outRef =
  case PlutusV2.addressCredential (PlutusV2.txOutAddress outRef) of
    PlutusV2.ScriptCredential h -> Just h
    _ -> Nothing

{-# INLINABLE isOutputAtScript #-}
isOutputAtScript :: PlutusV2.ValidatorHash -> PlutusV2.TxOut -> Bool
isOutputAtScript vh outRef =
  case scriptHashOfOutput outRef of
    Just h -> h == vh
    Nothing -> False

{-# INLINABLE countOutputsAtScriptWithDatum #-}
countOutputsAtScriptWithDatum :: PlutusTx.ToData a => PlutusV2.TxInfo -> PlutusV2.ValidatorHash -> a -> Integer
countOutputsAtScriptWithDatum info vh expected =
  P.foldr
    (\o acc -> if isOutputAtScript vh o && datumMatches expected o then acc + 1 else acc)
    0
    (PlutusV2.txInfoOutputs info)

{-# INLINABLE hasInputFromScript #-}
hasInputFromScript :: PlutusV2.TxInfo -> PlutusV2.ValidatorHash -> Bool
hasInputFromScript info vh =
  P.foldr
    (\i acc -> acc || isOutputAtScript vh (PlutusV2.txInInfoResolved i))
    False
    (PlutusV2.txInfoInputs info)

--------------------------------------------------------------------------------
-- List helpers
--------------------------------------------------------------------------------

{-# INLINABLE countPkhList #-}
countPkhList :: [PlutusV2.PubKeyHash] -> Integer
countPkhList xs =
  case xs of
    [] -> 0
    _ : rest -> 1 + countPkhList rest

{-# INLINABLE containsPkh #-}
containsPkh :: PlutusV2.PubKeyHash -> [PlutusV2.PubKeyHash] -> Bool
containsPkh p xs =
  case xs of
    [] -> False
    x : rest -> if p == x then True else containsPkh p rest

{-# INLINABLE noDuplicatePkhs #-}
noDuplicatePkhs :: [PlutusV2.PubKeyHash] -> Bool
noDuplicatePkhs xs =
  case xs of
    [] -> True
    x : rest -> if containsPkh x rest then False else noDuplicatePkhs rest

{-# INLINABLE getMilestoneTerms #-}
getMilestoneTerms :: Integer -> [MilestoneTerms] -> Maybe MilestoneTerms
getMilestoneTerms i xs =
  if i < 0 then Nothing else go i xs
  where
    go n ys =
      case ys of
        [] -> Nothing
        z : zs -> if n == 0 then Just z else go (n - 1) zs

{-# INLINABLE hasMilestoneTerms #-}
hasMilestoneTerms :: Integer -> [MilestoneTerms] -> Bool
hasMilestoneTerms i xs =
  case getMilestoneTerms i xs of
    Just _ -> True
    Nothing -> False

{-# INLINABLE sumMilestoneAmounts #-}
sumMilestoneAmounts :: [MilestoneTerms] -> Integer
sumMilestoneAmounts xs =
  case xs of
    [] -> 0
    m : rest -> mtAmount m + sumMilestoneAmounts rest

{-# INLINABLE validTerms #-}
validTerms :: MilestoneTerms -> Bool
validTerms m =
     mtAmount m > 0
  && mtSubmitDeadline m <= mtReviewDeadline m
  && mtReviewDeadline m <= mtRevisionDeadline m
  && mtRevisionDeadline m <= mtDisputeDeadline m

{-# INLINABLE validParties #-}
validParties :: PlutusV2.PubKeyHash -> PlutusV2.PubKeyHash -> PlutusV2.PubKeyHash -> [PlutusV2.PubKeyHash] -> Bool
validParties cl fr pf rs =
     cl /= fr
  && cl /= pf
  && fr /= pf
  && countPkhList rs == 3
  && noDuplicatePkhs rs
  && not (containsPkh cl rs)
  && not (containsPkh fr rs)
  && not (containsPkh pf rs)

{-# INLINABLE reviewerSignedCount #-}
reviewerSignedCount :: PlutusV2.TxInfo -> [PlutusV2.PubKeyHash] -> Integer
reviewerSignedCount info rs =
  P.foldr (\r acc -> if txSignedBy info r then acc + 1 else acc) 0 rs

{-# INLINABLE reviewerQuorum2 #-}
reviewerQuorum2 :: PlutusV2.TxInfo -> [PlutusV2.PubKeyHash] -> Bool
reviewerQuorum2 info rs = reviewerSignedCount info rs >= 2

{-# INLINABLE signedReviewerPaid #-}
signedReviewerPaid :: PlutusV2.TxInfo -> PlutusV2.PubKeyHash -> Integer -> Bool
signedReviewerPaid info reviewer amountEach =
  if txSignedBy info reviewer
    then valuePaidToPkh info reviewer >= amountEach
    else True

{-# INLINABLE signedReviewersPaid #-}
signedReviewersPaid :: PlutusV2.TxInfo -> [PlutusV2.PubKeyHash] -> Integer -> Bool
signedReviewersPaid info rs amountEach =
  case rs of
    [] -> True
    r : rest -> signedReviewerPaid info r amountEach && signedReviewersPaid info rest amountEach

--------------------------------------------------------------------------------
-- Thread token helpers
--------------------------------------------------------------------------------

{-# INLINABLE validThreadToken #-}
validThreadToken :: CurrencySymbol -> TokenName -> Bool
validThreadToken cs tn = not (cs == adaSymbol && tn == adaToken)

{-# INLINABLE threadPreserved #-}
threadPreserved :: PlutusV2.TxOut -> PlutusV2.TxOut -> CurrencySymbol -> TokenName -> Bool
threadPreserved inRef outRef cs tn =
     assetCount (PlutusV2.txOutValue inRef) cs tn == 1
  && assetCount (PlutusV2.txOutValue outRef) cs tn == 1

{-# INLINABLE threadReturned #-}
threadReturned :: PlutusV2.TxInfo -> PlutusV2.PubKeyHash -> PlutusV2.PubKeyHash -> CurrencySymbol -> TokenName -> Bool
threadReturned info cl pf cs tn =
     tokenPaidToPkh info cl cs tn == 1
  || tokenPaidToPkh info pf cs tn == 1
