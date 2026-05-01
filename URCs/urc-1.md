---
urc: 1
title: Uniswap Request for Comment Process
author: Daniel Gretzke (@gretzke)
status: Final
created: 2026-03-30
---

## Abstract

A Uniswap Request for Comment (URC) is a design document providing information to the Uniswap ecosystem, or describing a new standard, interface, or process related to Uniswap. A URC should provide a clear technical description of the proposed change together with its rationale.

This document defines the URC process and specifies how proposals are authored, discussed, and finalized. It is maintained by the URC editorial team and updated directly when the process changes. Changes are logged in the changelog at the end of this document.

## Motivation

The Uniswap ecosystem produces widely used smart contracts and interfaces that are depended upon by a broad range of participants, including protocol developers, application builders, infrastructure providers, and external integrators.

Design discussions for such systems often occur within the teams responsible for implementation, code reviews, and informal conversations. The URC process provides a dedicated, durable format for capturing these discussions as structured public design documents. This allows architectural decisions, assumptions, and tradeoffs to be discussed openly and referenced independently of any specific implementation.

The goal of the URC process is to extend building in public to the design phase, enabling shared understanding and long-term reference for standards that are intended to be reused, extended, or relied upon by others.

## Specification

A URC is a proposal that describes process changes, meta-standards, or organizational conventions related to the Uniswap ecosystem. It can also define smart-contract standards, interfaces, execution models, or protocol-adjacent architectural patterns that are specific to the Uniswap ecosystem.

### Lifecycle and Statuses

Each URC has a status that reflects its stage in the process:

- **Draft** – The proposal is under active development.
- **Discussion** – The proposal is considered complete enough for broad review.
- **Last Call** – The proposal is believed to be ready for finalization and is open for final feedback.
- **Final** – The proposal is complete and no longer subject to change.
- **Superseded** – The proposal has been replaced by a newer proposal; a reference to the superseding proposal is added once it reaches Final status.
- **Withdrawn** – The proposal has been withdrawn by its author(s).

Once a proposal reaches Final, it is immutable. Any changes require a new proposal that explicitly supersedes the earlier one.

The table below defines each status, where the proposal lives at that stage, and who can advance it.

| Status | What it means | Lives where | Who can advance it |
|---|---|---|---|
| Draft | Under active development. Not ready for broad review. | GitHub (open PR, not yet merged) or forum draft post | Author only. Author moves to Discussion when ready. |
| Discussion | Complete enough for broad community review and feedback. | Forum — designated URC discussion category | Author moves it here. URC editor assigns number at this transition. |
| Last Call | Believed ready for finalization. Open for final feedback (14 days). | Forum (same thread) + GitHub PR with deadline in preamble | URC editor only. Normative changes revert to Discussion. |
| Final | Complete and no longer subject to change. | GitHub (merged to repo) + pinned Canonical URCs forum post | URC editor merges PR. |
| Superseded | Replaced by a newer Final URC. Reference to successor added. | Stays in GitHub repo. Status updated in preamble. Forum post updated with link to successor. | Only reachable from Final. A new URC must reach Final before this status is assigned. |
| Withdrawn | Withdrawn by author(s). The number is retired and never reused. | PR closed or status updated in repo. | Author only. Reachable from Draft or Discussion only. |

### Numbering

URCs are assigned numbers sequentially starting from URC-1. Numbers are assigned by the author when opening a GitHub pull request, and confirmed by a URC editor on review. If two pull requests claim the same number, the earlier-opened pull request takes priority.

Numbers are never reused. Withdrawn URCs retain their number in the repository with their final status noted.

### The URC Process

#### Step 1 — Draft

The author prepares a URC using the template in `/urc-template.md`. The draft should be complete enough to communicate the proposal clearly, but does not need to be final.

The author opens a pull request to the URC GitHub repository. The PR should include the draft document filed under `/URCs/` with the next available number. The status in the preamble should be set to `Draft`.

At this stage the proposal is under active development. The author may continue to revise it before requesting broader review.

#### Step 2 — Discussion

When the author considers the draft ready for broad community input, they:

1. Update the status in the preamble to `Discussion`
2. Post the proposal to the designated URC discussion category on the Uniswap governance forum
3. Notify a URC editor, who confirms the number and updates the repository

Discussion happens on the forum thread. The author is responsible for monitoring feedback, responding to questions, and incorporating changes into the GitHub document. The GitHub document is the canonical version — the forum thread is the discussion venue.

There is no fixed time limit for the Discussion stage. The author may keep a proposal in Discussion for as long as necessary to reach a stable state.

#### Step 3 — Last Call

When the author believes the proposal is ready for finalization, they request Last Call status from a URC editor. The editor reviews the proposal and, if satisfied, assigns Last Call status and sets a review end date — typically 14 days from the date of assignment.

The Last Call deadline is recorded in the preamble. The proposal is announced on the forum thread.

#### Step 4 — Final

If no normative changes are required during Last Call, a URC editor merges the pull request and marks the proposal as Final. The editor pins a canonical post in the Uniswap forum.

Final URCs are immutable.

### URC Editor Responsibilities

URC editors facilitate the process. They do not hold authority to approve or reject proposals on their merits — that is determined by community discussion and rough consensus.

Editors are responsible for:

- Confirming URC numbers when proposals enter Discussion
- Reviewing proposals for formatting completeness before assigning Last Call
- Assigning Last Call status and setting the review end date
- Merging Final proposals to the repository
- Maintaining the repository and keeping canonical forum posts up to date
- Working with authors to resolve formatting issues — not content disputes

### Proposal Format

Each URC is a design document with a standardized structure intended to make proposals easy to read, discuss, and reference over time.

The full proposal format — including required and optional sections — is defined in `/urc-template.md`. Every URC must include a preamble, abstract, specification, rationale, security considerations, and copyright section. A summary of each section is also included below.

#### Preamble

The preamble consists of RFC 822–style headers containing metadata about the proposal. This includes the proposal number, a short descriptive title, the proposal type, status, author information, and the date of creation. The title should be concise and must not include the proposal number.

The preamble may also include relationship fields.

- **Extends** indicates that the proposal builds upon or refines one or more earlier proposals. Extended proposals remain valid unless explicitly superseded.
- **Supersedes** indicates that the proposal replaces one or more earlier proposals. When a proposal is superseded, its status must be updated and a reference to the superseding proposal is added once that proposal has reached Final status.

#### Abstract

The abstract is a short technical summary describing the proposal at a high level. It should be written to be human-readable and concise, providing enough information for a reader to understand the general intent and scope of the proposal without reading the full document.

The abstract should summarize the process, convention, or meta-standard being proposed or the interface, design, or architectural change being specified.

#### Motivation (optional)

The motivation section explains why the proposal is necessary. It should describe the problem being addressed and why existing processes, conventions, or designs are insufficient.

This section may be omitted if the motivation is self-evident from the proposal.

#### Specification

The specification describes the proposal in sufficient detail to allow it to be clearly understood and evaluated.

For all URCs, the specification defines either the proposed process, rules, or conventions, including their scope and intended effect or the technical specification, including interfaces, expected behavior, constraints, and invariants. The specification should focus on what is required, not how it is implemented.

#### Rationale

The rationale section explains the reasoning behind the proposal. It should describe alternative approaches that were considered, tradeoffs that were made, and concerns raised during discussion.

The rationale serves as a record of the design or process decisions and their justification.

#### Backwards Compatibility (optional)

If the proposal introduces backwards-incompatible changes, this section must describe those incompatibilities and their consequences.

This may include changes to existing processes or conventions or incompatibilities with existing contracts or interfaces.

This section may be omitted if no such incompatibilities exist.

#### Test Cases (optional)

Test cases may be included where they meaningfully aid understanding of the proposal.

This section is optional and primarily relevant for URCs that define complex or sensitive behavior.

#### Reference Implementation (optional)

A reference or example implementation may be included to assist readers in understanding the proposal.

This may include example documents, templates, or workflows, or example smart-contract code or interfaces.

Inclusion of a reference implementation does not imply endorsement or required adoption.

#### Security Considerations

Proposals must include a section discussing relevant security considerations.

This should address risks related to process misuse, ambiguity, or unintended effects or security assumptions, risks, and design decisions related to smart-contract behavior.

#### Copyright

All URCs must be released under CC0 1.0. The copyright section must include the standard CC0 waiver text.

## Rationale

The URC process is intended to provide a consistent way to document and evaluate design decisions that affect the Uniswap ecosystem. Although these proposals are primarily written for use within the Uniswap ecosystem, some designs may prove broadly useful and evolve into widely reused infrastructure, such as Permit2. For this reason, the process emphasizes open discussion of design choices and tradeoffs. Making these considerations explicit allows proposals to be evaluated on their technical merits and, where applicable, adopted or extended by a wider audience.

This approach ensures that design decisions are recorded transparently and can serve both immediate ecosystem needs and longer-term reuse.

## Security Considerations

This proposal defines a documentation and design process and does not introduce direct security risks, but clearer and more transparent design discussions may help surface security-relevant assumptions and risks earlier in the development lifecycle.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
