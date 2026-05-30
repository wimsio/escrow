{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NumericUnderscores #-}

module EscrowV3 where

import qualified Prelude as H

import GHC.Generics (Generic)

import Plutus.V1.Ledger.Value
  ( CurrencySymbol(..)
  , TokenName(..)
  , Value
  , adaSymbol
  , adaToken
  , valueOf
  )

import qualified Plutus.V2.Ledger.Api as PlutusV2
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , Validator
  , mkValidatorScript
  , unValidatorScript
  )

import Plutus.V2.Ledger.Contexts
  ( findOwnInput
  , getContinuingOutputs
  , txSignedBy
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

--------------------------------------------------------------------------------
-- On-chain types
--------------------------------------------------------------------------------

data EscrowStatus
  = AwaitingFreelancer
  | Active
  | InDispute
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''EscrowStatus
PlutusTx.makeLift ''EscrowStatus

data MilestoneStatus
  = Pending
  | Submitted BuiltinByteString
  | NeedsRevision BuiltinByteString
  | Accepted
  | Disputed
  | ResolvedToFreelancer
  | ResolvedToClient
  | TimedOutSplit
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''MilestoneStatus
PlutusTx.makeLift ''MilestoneStatus

data Milestone = Milestone
  { submitDeadline  :: PlutusV2.POSIXTime
  , reviewDeadline  :: PlutusV2.POSIXTime
  , revisionDeadline :: PlutusV2.POSIXTime
  , disputeDeadline :: PlutusV2.POSIXTime
  , milestoneAmount :: Integer
  , milestoneStatus :: MilestoneStatus
  , revisionCount   :: Integer
  , extensionUsed   :: Bool
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''Milestone
PlutusTx.makeLift ''Milestone

data EscrowDatum = EscrowDatum
  { projectId       :: Integer
  , client          :: PlutusV2.PubKeyHash
  , freelancer      :: PlutusV2.PubKeyHash
  , reviewers       :: [PlutusV2.PubKeyHash]
  , platform        :: PlutusV2.PubKeyHash
  , platformFeeRate :: Integer
  , reviewerFeeRate :: Integer
  , acceptDeadline  :: PlutusV2.POSIXTime
  , milestones      :: [Milestone]
  , currentIndex    :: Integer
  , maxRevisions    :: Integer
  , escrowStatus    :: EscrowStatus
  , threadCs        :: CurrencySymbol
  , threadTn        :: TokenName
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''EscrowDatum
PlutusTx.makeLift ''EscrowDatum

data EscrowAction
  = FreelancerAccept
  | ClientCancelBeforeAcceptance
  | ExtendMilestoneDeadlines
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
  | SubmitWork BuiltinByteString
  | ClientAcceptMilestone
  | ClientRejectMilestone
  | RaiseDispute
  | ResolveToFreelancer
  | ResolveToClient
  | ClientRefundAfterMissedDeadline
  | FreelancerClaimAfterReviewTimeout
  | SplitAfterDisputeTimeout
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''EscrowAction
PlutusTx.makeLift ''EscrowAction

--------------------------------------------------------------------------------
-- Basic helpers
--------------------------------------------------------------------------------

{-# INLINABLE lovelaceOf #-}
lovelaceOf :: Value -> Integer
lovelaceOf v = valueOf v adaSymbol adaToken

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

{-# INLINABLE assetCount #-}
assetCount :: Value -> CurrencySymbol -> TokenName -> Integer
assetCount v cs tn = valueOf v cs tn

{-# INLINABLE feeOf #-}
feeOf :: Integer -> Integer -> Integer
feeOf amount rate =
  divide (amount * rate) 10000

--------------------------------------------------------------------------------
-- Time helpers
--------------------------------------------------------------------------------

{-# INLINABLE fromLowerBound #-}
fromLowerBound :: PlutusV2.POSIXTimeRange -> PlutusV2.POSIXTime
fromLowerBound rng =
  case PlutusV2.ivFrom rng of
    PlutusV2.LowerBound (PlutusV2.Finite t) _ -> t
    _                                         -> traceError "E1"

{-# INLINABLE toUpperBound #-}
toUpperBound :: PlutusV2.POSIXTimeRange -> PlutusV2.POSIXTime
toUpperBound rng =
  case PlutusV2.ivTo rng of
    PlutusV2.UpperBound (PlutusV2.Finite t) _ -> t
    _                                         -> traceError "E2"

{-# INLINABLE beforeDeadline #-}
beforeDeadline :: PlutusV2.TxInfo -> PlutusV2.POSIXTime -> Bool
beforeDeadline info dl = toUpperBound (PlutusV2.txInfoValidRange info) <= dl

{-# INLINABLE afterDeadline #-}
afterDeadline :: PlutusV2.TxInfo -> PlutusV2.POSIXTime -> Bool
afterDeadline info dl = fromLowerBound (PlutusV2.txInfoValidRange info) >= dl

--------------------------------------------------------------------------------
-- Script I/O helpers
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

{-# INLINABLE decodeDatum #-}
decodeDatum :: PlutusV2.TxOut -> EscrowDatum
decodeDatum o =
  case PlutusV2.txOutDatum o of
    PlutusV2.OutputDatum (PlutusV2.Datum d) ->
      case PlutusTx.fromBuiltinData d of
        Just ed -> ed
        Nothing -> traceError "E6"
    _ ->
      traceError "E7"

--------------------------------------------------------------------------------
-- Equality helpers
--------------------------------------------------------------------------------

{-# INLINABLE eqEscrowStatus #-}
eqEscrowStatus :: EscrowStatus -> EscrowStatus -> Bool
eqEscrowStatus a b =
  case (a, b) of
    (AwaitingFreelancer, AwaitingFreelancer) -> True
    (Active, Active)                         -> True
    (InDispute, InDispute)                   -> True
    _                                        -> False

{-# INLINABLE eqMilestoneStatus #-}
eqMilestoneStatus :: MilestoneStatus -> MilestoneStatus -> Bool
eqMilestoneStatus a b =
  case (a, b) of
    (Pending, Pending) -> True
    (Submitted x, Submitted y) -> x == y
    (NeedsRevision x, NeedsRevision y) -> x == y
    (Accepted, Accepted) -> True
    (Disputed, Disputed) -> True
    (ResolvedToFreelancer, ResolvedToFreelancer) -> True
    (ResolvedToClient, ResolvedToClient) -> True
    (TimedOutSplit, TimedOutSplit) -> True
    _ -> False

{-# INLINABLE eqMilestone #-}
eqMilestone :: Milestone -> Milestone -> Bool
eqMilestone a b =
     submitDeadline a   == submitDeadline b
  && reviewDeadline a   == reviewDeadline b
  && revisionDeadline a == revisionDeadline b
  && disputeDeadline a  == disputeDeadline b
  && milestoneAmount a  == milestoneAmount b
  && eqMilestoneStatus (milestoneStatus a) (milestoneStatus b)
  && revisionCount a    == revisionCount b
  && extensionUsed a    == extensionUsed b

{-# INLINABLE eqMilestones #-}
eqMilestones :: [Milestone] -> [Milestone] -> Bool
eqMilestones xs ys =
  case (xs, ys) of
    ([], []) -> True
    (x : xs', y : ys') -> eqMilestone x y && eqMilestones xs' ys'
    _ -> False

{-# INLINABLE eqPkhList #-}
eqPkhList :: [PlutusV2.PubKeyHash] -> [PlutusV2.PubKeyHash] -> Bool
eqPkhList xs ys =
  case (xs, ys) of
    ([], []) -> True
    (x : xs', y : ys') -> x == y && eqPkhList xs' ys'
    _ -> False

{-# INLINABLE sameStaticFields #-}
sameStaticFields :: EscrowDatum -> EscrowDatum -> Bool
sameStaticFields old new =
     projectId old       == projectId new
  && client old          == client new
  && freelancer old      == freelancer new
  && eqPkhList (reviewers old) (reviewers new)
  && platform old        == platform new
  && platformFeeRate old == platformFeeRate new
  && reviewerFeeRate old == reviewerFeeRate new
  && acceptDeadline old  == acceptDeadline new
  && maxRevisions old    == maxRevisions new
  && threadCs old        == threadCs new
  && threadTn old        == threadTn new

{-# INLINABLE sameEscrowDatum #-}
sameEscrowDatum :: EscrowDatum -> EscrowDatum -> Bool
sameEscrowDatum a b =
     projectId a       == projectId b
  && client a          == client b
  && freelancer a      == freelancer b
  && eqPkhList (reviewers a) (reviewers b)
  && platform a        == platform b
  && platformFeeRate a == platformFeeRate b
  && reviewerFeeRate a == reviewerFeeRate b
  && acceptDeadline a  == acceptDeadline b
  && eqMilestones (milestones a) (milestones b)
  && currentIndex a    == currentIndex b
  && maxRevisions a    == maxRevisions b
  && eqEscrowStatus (escrowStatus a) (escrowStatus b)
  && threadCs a        == threadCs b
  && threadTn a        == threadTn b

--------------------------------------------------------------------------------
-- Status helpers
--------------------------------------------------------------------------------

{-# INLINABLE isAwaitingFreelancer #-}
isAwaitingFreelancer :: EscrowStatus -> Bool
isAwaitingFreelancer s =
  case s of
    AwaitingFreelancer -> True
    _ -> False

{-# INLINABLE isActive #-}
isActive :: EscrowStatus -> Bool
isActive s =
  case s of
    Active -> True
    _ -> False

{-# INLINABLE isInDispute #-}
isInDispute :: EscrowStatus -> Bool
isInDispute s =
  case s of
    InDispute -> True
    _ -> False

{-# INLINABLE isPendingMs #-}
isPendingMs :: MilestoneStatus -> Bool
isPendingMs s =
  case s of
    Pending -> True
    _ -> False

{-# INLINABLE isDisputedMs #-}
isDisputedMs :: MilestoneStatus -> Bool
isDisputedMs s =
  case s of
    Disputed -> True
    _ -> False

{-# INLINABLE isActiveMilestoneState #-}
isActiveMilestoneState :: MilestoneStatus -> Bool
isActiveMilestoneState s =
  case s of
    Pending -> True
    Submitted _ -> True
    NeedsRevision _ -> True
    _ -> False

{-# INLINABLE isFinalizedMilestone #-}
isFinalizedMilestone :: MilestoneStatus -> Bool
isFinalizedMilestone s =
  case s of
    Accepted -> True
    ResolvedToFreelancer -> True
    ResolvedToClient -> True
    TimedOutSplit -> True
    _ -> False

--------------------------------------------------------------------------------
-- List / milestone helpers
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
    x : rest ->
      if p == x
        then True
        else containsPkh p rest

{-# INLINABLE noDuplicatePkhs #-}
noDuplicatePkhs :: [PlutusV2.PubKeyHash] -> Bool
noDuplicatePkhs xs =
  case xs of
    [] -> True
    x : rest ->
      if containsPkh x rest
        then False
        else noDuplicatePkhs rest

{-# INLINABLE getMilestone #-}
getMilestone :: Integer -> [Milestone] -> Maybe Milestone
getMilestone i xs =
  if i < 0
    then Nothing
    else go i xs
  where
    go n ys =
      case ys of
        [] -> Nothing
        z : zs ->
          if n == 0
            then Just z
            else go (n - 1) zs

{-# INLINABLE setMilestone #-}
setMilestone :: Integer -> Milestone -> [Milestone] -> Maybe [Milestone]
setMilestone i new xs =
  if i < 0
    then Nothing
    else go i xs
  where
    go n ys =
      case ys of
        [] -> Nothing
        z : zs ->
          if n == 0
            then Just (new : zs)
            else
              case go (n - 1) zs of
                Nothing -> Nothing
                Just zs' -> Just (z : zs')

{-# INLINABLE hasMilestone #-}
hasMilestone :: Integer -> [Milestone] -> Bool
hasMilestone i xs =
  case getMilestone i xs of
    Just _ -> True
    Nothing -> False

{-# INLINABLE validMilestone #-}
validMilestone :: Milestone -> Bool
validMilestone m =
     milestoneAmount m > 0
  && revisionCount m >= 0
  && submitDeadline m <= reviewDeadline m
  && reviewDeadline m <= revisionDeadline m
  && revisionDeadline m <= disputeDeadline m

{-# INLINABLE milestoneFeesValid #-}
milestoneFeesValid :: Integer -> Integer -> Milestone -> Bool
milestoneFeesValid platformRate reviewerRate m =
  let
    amt = milestoneAmount m
    pf  = feeOf amt platformRate
    rf  = feeOf amt reviewerRate
  in
       pf > 0
    && rf >= 2
    && pf + rf <= amt

{-# INLINABLE allMilestonesValid #-}
allMilestonesValid :: Integer -> Integer -> [Milestone] -> Bool
allMilestonesValid platformRate reviewerRate xs =
  case xs of
    [] -> True
    m : rest ->
         validMilestone m
      && milestoneFeesValid platformRate reviewerRate m
      && allMilestonesValid platformRate reviewerRate rest

{-# INLINABLE previousMilestonesFinalized #-}
previousMilestonesFinalized :: Integer -> [Milestone] -> Bool
previousMilestonesFinalized i xs =
  if i == 0
    then True
    else
      case xs of
        [] -> False
        m : rest ->
             isFinalizedMilestone (milestoneStatus m)
          && previousMilestonesFinalized (i - 1) rest

{-# INLINABLE futureMilestonesPending #-}
futureMilestonesPending :: [Milestone] -> Bool
futureMilestonesPending xs =
  case xs of
    [] -> True
    m : rest ->
         isPendingMs (milestoneStatus m)
      && revisionCount m == 0
      && not (extensionUsed m)
      && futureMilestonesPending rest

{-# INLINABLE futureMilestonesPendingAfter #-}
futureMilestonesPendingAfter :: Integer -> [Milestone] -> Bool
futureMilestonesPendingAfter i xs =
  if i < 0
    then False
    else
      case xs of
        [] -> True
        _ : rest ->
          if i == 0
            then futureMilestonesPending rest
            else futureMilestonesPendingAfter (i - 1) rest

{-# INLINABLE remainingAmountFrom #-}
remainingAmountFrom :: Integer -> [Milestone] -> Integer
remainingAmountFrom i xs =
  if i < 0
    then 0
    else go i xs
  where
    go n ys =
      case ys of
        [] -> 0
        m : rest ->
          if n == 0
            then milestoneAmount m + remainingAmountFrom 0 rest
            else go (n - 1) rest

--------------------------------------------------------------------------------
-- Reviewer / party validation
--------------------------------------------------------------------------------

{-# INLINABLE signedReviewerCount #-}
signedReviewerCount :: PlutusV2.TxInfo -> [PlutusV2.PubKeyHash] -> Integer
signedReviewerCount info rs =
  P.foldr
    (\r acc -> if txSignedBy info r then acc + 1 else acc)
    0
    rs

{-# INLINABLE reviewerQuorum #-}
reviewerQuorum :: PlutusV2.TxInfo -> [PlutusV2.PubKeyHash] -> Bool
reviewerQuorum info rs =
  signedReviewerCount info rs >= 2

{-# INLINABLE signedReviewerPaid #-}
signedReviewerPaid ::
  PlutusV2.TxInfo ->
  PlutusV2.PubKeyHash ->
  Integer ->
  Bool
signedReviewerPaid info reviewer amountEach =
  if txSignedBy info reviewer
    then valuePaidToPkh info reviewer >= amountEach
    else True

{-# INLINABLE signedReviewersPaid #-}
signedReviewersPaid ::
  PlutusV2.TxInfo ->
  [PlutusV2.PubKeyHash] ->
  Integer ->
  Bool
signedReviewersPaid info rs amountEach =
  case rs of
    [] ->
      True

    r : rest ->
         signedReviewerPaid info r amountEach
      && signedReviewersPaid info rest amountEach

{-# INLINABLE validParties #-}
validParties :: EscrowDatum -> Bool
validParties d =
     client d /= freelancer d
  && client d /= platform d
  && freelancer d /= platform d
  && countPkhList (reviewers d) == 3
  && noDuplicatePkhs (reviewers d)
  && not (containsPkh (client d) (reviewers d))
  && not (containsPkh (freelancer d) (reviewers d))
  && not (containsPkh (platform d) (reviewers d))

--------------------------------------------------------------------------------
-- Thread-token helpers
--------------------------------------------------------------------------------

{-# INLINABLE validThreadToken #-}
validThreadToken :: EscrowDatum -> Bool
validThreadToken d =
  not (threadCs d == adaSymbol && threadTn d == adaToken)

{-# INLINABLE threadPreserved #-}
threadPreserved :: PlutusV2.TxOut -> PlutusV2.TxOut -> EscrowDatum -> Bool
threadPreserved inRef outRef dat =
     assetCount (PlutusV2.txOutValue inRef)  (threadCs dat) (threadTn dat) == 1
  && assetCount (PlutusV2.txOutValue outRef) (threadCs dat) (threadTn dat) == 1

{-# INLINABLE threadReturned #-}
threadReturned :: PlutusV2.TxInfo -> EscrowDatum -> Bool
threadReturned info dat =
     tokenPaidToPkh info (client dat)   (threadCs dat) (threadTn dat) == 1
  || tokenPaidToPkh info (platform dat) (threadCs dat) (threadTn dat) == 1

--------------------------------------------------------------------------------
-- Datum invariant validation
--------------------------------------------------------------------------------

{-# INLINABLE validCurrentState #-}
validCurrentState :: EscrowDatum -> Bool
validCurrentState d =
  case getMilestone (currentIndex d) (milestones d) of
    Nothing -> False
    Just m ->
      case escrowStatus d of
        AwaitingFreelancer ->
             currentIndex d == 0
          && isPendingMs (milestoneStatus m)

        Active ->
          isActiveMilestoneState (milestoneStatus m)

        InDispute ->
          isDisputedMs (milestoneStatus m)

{-# INLINABLE validDatum #-}
validDatum :: EscrowDatum -> Bool
validDatum d =
     platformFeeRate d > 0
  && platformFeeRate d <= 10000
  && reviewerFeeRate d > 0
  && reviewerFeeRate d <= 10000
  && platformFeeRate d + reviewerFeeRate d <= 10000
  && maxRevisions d >= 0
  && currentIndex d >= 0
  && validParties d
  && validThreadToken d
  && allMilestonesValid (platformFeeRate d) (reviewerFeeRate d) (milestones d)
  && hasMilestone (currentIndex d) (milestones d)
  && previousMilestonesFinalized (currentIndex d) (milestones d)
  && futureMilestonesPendingAfter (currentIndex d) (milestones d)
  && validCurrentState d
  && remainingAmountFrom (currentIndex d) (milestones d) > 0

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------

{-# INLINABLE mkValidator #-}
mkValidator :: EscrowDatum -> EscrowAction -> PlutusV2.ScriptContext -> Bool
mkValidator oldDatum action ctx =
  let
    info  = PlutusV2.scriptContextTxInfo ctx
    inRef = findOwnInputOrFail ctx

    adaIn = lovelaceOf (PlutusV2.txOutValue inRef)

    cl  = client oldDatum
    fr  = freelancer oldDatum
    pf  = platform oldDatum
    idx = currentIndex oldDatum

    currentMilestone =
      case getMilestone idx (milestones oldDatum) of
        Just m  -> m
        Nothing -> traceError "E8"

    currentAmount = milestoneAmount currentMilestone

    platformFee =
      feeOf currentAmount (platformFeeRate oldDatum)

    reviewerFeePool =
      feeOf currentAmount (reviewerFeeRate oldDatum)

    reviewerCount =
      signedReviewerCount info (reviewers oldDatum)

    reviewerFeeEach =
      if reviewerCount <= 0
        then 0
        else divide reviewerFeePool reviewerCount

    freelancerNet =
      currentAmount - platformFee

    freelancerNetAfterDispute =
      currentAmount - platformFee - reviewerFeePool

    updateCurrentMilestone :: Milestone -> [Milestone]
    updateCurrentMilestone newMilestone =
      case setMilestone idx newMilestone (milestones oldDatum) of
        Just ms -> ms
        Nothing -> traceError "E9"

    requireContinuingOutput :: EscrowDatum -> Integer -> Bool
    requireContinuingOutput expected releasedAda =
      let
        outRef = getSingleContinuingOutput ctx
        newDat = decodeDatum outRef
        adaOut = lovelaceOf (PlutusV2.txOutValue outRef)
      in
           traceIfFalse "E10" (releasedAda >= 0)
        && traceIfFalse "E11" (releasedAda <= adaIn)
        && traceIfFalse "E12" (sameStaticFields oldDatum newDat)
        && traceIfFalse "E13" (sameEscrowDatum expected newDat)
        && traceIfFalse "E14" (validDatum newDat)
        && traceIfFalse "E15" (adaOut == adaIn - releasedAda)
        && traceIfFalse "E16" (threadPreserved inRef outRef oldDatum)

    closeToClient :: Integer -> Bool
    closeToClient clientAda =
      case assertNoContinuingOutput ctx of
        () ->
             traceIfFalse "E17" (valuePaidToPkh info cl >= clientAda)
          && traceIfFalse "E18" (threadReturned info oldDatum)

    closeWithPayout :: Integer -> Integer -> Bool
    closeWithPayout freelancerAda platformAda =
      let
        clientRemainder = adaIn - currentAmount
      in
        case assertNoContinuingOutput ctx of
          () ->
               traceIfFalse "E19" (clientRemainder >= 0)
            && traceIfFalse "E20" (valuePaidToPkh info fr >= freelancerAda)
            && traceIfFalse "E21" (valuePaidToPkh info pf >= platformAda)
            && traceIfFalse "E22" (valuePaidToPkh info cl >= clientRemainder)
            && traceIfFalse "E18" (threadReturned info oldDatum)

    continueOrCloseAfterPayout ::
      MilestoneStatus ->
      Integer ->
      Integer ->
      Bool
    continueOrCloseAfterPayout finalStatus payFreelancer payPlatform =
      let
        finalMilestone =
          currentMilestone { milestoneStatus = finalStatus }

        updatedMilestones =
          updateCurrentMilestone finalMilestone

        nextIndex =
          idx + 1
      in
        if hasMilestone nextIndex updatedMilestones
          then
            let
              expected =
                oldDatum
                  { milestones   = updatedMilestones
                  , currentIndex = nextIndex
                  , escrowStatus = Active
                  }
            in
                 traceIfFalse "E20" (valuePaidToPkh info fr >= payFreelancer)
              && traceIfFalse "E21" (valuePaidToPkh info pf >= payPlatform)
              && requireContinuingOutput expected currentAmount
          else
            closeWithPayout payFreelancer payPlatform

    enterDispute :: Bool
    enterDispute =
      let
        disputedMilestone =
          currentMilestone { milestoneStatus = Disputed }

        updatedMilestones =
          updateCurrentMilestone disputedMilestone

        expected =
          oldDatum
            { milestones   = updatedMilestones
            , escrowStatus = InDispute
            }
      in
        requireContinuingOutput expected 0

    validExtensionOrdering ::
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      Bool
    validExtensionOrdering newSubmit newReview newRevision newDispute =
         newSubmit <= newReview
      && newReview <= newRevision
      && newRevision <= newDispute

    extensionMovesForward ::
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      Bool
    extensionMovesForward newSubmit newReview newRevision newDispute =
         newSubmit   >= submitDeadline currentMilestone
      && newReview   >= reviewDeadline currentMilestone
      && newRevision >= revisionDeadline currentMilestone
      && newDispute  >= disputeDeadline currentMilestone
      && (    newSubmit   > submitDeadline currentMilestone
           || newReview   > reviewDeadline currentMilestone
           || newRevision > revisionDeadline currentMilestone
           || newDispute  > disputeDeadline currentMilestone
         )

    extensionReactivatesCurrentState ::
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.POSIXTime ->
      PlutusV2.TxInfo ->
      Bool
    extensionReactivatesCurrentState newSubmit newReview newRevision txInfo =
      let
        now = fromLowerBound (PlutusV2.txInfoValidRange txInfo)
      in
        case milestoneStatus currentMilestone of
          Pending ->
            newSubmit > now

          Submitted _ ->
            newReview > now

          NeedsRevision _ ->
            newRevision > now

          _ ->
            False

  in
       traceIfFalse "E23" (validDatum oldDatum)
    && traceIfFalse "E24"
         (adaIn >= remainingAmountFrom idx (milestones oldDatum))
    && traceIfFalse "E25" (currentAmount > 0)
    && traceIfFalse "E26" (platformFee > 0)
    && traceIfFalse "E27" (reviewerFeePool >= 2)
    && traceIfFalse "E28"
         (platformFee + reviewerFeePool <= currentAmount)
    && traceIfFalse "E29"
         (assetCount (PlutusV2.txOutValue inRef) (threadCs oldDatum) (threadTn oldDatum) == 1)
    && case action of

      FreelancerAccept ->
           traceIfFalse "E30"
             (isAwaitingFreelancer (escrowStatus oldDatum))
        && traceIfFalse "E31"
             (signedBy info fr)
        && traceIfFalse "E32"
             (beforeDeadline info (acceptDeadline oldDatum))
        && requireContinuingOutput
             (oldDatum { escrowStatus = Active })
             0

      ClientCancelBeforeAcceptance ->
           traceIfFalse "E30"
             (isAwaitingFreelancer (escrowStatus oldDatum))
        && traceIfFalse "E33"
             (signedBy info cl)
        && closeToClient adaIn

      ExtendMilestoneDeadlines newSubmit newReview newRevision newDispute ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E35"
             (signedBy info cl && signedBy info fr)
        && traceIfFalse "E36"
             (not (extensionUsed currentMilestone))
        && traceIfFalse "E37"
             (validExtensionOrdering newSubmit newReview newRevision newDispute)
        && traceIfFalse "E38"
             (extensionMovesForward newSubmit newReview newRevision newDispute)
        && traceIfFalse "E39"
             (extensionReactivatesCurrentState newSubmit newReview newRevision info)
        && let
             extended =
               currentMilestone
                 { submitDeadline   = newSubmit
                 , reviewDeadline   = newReview
                 , revisionDeadline = newRevision
                 , disputeDeadline  = newDispute
                 , extensionUsed    = True
                 }

             expected =
               oldDatum { milestones = updateCurrentMilestone extended }
           in
             requireContinuingOutput expected 0

      SubmitWork subHash ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E31"
             (signedBy info fr)
        && traceIfFalse "E40"
             (subHash /= Builtins.emptyByteString)
        && case milestoneStatus currentMilestone of
             Pending ->
                  traceIfFalse "E41"
                    (beforeDeadline info (submitDeadline currentMilestone))
               && let
                    updatedMilestone =
                      currentMilestone { milestoneStatus = Submitted subHash }

                    expected =
                      oldDatum { milestones = updateCurrentMilestone updatedMilestone }
                  in
                    requireContinuingOutput expected 0

             NeedsRevision _ ->
                  traceIfFalse "E42"
                    (beforeDeadline info (revisionDeadline currentMilestone))
               && let
                    updatedMilestone =
                      currentMilestone { milestoneStatus = Submitted subHash }

                    expected =
                      oldDatum { milestones = updateCurrentMilestone updatedMilestone }
                  in
                    requireContinuingOutput expected 0

             _ ->
               traceError "E43"

      ClientAcceptMilestone ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E33"
             (signedBy info cl)
        && case milestoneStatus currentMilestone of
             Submitted _ ->
               continueOrCloseAfterPayout
                 Accepted
                 freelancerNet
                 platformFee

             _ ->
               traceError "E44"

      ClientRejectMilestone ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E33"
             (signedBy info cl)
        && traceIfFalse "E45"
             (beforeDeadline info (reviewDeadline currentMilestone))
        && case milestoneStatus currentMilestone of
             Submitted h ->
                  traceIfFalse "E46"
                    (revisionCount currentMilestone < maxRevisions oldDatum)
               && let
                    updatedMilestone =
                      currentMilestone
                        { milestoneStatus = NeedsRevision h
                        , revisionCount   = revisionCount currentMilestone + 1
                        }

                    expected =
                      oldDatum { milestones = updateCurrentMilestone updatedMilestone }
                  in
                    requireContinuingOutput expected 0

             _ ->
               traceError "E44"

      RaiseDispute ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E47"
             (signedBy info cl || signedBy info fr)
        && case milestoneStatus currentMilestone of
             Submitted _ ->
                  traceIfFalse "E48"
                    (beforeDeadline info (reviewDeadline currentMilestone))
               && enterDispute

             NeedsRevision _ ->
                  traceIfFalse "E49"
                    (beforeDeadline info (revisionDeadline currentMilestone))
               && enterDispute

             _ ->
               traceError "E50"

      ResolveToFreelancer ->
           traceIfFalse "E51"
             (isInDispute (escrowStatus oldDatum))
        && traceIfFalse "E52"
             (reviewerQuorum info (reviewers oldDatum))
        && traceIfFalse "E53"
             (reviewerFeeEach > 0)
        && traceIfFalse "E54"
             (signedReviewersPaid info (reviewers oldDatum) reviewerFeeEach)
        && traceIfFalse "E55"
             (beforeDeadline info (disputeDeadline currentMilestone))
        && case milestoneStatus currentMilestone of
             Disputed ->
               continueOrCloseAfterPayout
                 ResolvedToFreelancer
                 freelancerNetAfterDispute
                 platformFee

             _ ->
               traceError "E56"

      ResolveToClient ->
           traceIfFalse "E51"
             (isInDispute (escrowStatus oldDatum))
        && traceIfFalse "E52"
             (reviewerQuorum info (reviewers oldDatum))
        && traceIfFalse "E53"
             (reviewerFeeEach > 0)
        && traceIfFalse "E54"
             (signedReviewersPaid info (reviewers oldDatum) reviewerFeeEach)
        && traceIfFalse "E55"
             (beforeDeadline info (disputeDeadline currentMilestone))
        && case milestoneStatus currentMilestone of
             Disputed ->
               case assertNoContinuingOutput ctx of
                 () ->
                      traceIfFalse "E17"
                        (valuePaidToPkh info cl >= adaIn - reviewerFeePool)
                   && traceIfFalse "E18"
                        (threadReturned info oldDatum)

             _ ->
               traceError "E56"

      ClientRefundAfterMissedDeadline ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E33"
             (signedBy info cl)
        && case milestoneStatus currentMilestone of
             Pending ->
                  traceIfFalse "E57"
                    (afterDeadline info (submitDeadline currentMilestone))
               && closeToClient adaIn

             NeedsRevision _ ->
                  traceIfFalse "E58"
                    (afterDeadline info (revisionDeadline currentMilestone))
               && closeToClient adaIn

             _ ->
               traceError "E59"

      FreelancerClaimAfterReviewTimeout ->
           traceIfFalse "E34"
             (isActive (escrowStatus oldDatum))
        && traceIfFalse "E31"
             (signedBy info fr)
        && traceIfFalse "E60"
             (afterDeadline info (reviewDeadline currentMilestone))
        && case milestoneStatus currentMilestone of
             Submitted _ ->
               continueOrCloseAfterPayout
                 Accepted
                 freelancerNet
                 platformFee

             _ ->
               traceError "E44"

      SplitAfterDisputeTimeout ->
           traceIfFalse "E51"
             (isInDispute (escrowStatus oldDatum))
        && traceIfFalse "E47"
             (signedBy info cl || signedBy info fr)
        && traceIfFalse "E61"
             (afterDeadline info (disputeDeadline currentMilestone))
        && case milestoneStatus currentMilestone of
             Disputed ->
               let
                 freelancerShare =
                   divide currentAmount 2

                 clientShare =
                   adaIn - freelancerShare
               in
                 case assertNoContinuingOutput ctx of
                   () ->
                        traceIfFalse "E62"
                          (valuePaidToPkh info fr >= freelancerShare)
                     && traceIfFalse "E63"
                          (valuePaidToPkh info cl >= clientShare)
                     && traceIfFalse "E18"
                          (threadReturned info oldDatum)

             _ ->
               traceError "E56"

--------------------------------------------------------------------------------
-- Boilerplate
--------------------------------------------------------------------------------

{-# INLINABLE mkWrapped #-}
mkWrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
mkWrapped d r c =
  check $
    mkValidator
      (unsafeFromBuiltinData d)
      (unsafeFromBuiltinData r)
      (unsafeFromBuiltinData c)

validator :: Validator
validator =
  mkValidatorScript $$(PlutusTx.compile [|| mkWrapped ||])

script :: PlutusV2.Script
script = unValidatorScript validator

--------------------------------------------------------------------------------
-- Serialisation / export
--------------------------------------------------------------------------------

serialiseToCBOR :: Validator -> LBS.ByteString
serialiseToCBOR v =
  let scr = unValidatorScript v
  in Serialise.serialise scr

serialiseToCBORBytes :: Validator -> BS.ByteString
serialiseToCBORBytes = LBS.toStrict . serialiseToCBOR

writeValidatorEnvelope :: H.FilePath -> Validator -> H.IO ()
writeValidatorEnvelope fp v = do
  let cbor = serialiseToCBORBytes v
      hex  = B16.encode cbor
      json = LBS.fromStrict $
        C8.concat
          [ C8.pack "{\n  \"type\": \"PlutusScriptV2\",\n  \"description\": \"Escrow V3 Validator\",\n  \"cborHex\": \""
          , hex
          , C8.pack "\"\n}\n"
          ]
  LBS.writeFile fp json

exportEscrowScript :: H.IO ()
exportEscrowScript =
  writeValidatorEnvelope "./assets/escrow-v3-validator.plutus" validator

--------------------------------------------------------------------------------
-- Error code index
--------------------------------------------------------------------------------
-- E1: Escrow: open-begin range
-- E2: Escrow: open-end range
-- E3: Escrow: own input not found
-- E4: Escrow: expected one continuing output
-- E5: Escrow: unexpected continuing output
-- E6: Escrow: bad inline datum
-- E7: Escrow: expected inline datum
-- E8: Escrow: invalid current milestone
-- E9: Escrow: cannot update milestone
-- E10: Escrow: released ADA negative
-- E11: Escrow: released ADA too large
-- E12: Escrow: static fields changed
-- E13: Escrow: wrong continuing datum
-- E14: Escrow: invalid new datum
-- E15: Escrow: wrong remaining ADA
-- E16: Escrow: thread token not preserved
-- E17: Escrow: client underpaid
-- E18: Escrow: thread token not returned
-- E19: Escrow: negative client remainder
-- E20: Escrow: freelancer underpaid
-- E21: Escrow: platform underpaid
-- E22: Escrow: client remainder underpaid
-- E23: Escrow: invalid old datum
-- E24: Escrow: escrow underfunded
-- E25: Escrow: invalid milestone amount
-- E26: Escrow: platform fee invalid
-- E27: Escrow: reviewer fee invalid
-- E28: Escrow: fees exceed milestone
-- E29: Escrow: thread token missing from input
-- E30: Escrow: must be awaiting freelancer
-- E31: Escrow: must be freelancer
-- E32: Escrow: acceptance deadline passed
-- E33: Escrow: must be client
-- E34: Escrow: must be active
-- E35: Escrow: extension requires client and freelancer
-- E36: Escrow: extension already used
-- E37: Escrow: invalid extension ordering
-- E38: Escrow: extension must move deadline forward
-- E39: Escrow: extension does not reactivate state
-- E40: Escrow: empty submission hash
-- E41: Escrow: submission deadline passed
-- E42: Escrow: revision deadline passed
-- E43: Escrow: milestone cannot be submitted
-- E44: Escrow: milestone not submitted
-- E45: Escrow: review deadline passed
-- E46: Escrow: max revisions reached
-- E47: Escrow: must be client or freelancer
-- E48: Escrow: submitted dispute after review deadline
-- E49: Escrow: revision dispute after revision deadline
-- E50: Escrow: milestone cannot enter dispute
-- E51: Escrow: must be in dispute
-- E52: Escrow: reviewer quorum missing
-- E53: Escrow: reviewer fee each invalid
-- E54: Escrow: signed reviewers underpaid
-- E55: Escrow: dispute deadline passed
-- E56: Escrow: milestone not disputed
-- E57: Escrow: submission deadline not passed
-- E58: Escrow: revision deadline not passed
-- E59: Escrow: invalid refund milestone state
-- E60: Escrow: review deadline not passed
-- E61: Escrow: dispute deadline not passed
-- E62: Escrow: freelancer split underpaid
-- E63: Escrow: client split underpaid