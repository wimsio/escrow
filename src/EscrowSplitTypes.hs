{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module EscrowSplitTypes where

import qualified Prelude as H
import GHC.Generics (Generic)

import Plutus.V1.Ledger.Value (CurrencySymbol(..), TokenName(..))
import qualified Plutus.V2.Ledger.Api as PlutusV2
import PlutusTx.Builtins (BuiltinByteString)
import qualified PlutusTx
import PlutusTx.Prelude

--------------------------------------------------------------------------------
-- Shared on-chain types for split V3 escrow
--------------------------------------------------------------------------------

data ProjectStatus
  = ProjectAwaitingFreelancer
  | ProjectActive
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''ProjectStatus
PlutusTx.makeLift ''ProjectStatus

data MilestoneStatus
  = MilestonePending
  | MilestoneSubmitted BuiltinByteString
  | MilestoneNeedsRevision BuiltinByteString
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''MilestoneStatus
PlutusTx.makeLift ''MilestoneStatus

data MilestoneTerms = MilestoneTerms
  { mtSubmitDeadline   :: PlutusV2.POSIXTime
  , mtReviewDeadline   :: PlutusV2.POSIXTime
  , mtRevisionDeadline :: PlutusV2.POSIXTime
  , mtDisputeDeadline  :: PlutusV2.POSIXTime
  , mtAmount           :: Integer
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''MilestoneTerms
PlutusTx.makeLift ''MilestoneTerms

data ProjectDatum = ProjectDatum
  { pdProjectId              :: Integer
  , pdClient                 :: PlutusV2.PubKeyHash
  , pdFreelancer             :: PlutusV2.PubKeyHash
  , pdReviewers              :: [PlutusV2.PubKeyHash]
  , pdPlatform               :: PlutusV2.PubKeyHash
  , pdPlatformFeeRate        :: Integer
  , pdReviewerFeeRate        :: Integer
  , pdAcceptDeadline         :: PlutusV2.POSIXTime
  , pdMilestones             :: [MilestoneTerms]
  , pdCurrentIndex           :: Integer
  , pdMaxRevisions           :: Integer
  , pdStatus                 :: ProjectStatus
  , pdProjectThreadCs        :: CurrencySymbol
  , pdProjectThreadTn        :: TokenName
  , pdProjectValidatorHash   :: PlutusV2.ValidatorHash
  , pdMilestoneValidatorHash :: PlutusV2.ValidatorHash
  , pdDisputeValidatorHash   :: PlutusV2.ValidatorHash
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''ProjectDatum
PlutusTx.makeLift ''ProjectDatum

data MilestoneDatum = MilestoneDatum
  { mdProjectId            :: Integer
  , mdIndex                :: Integer
  , mdClient               :: PlutusV2.PubKeyHash
  , mdFreelancer           :: PlutusV2.PubKeyHash
  , mdReviewers            :: [PlutusV2.PubKeyHash]
  , mdPlatform             :: PlutusV2.PubKeyHash
  , mdPlatformFeeRate      :: Integer
  , mdReviewerFeeRate      :: Integer
  , mdMaxRevisions         :: Integer
  , mdSubmitDeadline       :: PlutusV2.POSIXTime
  , mdReviewDeadline       :: PlutusV2.POSIXTime
  , mdRevisionDeadline     :: PlutusV2.POSIXTime
  , mdDisputeDeadline      :: PlutusV2.POSIXTime
  , mdAmount               :: Integer
  , mdStatus               :: MilestoneStatus
  , mdRevisionCount        :: Integer
  , mdExtensionUsed        :: Bool
  , mdProjectValidatorHash :: PlutusV2.ValidatorHash
  , mdDisputeValidatorHash :: PlutusV2.ValidatorHash
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''MilestoneDatum
PlutusTx.makeLift ''MilestoneDatum

data DisputeDatum = DisputeDatum
  { ddProjectId            :: Integer
  , ddIndex                :: Integer
  , ddClient               :: PlutusV2.PubKeyHash
  , ddFreelancer           :: PlutusV2.PubKeyHash
  , ddReviewers            :: [PlutusV2.PubKeyHash]
  , ddPlatform             :: PlutusV2.PubKeyHash
  , ddPlatformFeeRate      :: Integer
  , ddReviewerFeeRate      :: Integer
  , ddDisputeDeadline      :: PlutusV2.POSIXTime
  , ddAmount               :: Integer
  , ddSubmissionHash       :: BuiltinByteString
  , ddProjectValidatorHash :: PlutusV2.ValidatorHash
  }
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''DisputeDatum
PlutusTx.makeLift ''DisputeDatum

--------------------------------------------------------------------------------
-- Redeemers
--------------------------------------------------------------------------------

data ProjectAction
  = PFreelancerAccept
  | PCancelBeforeAcceptance
  | PAdvanceAfterMilestone
  | PCloseToClient
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''ProjectAction
PlutusTx.makeLift ''ProjectAction

data MilestoneAction
  = MSubmitWork BuiltinByteString
  | MClientReject
  | MExtendDeadlines
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
      PlutusV2.POSIXTime
  | MClientAccept
  | MClientRefundAfterMissedDeadline
  | MFreelancerClaimAfterReviewTimeout
  | MRaiseDispute
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''MilestoneAction
PlutusTx.makeLift ''MilestoneAction

data DisputeAction
  = DResolveToFreelancer
  | DResolveToClient
  | DSplitAfterTimeout
  deriving stock (Generic, H.Show)

PlutusTx.unstableMakeIsData ''DisputeAction
PlutusTx.makeLift ''DisputeAction
