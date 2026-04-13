# Product Requirements Document

## Cardano Escrow dApp (Lucid Off-Chain Version)

### Table of Contents

1. Executive Summary
2. Product Vision
3. Problem Statement
4. Goals and Non-Goals
5. Target Users and Roles
6. Product Scope
7. User Journeys
8. Functional Requirements
9. Business Rules and On-Chain Constraints
10. User Interface Requirements
11. Technical and Integration Requirements
12. Non-Functional Requirements
13. Success Criteria
14. Acceptance Criteria
15. Test Strategy and Test Requirements
16. Detailed Feature Test Matrix
17. Risks and Open Questions
18. Glossary



## 1. Executive Summary

This product is a browser-based Cardano escrow application that allows a client to fund a project escrow, a freelancer to accept and submit work, and an arbitrator to resolve disputes when needed. The current workflow supports the following lifecycle states and actions: **Funded**, **Accepted**, **Submitted**, and **Disputed**, with supported actions including **Accept**, **Submit Work**, **Approve**, **Refund**, **Raise Dispute**, **Resolve To Freelancer**, **Resolve To Client**, and **Cancel Before Acceptance**. The front end renders project cards that show project ID, amount, fee, freelancer payout, role, deadline, UTxO reference, and detailed escrow metadata such as participant key hashes, work hash, submission hash, and optional thread unit.   

This PRD defines the product requirements for making the Lucid-based escrow application production-ready in terms of feature behavior, UI expectations, role-based permissions, error handling, confirmation flow, and test coverage. It is based on the current validator rules, the Lucid off-chain action set, and the existing browser UI behavior.   



## 2. Product Vision

The product should provide a simple, transparent, and trust-minimized escrow experience for small project engagements on Cardano. A client should be able to lock funds into a validator-backed escrow, a freelancer should be able to accept work and submit proof of completion, and an arbitrator should be able to resolve disagreements according to explicit on-chain rules. The user experience should make the escrow state, available actions, and expected outcomes clear at every step.  



## 3. Problem Statement

Freelance project payments often rely on trust, manual coordination, and off-platform agreements. Clients need assurance that they can recover funds when work is not accepted or deadlines pass. Freelancers need assurance that funds have been committed before starting work. Arbitrators need a clearly defined resolution path when a dispute arises. The application addresses this by encoding project amount, fee, deadline, participant identities, work hashes, and state transitions in an escrow datum, then enforcing valid transitions through a Plutus V2 validator.  



## 4. Goals and Non-Goals

### Goals

The application must allow a connected wallet to fund a new escrow using a project ID, freelancer identifier, arbitrator identifier, amount, fee, deadline, work hash, and optional thread token unit. It must then allow authorized users to transition the escrow through the supported lifecycle using role-appropriate actions. The UI must show only actions that are valid for the current escrow status and for the currently connected user’s role.  

The application must preserve the same escrow front-end model already in place, including card-based project rendering, detailed escrow metadata, transaction links, proxy-backed networking, and wallet-based execution. It must remain compatible with browser CIP-30 wallets and use the configured preprod network.  

### Non-Goals

This version is not intended to provide multi-validator workflows, milestone escrows, partial releases, reputation systems, fiat settlement, identity verification, messaging, or document storage. The current scope is limited to a single-project escrow flow with four states and the existing set of state transitions and terminal resolutions.  



## 5. Target Users and Roles

### Client

The client is the wallet that funds the escrow. The client is responsible for creating the escrow, approving a submitted work result, refunding after the deadline where permitted, canceling before acceptance, and participating in disputes. In terminal payment paths, the client either receives a refund or authorizes payment to the freelancer and arbitrator.   

### Freelancer

The freelancer is the intended worker for the project. The freelancer can accept a funded escrow, submit work before the deadline, and raise disputes when appropriate. The freelancer is also the beneficiary of the payout path when a project is approved or resolved in the freelancer’s favor.   

### Arbitrator

The arbitrator is the third-party resolver. The arbitrator has no action during the normal happy path, but becomes active when an escrow reaches the disputed state. The arbitrator can resolve a dispute to the freelancer or to the client. In freelancer-favor resolutions, the arbitrator also receives the configured fee.   

### Viewer

A connected user who is not the client, freelancer, or arbitrator may still view escrows at the validator address but should not see privileged actions. The UI labels such a user as a viewer when no matching role is detected. 



## 6. Product Scope

The product scope includes wallet connection, escrow funding, escrow listing, optional project filtering, card-based escrow rendering, role-based action display, Lucid transaction construction and submission, and proxy-backed communication with Blockfrost. The system also includes support for an optional thread token that must be preserved across continuing outputs when used.   

The app must display escrow cards that summarize amount, fee, freelancer payout, deadline, UTxO reference, and detailed metadata including participant PKHs, work hash, submission hash, and thread unit. It must refresh the list of escrows after successful actions and support filtering by project ID. 



## 7. User Journeys

### Journey 1: Client funds an escrow

The client connects a wallet, enters project data, and funds an escrow. The escrow appears in the list with status **Funded**. From that point, the freelancer may accept it, while the client may cancel before acceptance or refund after the deadline if the validator rules allow it.  

### Journey 2: Freelancer accepts and submits work

A freelancer connects the wallet matching the freelancer PKH in the datum, sees the **Accept** action for a funded escrow, and transitions it to **Accepted**. Before the deadline, the freelancer may enter a submission hash or text and submit work, which transitions the escrow to **Submitted**.   

### Journey 3: Client approves payout

A client connects the wallet matching the client PKH in the datum, sees the **Approve** action for a submitted escrow, and closes out the escrow. The validator requires that the freelancer receive at least the payout amount and the arbitrator receive at least the fee amount.  

### Journey 4: Client refunds after deadline

If the escrow remains in **Funded** or **Accepted** state and the deadline has passed, the client may use **Refund After Deadline**. The validator requires that the client be refunded the escrow amount and that the action occur after the deadline.   

### Journey 5: Dispute and arbitration

If the escrow is in **Accepted** or **Submitted** state, either the client or freelancer may raise a dispute, moving the escrow to **Disputed**. The arbitrator may then resolve to the freelancer or to the client. The freelancer path pays the payout to the freelancer and fee to the arbitrator; the client path refunds the amount to the client.   



## 8. Functional Requirements

### 8.1 Wallet Connection

The application must allow a user to connect a browser CIP-30 wallet and show the connected wallet address, payment key hash, and validator address. The application must support a configurable wallet name and a proxy-backed preprod configuration.  

### 8.2 Escrow Funding

The application must allow a connected client wallet to fund a new escrow with the following required fields: project ID, freelancer identifier, arbitrator identifier, amount, fee, deadline, and work hash. The optional thread token unit may also be provided. The app must validate missing fields and invalid deadline formats before attempting submission. The initial escrow status must be **Funded**.  

### 8.3 Escrow Listing and Filtering

The application must fetch UTxOs at the validator address, decode inline datums into escrow records, and display valid escrow UTxOs as sorted cards. The application must support filtering by project ID. Non-escrow UTxOs at the same address must be ignored.  

### 8.4 Role-Based Actions

The application must display actions according to the current escrow state and the connected user role. A freelancer must see **Accept** only for funded escrows and **Submit Work** only for accepted escrows. A client must see **Cancel Before Acceptance** only for funded escrows, **Refund After Deadline** for funded or accepted escrows, and **Approve** only for submitted escrows. A client or freelancer must see **Raise Dispute** only for accepted or submitted escrows. An arbitrator must see **Resolve To Freelancer** and **Resolve To Client** only for disputed escrows. 

### 8.5 Submission Hash Handling

The application must allow a freelancer to enter a submission hash or plain text value when submitting work. The system must normalize this value into bytes for the datum and store it in the `submissionHash` field when transitioning to **Submitted**.  

### 8.6 Transaction Feedback

After a successful action, the application must show the transaction hash and render a link to view the transaction on a preprod explorer. The escrow list must then refresh so the UI reflects the latest state. 

### 8.7 Error Handling

The application must reject actions when the current wallet does not match the required role or when the escrow is in the wrong state. Error messages must clearly explain the failure, such as “Only the freelancer can accept” or “Escrow must be Submitted.” The system must also surface proxy or connection problems when the proxy is unreachable.  



## 9. Business Rules and On-Chain Constraints

The validator defines four statuses: **Funded**, **Accepted**, **Submitted**, and **Disputed**. It also defines eight supported actions: **Accept**, **SubmitWork**, **Approve**, **Refund**, **RaiseDispute**, **ResolveToFreelancer**, **ResolveToClient**, and **CancelBeforeAcceptance**. These are the canonical business states and operations for the product.  

The validator requires strict role-based authorization. Accept and SubmitWork require the freelancer signature. Approve, Refund, and CancelBeforeAcceptance require the client signature. ResolveToFreelancer and ResolveToClient require the arbitrator signature. RaiseDispute can be signed by either the client or the freelancer. 

State transitions are constrained. Accept is valid only when the current state is Funded. SubmitWork is valid only when the current state is Accepted. Approve is valid only when the current state is Submitted. Refund is valid only when the current state is Funded or Accepted. RaiseDispute is valid only when the current state is Accepted or Submitted. Resolution actions are valid only when the state is Disputed. CancelBeforeAcceptance is valid only when the current state is Funded.  

The validator also enforces value preservation and output structure. Continuing-output transitions must preserve the core fields, match the expected new datum, preserve the escrow ADA amount, and preserve the thread token when one is configured. Terminal transitions must not leave unexpected continuing outputs behind. 

Time-based rules are also enforced. SubmitWork must occur before the deadline, while Refund must occur only after the deadline. The off-chain code mirrors these constraints by applying a `validTo` window for submit and a `validFrom` window for refund.  



## 10. User Interface Requirements

The application must present escrows as readable cards with a visible status badge and key financial information. Each card must show the amount, fee, freelancer payout, current connected-user role label, deadline, and UTxO reference in its collapsed state, with detailed metadata shown in an expandable section. This structure is already reflected in the current UI and should remain the baseline design.  

The UI must show only actions that are relevant to the current role and state. This is a core usability requirement because it reduces invalid attempts and makes the workflow understandable without requiring users to read validator code. Buttons should be disabled while a transaction is in progress and must not trigger duplicate submissions on repeated clicks. 

The application must expose a clear connection area, a funding form, a refresh action, a project filter, a transaction status area, and a log/error surface. The proxy mode state should remain visible so users can confirm whether requests are flowing through the PHP Blockfrost proxy. 



## 11. Technical and Integration Requirements

The application must use Lucid as the off-chain transaction-building layer and a Plutus V2 validator referenced from the configured `validator.js` CBOR payload. It must construct transactions using the wallet selected via CIP-30 and the Blockfrost provider configured for preprod. 

The system must support proxy-backed access to Blockfrost. When proxy mode is enabled, the app must direct Blockfrost-related requests through `blockfrost-proxy.php`, and the browser UI must remain usable without direct CORS exposure. The proxy configuration should support the existing basic mode with `?endpoint=` routing and optional advanced mode.  

The product must continue to support inline datum decoding, wallet-based role identification using payment key hash, address parsing from either full address or 56-character PKH, and optional thread-token asset preservation. 



## 12. Non-Functional Requirements

The application must provide clear failure feedback for invalid user actions, wallet connection issues, proxy failures, malformed datum data, invalid ADA amounts, invalid dates, and unsupported address input. Error messages should be human-readable and actionable.  

The application must remain responsive during transaction submission and confirmation. Users must be able to understand whether the app is waiting for submission, confirmation, or refresh. The UI must also prevent accidental duplicate action execution by disabling controls during an in-flight action. 

The application must safely escape user-visible strings when rendering the escrow cards so that project data and metadata do not produce unsafe HTML output. 



## 13. Success Criteria

The product will be considered functionally complete when a tester can execute every intended escrow path end to end on preprod using the existing UI and a supported CIP-30 wallet. Specifically, the product must successfully support funding, acceptance, work submission, approval, refund after deadline, dispute raising, arbitrator resolution to freelancer, arbitrator resolution to client, and cancellation before acceptance. It must also correctly hide or reject invalid actions based on role or state.   



## 14. Acceptance Criteria

A feature will be accepted only if the following are true:

The wallet connection flow shows the connected wallet address, signer PKH, and validator address, and successfully loads escrow cards from the validator address. 

Funding a valid escrow creates a new **Funded** card that contains the expected amount, fee, payout, deadline, project ID, participant metadata, and work hash.  

Accepting a funded escrow as the freelancer changes its status to **Accepted** and removes the **Accept** button from users who are not authorized.  

Submitting work before the deadline as the freelancer changes the status to **Submitted** and stores the submission hash in the datum-backed UI.   

Approving a submitted escrow as the client closes the escrow and distributes payout and fee according to validator requirements.  

Refunding after the deadline as the client closes the escrow and returns the escrow amount to the client for valid refund states.  

Raising a dispute from accepted or submitted state changes the escrow to **Disputed**, and resolution actions become available only to the arbitrator.  

Resolving to freelancer closes the escrow and routes payout and fee correctly; resolving to client closes the escrow and routes refund correctly.  

Canceling before acceptance as the client closes a funded escrow and refunds the client.  



## 15. Test Strategy and Test Requirements

Testing must verify both the UI contract and the validator contract. The UI must be tested for correct rendering, action visibility, input validation, logging, wallet display, and transaction feedback. The on-chain contract must be tested indirectly through end-to-end flows that confirm the validator accepts only the correct signer, state, time window, and payout structure.  

Testing should be organized into five layers. First, **smoke tests** should verify wallet connection, proxy connectivity, validator address display, and escrow list rendering. Second, **happy-path tests** should validate the intended business flow from funded to approved. Third, **deadline-path tests** should validate refund timing and late submission rejection. Fourth, **dispute-path tests** should validate escalation and both arbitration outcomes. Fifth, **negative tests** should confirm that wrong-role and wrong-state actions are blocked by the UI and rejected by the contract if attempted.   

Testing must use at least three wallets: one client wallet, one freelancer wallet, and one arbitrator wallet. Each scenario should use a fresh escrow where the path is terminal, because approval, refund, cancellation, and dispute resolution consume the escrow UTxO and cannot be reused for later scenarios. This is implied by the validator’s “no continuing output” requirement for terminal actions. 



## 16. Detailed Feature Test Matrix

### 16.1 Wallet Connection Test

**Purpose:** Verify that a supported wallet can connect and initialize the app.
**Method:** Connect the selected CIP-30 wallet and verify that wallet address, signer PKH, validator address, proxy status, and current escrow list appear.
**Expected Result:** Connection succeeds, the correct addresses are displayed, and escrow fetching works without blocking the UI.  

### 16.2 Fund Escrow Test

**Purpose:** Verify escrow creation.
**Method:** Enter valid project ID, freelancer, arbitrator, amount, fee, deadline, work hash, and optional thread unit, then fund the escrow.
**Expected Result:** A new **Funded** escrow card appears with correct metadata and financial fields. The connected wallet becomes the client in the datum.  

### 16.3 Accept Escrow Test

**Purpose:** Verify freelancer acceptance.
**Method:** Connect as freelancer and click **Accept** on a funded escrow.
**Expected Result:** Status changes from **Funded** to **Accepted**. Only the freelancer should be able to complete this action.   

### 16.4 Submit Work Test

**Purpose:** Verify work submission before deadline.
**Method:** Connect as freelancer, enter submission text or hash, and click **Submit Work** on an accepted escrow before the deadline.
**Expected Result:** Status changes to **Submitted** and the submission hash is visible in escrow details. The action should fail if attempted after the deadline.   

### 16.5 Approve Escrow Test

**Purpose:** Verify client approval path.
**Method:** Connect as client and click **Approve** on a submitted escrow.
**Expected Result:** Escrow closes, freelancer receives payout, arbitrator receives fee, and the card disappears after refresh.  

### 16.6 Refund After Deadline Test from Funded

**Purpose:** Verify refund without acceptance after deadline.
**Method:** Create a funded escrow, wait until after the deadline, connect as client, and click **Refund After Deadline**.
**Expected Result:** Escrow closes and funds return to client. Refund before the deadline must fail.   

### 16.7 Refund After Deadline Test from Accepted

**Purpose:** Verify refund after acceptance when no successful completion occurs.
**Method:** Create and accept an escrow, wait until after deadline, connect as client, and click **Refund After Deadline**.
**Expected Result:** Escrow closes and client is refunded.  

### 16.8 Raise Dispute Test from Accepted

**Purpose:** Verify dispute escalation before submission.
**Method:** Connect as client or freelancer on an accepted escrow and click **Raise Dispute**.
**Expected Result:** Status changes to **Disputed**, and arbitrator resolution actions become available.   

### 16.9 Raise Dispute Test from Submitted

**Purpose:** Verify dispute escalation after submission and before approval.
**Method:** Connect as client or freelancer on a submitted escrow and click **Raise Dispute**.
**Expected Result:** Status changes to **Disputed**.  

### 16.10 Resolve to Freelancer Test

**Purpose:** Verify arbitrator closes dispute in freelancer’s favor.
**Method:** Connect as arbitrator and click **Resolve To Freelancer** on a disputed escrow.
**Expected Result:** Escrow closes, freelancer receives payout, and arbitrator receives fee.  

### 16.11 Resolve to Client Test

**Purpose:** Verify arbitrator closes dispute in client’s favor.
**Method:** Connect as arbitrator and click **Resolve To Client** on a disputed escrow.
**Expected Result:** Escrow closes and client receives refund.  

### 16.12 Cancel Before Acceptance Test

**Purpose:** Verify client cancellation before freelancer acceptance.
**Method:** Connect as client and click **Cancel Before Acceptance** on a funded escrow.
**Expected Result:** Escrow closes and client is refunded. The action must not be allowed after acceptance.   

### 16.13 Wrong-Role Tests

**Purpose:** Verify role enforcement.
**Method:** Attempt to accept as client, approve as freelancer, resolve as client, refund as freelancer, or submit as arbitrator.
**Expected Result:** The UI should not expose invalid actions, and any forced attempt should fail with a clear role-specific error. The validator should also reject a transaction lacking the required signer.   

### 16.14 Wrong-State Tests

**Purpose:** Verify state enforcement.
**Method:** Attempt to approve before submission, dispute after resolution, cancel after acceptance, or submit before acceptance.
**Expected Result:** The UI should suppress these actions and the off-chain code should reject them with clear state-specific errors.  

### 16.15 Deadline Boundary Tests

**Purpose:** Verify timing rules.
**Method:** Attempt submission after deadline and refund before deadline. Then repeat with valid timing.
**Expected Result:** Invalid timing attempts fail, while valid timing attempts succeed.  

### 16.16 Data Integrity Tests

**Purpose:** Verify escrow metadata consistency.
**Method:** Confirm that project ID, participant PKHs, amount, fee, deadline, work hash, submission hash, and thread token remain correct across state transitions.
**Expected Result:** Continuing-output paths preserve core fields and only update allowed fields such as status and submission hash.  

### 16.17 UI Rendering Tests

**Purpose:** Verify card accuracy and clarity.
**Method:** Inspect cards for funded, accepted, submitted, and disputed escrows under different connected wallets.
**Expected Result:** Cards display correct badge, action set, role label, and escrow details for each role.  



## 17. Risks and Open Questions

A major operational risk is network or provider inconsistency during transaction submission and confirmation, especially when routing through a proxy and waiting for Blockfrost indexing. The product should define whether the UI treats “submitted but not yet indexed” as success with pending confirmation or as a blocking state. The current app already distinguishes proxy connectivity and transaction feedback, so this behavior should be formalized before production rollout.  

Another risk is user confusion around role matching, since users may connect the wrong wallet and not understand why actions are unavailable. The current role-label rendering is helpful, but production readiness may require clearer guidance such as “You are connected as Freelancer” or “This wallet is not a participant in this escrow.” 

An open question is whether the product should remain preprod-only for testing or introduce an environment toggle for mainnet later. The current implementation is explicitly configured for preprod.  



## 18. Glossary

**ADA:** The native currency of Cardano. In the app, user-facing values are entered or displayed in ADA, while transactions operate in lovelace. 

**Lovelace:** The smallest unit of ADA, used internally for value calculations and validator checks.  

**CIP-30 Wallet:** A browser wallet interface used by the application to connect to supported Cardano wallets and sign transactions. 

**UTxO:** An unspent transaction output. Each active escrow exists as a script UTxO at the validator address.  

**Datum:** Structured data attached to the script output. In this product, the datum stores project ID, participant PKHs, amount, fee, deadline, work hash, submission hash, status, and optional thread token fields.  

**Redeemer:** The action payload supplied when spending a script UTxO. The escrow supports redeemers such as Accept, SubmitWork, Approve, Refund, RaiseDispute, ResolveToFreelancer, ResolveToClient, and CancelBeforeAcceptance.  

**Inline Datum:** A datum embedded directly in the UTxO rather than referenced by hash. The validator expects inline datum decoding for escrow outputs. 

**Thread Token:** An optional asset identified by policy ID and token name that must remain preserved across continuing outputs when used.  

**Continuing Output:** A new script output created when an escrow changes state but remains active, such as Funded to Accepted or Accepted to Submitted. 

**Terminal Transition:** A closing path that consumes the escrow without creating a new escrow output, such as approval, refund, cancellation, or dispute resolution. 

**PKH (PubKeyHash):** The payment key hash that identifies a wallet participant in the escrow datum and is used for signer checks and payout routing.  

