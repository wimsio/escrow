# Zonke Escrow V3 — Preprod Smart Contract Testing Project

**Date:** 2026-05-22  
**Network:** Cardano Preprod  
**Project Type:** Split-validator escrow dApp testing  
**Status:** Testing stage  
**Important Rule:** AI automation, autonomous AI execution, and “vibing” workflows are **not allowed and not permitted at this stage**. All tests must be manually reviewed, intentionally executed, and recorded by an assigned tester.



## 📑 Table of Contents

1. [🧭 Project Overview](#1--project-overview)  
2. [🎯 Testing Objectives](#2--testing-objectives)  
3. [🚫 Prohibited Testing Practices](#3--prohibited-testing-practices)  
4. [🏗️ Smart Contract Architecture](#4️--smart-contract-architecture)  
5. [👥 Roles and Wallets](#5--roles-and-wallets)  
6. [🧰 Preprod Environment Setup](#6--preprod-environment-setup)  
7. [🔐 Validator and Script Setup](#7--validator-and-script-setup)  
8. [💰 Project Funding Tests](#8--project-funding-tests)  
9. [🤝 Freelancer Acceptance Tests](#9--freelancer-acceptance-tests)  
10. [📤 Work Submission Tests](#10--work-submission-tests)  
11. [✅ Client Acceptance Tests](#11--client-acceptance-tests)  
12. [🔁 Rejection and Revision Tests](#12--rejection-and-revision-tests)  
13. [⏰ Deadline Extension Tests](#13--deadline-extension-tests)  
14. [↩️ Refund After Missed Deadline Tests](#14️--refund-after-missed-deadline-tests)  
15. [⏳ Freelancer Review Timeout Claim Tests](#15--freelancer-review-timeout-claim-tests)  
16. [⚖️ Dispute Creation Tests](#16️--dispute-creation-tests)  
17. [🧑‍⚖️ Reviewer Resolution Tests](#17️--reviewer-resolution-tests)  
18. [🪓 Split After Dispute Timeout Tests](#18--split-after-dispute-timeout-tests)  
19. [🧩 Multi-Milestone Tests](#19--multi-milestone-tests)  
20. [🛡️ Negative and Security Tests](#20️--negative-and-security-tests)  
21. [🖥️ Frontend and Off-Chain Tests](#21️--frontend-and-off-chain-tests)  
22. [📏 Property-Based Testing Plan](#22--property-based-testing-plan)  
23. [📘 Glossary of Terms](#23--glossary-of-terms)  
24. [🐞 Bug Report Template](#24--bug-report-template)  
25. [📊 Final Test Report Template](#25--final-test-report-template)  
26. [🎬 Stakeholder Demo Script](#26--stakeholder-demo-script)



## 1. 🧭 Project Overview

The **Zonke Escrow V3** project is a Cardano smart contract escrow system for milestone-based freelance work. It uses a split-validator architecture to reduce individual validator size and separate project lifecycle, milestone workflow, and dispute workflow.

The system supports project funding, freelancer acceptance, milestone-based work submission, client approval and rejection, deadline extension once per milestone, refunds after missed deadlines, freelancer claims after review timeout, disputes handled by reviewers, platform and reviewer fee payments, and deadlock protection through dispute-timeout splitting.



## 2. 🎯 Testing Objectives

1. Confirm that each validator enforces the correct state transition.
2. Confirm that all role permissions are correctly enforced.
3. Confirm that ADA, platform fees, reviewer fees, and project reserve ADA are paid correctly.
4. Confirm that one-milestone and multi-milestone projects work.
5. Confirm that honest Client and honest Freelancer protections work.
6. Confirm that dispute resolution cannot deadlock.
7. Confirm that invalid actions fail with expected validator trace codes.
8. Confirm that the frontend and Lucid off-chain code construct valid transactions.
9. Confirm that wallet cancellation and Blockfrost/proxy failures produce friendly user messages.
10. Confirm that reference scripts are disabled unless real `scriptRef` UTxOs exist.



## 3. 🚫 Prohibited Testing Practices

At this stage, the following are **not permitted**:

- AI automation executing transactions without human review.
- Autonomous testing bots submitting transactions.
- “Vibing” or informal untracked testing.
- Unreviewed AI-generated transaction flows.
- Unrecorded wallet role changes.
- Using mainnet funds.
- Testing with real Client or Freelancer payments.
- Enabling reference scripts unless scanner confirms `hasScriptRef: true`.

Every test must be intentional, manual, and recorded with wallet role, project ID, action performed, expected result, actual result, transaction hash, and any console error or validator trace.



## 4. 🏗️ Smart Contract Architecture

The current system uses three validators.

### 4.1 ProjectEscrowValidator

Responsible for:

- Freelancer accepting a project.
- Client cancelling before acceptance.
- Project advancement after milestone completion.
- Project closure to Client.

Expected project states:

```text
AwaitingFreelancer
Active
```

### 4.2 MilestoneValidator

Responsible for:

- Freelancer submitting work.
- Client rejecting work.
- Deadline extension once per milestone.
- Client accepting milestone.
- Client refund after missed deadline.
- Freelancer claim after review timeout.
- Raising dispute.

Expected milestone states:

```text
Pending
Submitted
NeedsRevision
```

### 4.3 DisputeValidator

Responsible for:

- Resolving dispute to Freelancer.
- Resolving dispute to Client.
- Splitting disputed funds after timeout.

Expected dispute outcomes:

```text
ResolveToFreelancer
ResolveToClient
SplitAfterTimeout
```



## 5. 👥 Roles and Wallets

Use separate wallets on Cardano Preprod.

| Role | Purpose | Required Actions |

| Client | Funds project and approves/rejects work | Fund, cancel, accept, reject, refund, dispute |
| Freelancer | Accepts project and submits work | Accept, submit, claim timeout, dispute |
| Platform | Receives platform fees | No signing required for normal tests |
| Reviewer 1 | Dispute reviewer | Co-sign dispute resolution |
| Reviewer 2 | Dispute reviewer | Co-sign dispute resolution |
| Reviewer 3 | Backup dispute reviewer | May be used in alternate resolution tests |

The Client wallet must also hold the project thread token/NFT before funding.



## 6. 🧰 Preprod Environment Setup

Required setup:

1. Browser with Eternl or another Cardano wallet supporting Preprod.
2. Wallet network set to Preprod.
3. Test ADA in all role wallets.
4. PHP Blockfrost proxy configured and working.
5. `validators.js` updated with current compiled CBOR.
6. `env.js` configured as the single source of settings.

Recommended `env.js` settings:

```js
export const APP_ENV = {
  NETWORK: "preprod",
  WALLET_NAME: "eternl",

  BLOCKFROST_URL: "https://cardano-preprod.blockfrost.io/api/v0",
  BLOCKFROST_PROJECT_ID: "",

  USE_PROXY: true,
  PROXY_URL: "./blockfrost-proxy.php",
  PROXY_MODE: "basic",

  USE_REFERENCE_SCRIPTS: false,

  PROJECT_REF_SCRIPT: "",
  MILESTONE_REF_SCRIPT: "",
  DISPUTE_REF_SCRIPT: "",

  REF_SCRIPT_MIN_ADA: 10_000_000n,

  PLATFORM_FEE_BPS: 500,
  REVIEWER_FEE_BPS: 500,
  ZONKE_WALLET_ADDRESS: ""
};
```



## 7. 🔐 Validator and Script Setup

After every Haskell validator change:

```bash
cabal build
cabal run vesting-exe
```

Then copy the new `cborHex` values into:

```text
validators.js
```

Required validator files:

```text
assets/project-escrow-validator.plutus
assets/milestone-validator.plutus
assets/dispute-validator.plutus
```

Important Project validator rule for one-milestone projects:

```haskell
adaOut >= adaIn - releasedAda
```

This allows the continuing Project UTxO to keep project reserve ADA and the thread token after the first milestone is created.



## 8. 💰 Project Funding Tests

### 8.1 Goal

Verify that Client can fund a project and create the initial Project UTxO.

### 8.2 Test Data

Use a one-milestone project first:

```text
Project ID: 101
Milestone amount: 10 ADA
Project reserve: 2–5 ADA
Platform fee rate: 500 or 1000 bps
Reviewer fee rate: 500 bps
Max revisions: 2
Accept deadline: future time
Submit deadline: future time
Review deadline: after submit deadline
Revision deadline: after review deadline
Dispute deadline: after revision deadline
```

### 8.3 Expected Result

```text
Project UTxO exists at ProjectEscrowValidator
Project status = AwaitingFreelancer
No Milestone UTxO exists
No Dispute UTxO exists
Project UTxO contains milestone amount + project reserve ADA
Project UTxO contains project thread token
```



## 9. 🤝 Freelancer Acceptance Tests

### 9.1 Goal

Verify that Freelancer can accept the project and activate the first milestone.

### 9.2 Action

Connect as Freelancer and click:

```text
Freelancer Accept
```

### 9.3 Expected Result

```text
Project UTxO continues
Project status = Active
Milestone UTxO is created
Milestone status = Pending
Milestone UTxO contains current milestone amount
Project UTxO keeps project reserve ADA + thread token
```

### 9.4 Negative Tests

- Non-Freelancer tries to accept.
- Freelancer accepts after acceptance deadline.
- Project thread token missing.
- Milestone output not created.
- Milestone output has wrong datum.
- Milestone output has wrong ADA amount.



## 10. 📤 Work Submission Tests

### 10.1 Goal

Verify that Freelancer can submit a work reference or hash.

### 10.2 Valid Test Inputs

For manual testing:

```text
demo milestone 1 work
```

For production-like testing:

```text
ipfs://bafy...
hex:<sha256-or-blake2b-hash>
git commit hash
release hash
```

### 10.3 Expected On-Chain Use

The smart contract does not inspect files, fetch IPFS, or validate content quality. It stores the submitted value as immutable evidence in the milestone datum.

Expected result:

```text
Milestone UTxO continues
Milestone status changes from Pending to Submitted <hash>
Milestone value remains unchanged
Freelancer signature is required
Submission hash must be non-empty
Submission must happen before submit deadline
```



## 11. ✅ Client Acceptance Tests

### 11.1 Goal

Verify that Client can approve submitted work and release payment.

### 11.2 Expected Result

For one milestone:

```text
Milestone UTxO closes
Project UTxO closes
Freelancer receives amount minus platform fee
Platform receives platform fee
Client receives project reserve ADA + thread token
```

Example:

```text
Milestone amount: 10 ADA
Platform fee: 10%
Freelancer receives: 9 ADA
Platform receives: 1 ADA
Client receives: reserve ADA + thread token
```

### 11.3 Size Risk

If the transaction fails with:

```text
Maximum transaction size expected max 16384
```

then Project, Milestone validators are still too large when attached together. Fix by shrinking validators or publishing real reference scripts using tooling that creates UTxOs with `scriptRef`.



## 12. 🔁 Rejection and Revision Tests

### 12.1 Flow

```text
Freelancer submits work
Client rejects
Milestone status becomes NeedsRevision
revisionCount increases by 1
Freelancer submits revised work
Client accepts or rejects again
```

### 12.2 Expected Result

```text
Milestone UTxO continues
Status = NeedsRevision <previous submission hash>
revisionCount = revisionCount + 1
Value unchanged
```

### 12.3 Negative Tests

- Reject after review deadline.
- Reject when milestone is not Submitted.
- Reject after max revisions reached.
- Non-Client tries to reject.



## 13. ⏰ Deadline Extension Tests

### 13.1 Goal

Verify that deadlines can be extended once per milestone.

### 13.2 Required Signatures

```text
Client
Freelancer
```

### 13.3 Expected Result

```text
Milestone UTxO continues
Deadlines are updated
extensionUsed = True
Value unchanged
```

### 13.4 Negative Tests

- Client alone signs.
- Freelancer alone signs.
- Extension does not move any deadline forward.
- Extension breaks deadline ordering.
- Extension does not reactivate current state.
- Second extension attempt.



## 14. ↩️ Refund After Missed Deadline Tests

### 14.1 Pending Milestone Refund

Flow:

```text
Milestone status = Pending
Submit deadline passes
Client clicks Refund After Missed Deadline
```

Expected:

```text
Milestone UTxO closes
Project UTxO closes
Client receives milestone amount + project reserve + thread token
```

### 14.2 NeedsRevision Refund

Flow:

```text
Milestone status = NeedsRevision
Revision deadline passes
Client clicks Refund After Missed Deadline
```

Expected:

```text
Milestone UTxO closes
Project UTxO closes
Client receives refund
```



## 15. ⏳ Freelancer Review Timeout Claim Tests

### 15.1 Flow

```text
Freelancer submits work
Review deadline passes
Freelancer clicks Claim After Review Timeout
```

### 15.2 Expected Result

```text
Milestone UTxO closes
Freelancer receives amount minus platform fee
Platform receives platform fee
Project advances or closes
```

For one-milestone project:

```text
Project closes
Client receives reserve ADA + thread token
```



## 16. ⚖️ Dispute Creation Tests

### 16.1 Flow

```text
Milestone status = Submitted or NeedsRevision
Client or Freelancer clicks Raise Dispute
```

### 16.2 Expected Result

```text
Milestone UTxO closes
Dispute UTxO is created
Project UTxO remains active
Dispute datum stores projectId, index, parties, reviewers, fees, amount, submission hash
```



## 17. 🧑‍⚖️ Reviewer Resolution Tests

### 17.1 Resolve To Freelancer

Required:

```text
Exactly two reviewer signatures
```

Expected payout:

```text
Freelancer = amount - platformFee - reviewerFeePool
Platform = platformFee
Reviewer 1 = reviewerFeePool / 2
Reviewer 2 = reviewerFeePool / 2
```

### 17.2 Resolve To Client

Choose one policy:

```text
Policy A: Platform fee only paid when Freelancer wins.
Policy B: Platform fee paid on every reviewer resolution.
```

The validator and off-chain code must match the chosen policy.



## 18. 🪓 Split After Dispute Timeout Tests

### 18.1 Flow

```text
Dispute deadline passes
Client or Freelancer clicks Split After Dispute Timeout
```

### 18.2 Expected Result

```text
Dispute UTxO closes
Freelancer receives 50%
Client receives 50% + remaining project reserve/funds
Reviewers receive 0
Project closes
```



## 19. 🧩 Multi-Milestone Tests

Use at least three milestones:

```text
Milestone 1: 5 ADA
Milestone 2: 7 ADA
Milestone 3: 10 ADA
```

Expected flow:

```text
Fund project
Freelancer accepts
Milestone 1 Pending
Submit M1
Client accepts M1
Milestone 2 Pending
Submit M2
Client accepts M2
Milestone 3 Pending
Submit M3
Client accepts M3
Project closes
```

Expected checks:

```text
Project currentIndex increments correctly
Only one active milestone exists
Future milestones are not created early
Project UTxO ADA decreases correctly
Final milestone closes project
Thread token is returned correctly
```



## 20. 🛡️ Negative and Security Tests

Run the following:

```text
Wrong signer tries each action
Wrong thread token
Wrong milestone amount
Wrong continuing datum
Wrong script address
Duplicate milestone outputs
Missing project input
Missing milestone input
Missing dispute input
Deadline range missing
Deadline too early or too late
Reviewer underpaid
Platform underpaid
Freelancer underpaid
Client underpaid
Attempt to change static datum fields
Attempt to change reviewers
Attempt to change freelancer/client/platform
Attempt to reuse spent UTxO
Submit empty hash
Extend twice
```



## 21. 🖥️ Frontend and Off-Chain Tests

Check:

```text
Proxy routes all Blockfrost calls through PHP
Wallet rejection shows friendly message
Project list groups Project + Milestone + Dispute UTxOs correctly
Buttons only appear for correct role
One-milestone project works
Multi-milestone project works
Submission hash displays correctly
Deadline fields display correctly
Reference scripts disabled unless real scriptRef UTxOs exist
```

Wallet rejection should show:

```text
Transaction signing was cancelled in the wallet.
```

not an uncaught error.



## 22. 📏 Property-Based Testing Plan

Generate random projects with:

```text
1 to N milestones
random milestone amounts
valid and invalid deadlines
valid and invalid fee rates
valid and invalid reviewer sets
random signer roles
random state transitions
```

Core invariants:

```text
Only Freelancer can accept project
Only Freelancer can submit work
Only Client can accept/reject/refund
Only Client or Freelancer can raise dispute
Exactly two reviewers resolve dispute
Escrow ADA is never lost
Thread token is preserved or returned
Only one active milestone exists
Final milestone closes project
Deadline extension can happen at most once
Client cannot steal before deadline
Freelancer cannot claim before review timeout
Reviewers cannot resolve after dispute deadline
```



## 23. 📘 Glossary of Terms

- **ADA** — Cardano native currency.
- **Lovelace** — Smallest ADA unit. `1 ADA = 1,000,000 lovelace`.
- **Client** — The party funding the project.
- **Freelancer** — The party completing the work.
- **Platform** — The party receiving platform fees.
- **Reviewer** — A dispute reviewer who can co-sign dispute resolution.
- **Project UTxO** — The UTxO controlled by `ProjectEscrowValidator`.
- **Milestone UTxO** — The UTxO controlled by `MilestoneValidator`.
- **Dispute UTxO** — The UTxO controlled by `DisputeValidator`.
- **Thread Token** — A unique token/NFT used to identify the project.
- **Datum** — On-chain state stored with a script UTxO.
- **Redeemer** — Action data used when spending a script UTxO.
- **CBOR** — Binary script format exported from compiled validators.
- **Validator** — Plutus script that enforces spending rules.
- **Project Reserve ADA** — Extra ADA kept in the Project UTxO so it can continue holding the thread token.
- **Submission Hash** — The work reference/hash submitted by Freelancer.
- **IPFS CID** — Content identifier for files uploaded to IPFS.
- **Review Deadline** — Deadline for Client to approve/reject submitted work.
- **Revision Deadline** — Deadline for Freelancer to resubmit after rejection.
- **Dispute Deadline** — Deadline for reviewers to resolve a dispute.
- **Reference Script** — A script stored in a UTxO and used via reference input.
- **`scriptRef`** — The actual reference-script field that must exist on a UTxO.
- **AI Automation** — Autonomous execution of tests or transactions by AI. Not allowed at this stage.
- **Vibing** — Informal untracked testing or AI-assisted guessing without recorded steps. Not allowed at this stage.



## 24. 🐞 Bug Report Template

```text
Title:
Environment:
Wallet:
Network:
Project ID:
Action:
Expected result:
Actual result:
Transaction hash:
Console error:
Validator trace code:
Screenshots:
Steps to reproduce:
```



## 25. 📊 Final Test Report Template

```text
Project:
Validator versions:
Frontend version:
Network:
Tester:
Date:

Summary:
Passed:
Failed:
Blocked:

Test results:
1. Fund Project:
2. Freelancer Accept:
3. Submit Work:
4. Client Accept:
5. Client Reject:
6. Deadline Extension:
7. Refund After Missed Deadline:
8. Claim After Review Timeout:
9. Raise Dispute:
10. Resolve To Freelancer:
11. Resolve To Client:
12. Split After Timeout:
13. Multi-Milestone:
14. Negative Tests:

Known Issues:
Required Fixes:
Ready for Demo: Yes / No
Ready for Mainnet: Yes / No
```



## 26. 🎬 Stakeholder Demo Script

### 26.1 Happy Path Demo

```text
1. Client connects wallet.
2. Client funds one-milestone project with thread token.
3. Freelancer connects wallet.
4. Freelancer accepts project.
5. Milestone UTxO appears.
6. Freelancer submits IPFS CID/hash.
7. Client reconnects.
8. Client approves milestone.
9. Freelancer receives payout.
10. Platform receives platform fee.
11. Project closes and thread token returns.
```

### 26.2 Dispute Demo

```text
1. Freelancer submits work.
2. Client rejects.
3. Freelancer submits revision.
4. Client or Freelancer raises dispute.
5. Two reviewers resolve dispute.
6. Reviewers receive fees.
7. Winning party receives funds.
8. Project advances or closes.
```
