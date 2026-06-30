---
urc: 1
title: Uniswap Request for Comment Process
author: Daniel Gretzke (@gretzke)
status: Draft
created: 2026-03-30
---

## Abstract

A Uniswap Request for Comment (URC) is a design document providing information to the Uniswap ecosystem, or describing a new standard or process related to Uniswap. A URC should provide a clear technical description of the proposed change together with its rationale.

URCs are meant to drive alignment around designs that other developers build on, and are not intended to be used for every product, protocol, or update Uniswap Labs or teams building on Uniswap ship.

This document defines the URC process and specifies how proposals are authored, discussed, and finalized. It is maintained by URC editors and updated directly when the process changes. Changes are logged in the changelog at the end of this document.

## Motivation

The Uniswap ecosystem produces widely used smart contracts and standards that are depended upon by a broad range of participants, including protocol developers, application builders, infrastructure providers, and external integrators.

Design discussions for such systems often occur internally within the teams responsible for implementation, code reviews, and informal conversations. The URC process provides a dedicated format for capturing these discussions as structured public design documents. This allows architectural decisions, assumptions, and tradeoffs to be discussed openly and referenced independently of any specific implementation.

The goal of the URC process is to extend building in public to the design phase, enabling shared understanding and long-term reference for standards that are intended to be reused, extended, or relied upon by others.

## Specification

A URC is a proposal that describes process changes, meta-standards, or organizational conventions related to the Uniswap ecosystem. It can also define smart-contract standards, interfaces, execution models, or protocol-adjacent architectural patterns that are specific to the Uniswap ecosystem.

### Lifecycle and Statuses

Each URC has a status reflecting its stage in the process. The table below defines each status, where the proposal lives at that stage, and who can advance it. Once a proposal reaches Final, it is immutable, any changes require a new proposal that explicitly supersedes the earlier one.

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

1. **Draft.** Prepare a URC using `/urc-template.md` and open a pull request to the URC GitHub repository, filing the document under `/URCs/` with the next available number and status `Draft`. Revise freely until ready for review.
2. **Discussion.** Set status to `Discussion`, post the proposal to the designated URC discussion category on the Uniswap governance forum, record the forum thread URL in the preamble's `discussions-to` field, and notify a URC editor to confirm the number. The GitHub document is canonical and the forum thread is the discussion venue. The author monitors feedback and incorporates changes. There is no time limit on this stage.
3. **Last Call.** Request Last Call from a URC editor. If satisfied, the editor assigns the status, sets a review end date (typically 14 days) documented in the preamble, and announces it on the forum thread.
4. **Final.** If no normative changes are required during Last Call, a URC editor merges the PR, marks the proposal `Final`, and pins a canonical post in the forum. Final URCs are immutable.

### URC Editor Responsibilities

The URC editors team consists of members of the Uniswap Labs team.

URC editors facilitate the process. They do not hold authority to approve or reject proposals on their merits — that is determined by community discussion and rough consensus.

Editors are responsible for:

- Confirming URC numbers when proposals enter Discussion
- Reviewing proposals for formatting completeness before assigning Last Call
- Assigning Last Call status and setting the review end date
- Merging Final proposals to the repository
- Maintaining the repository and keeping canonical forum posts up to date
- Working with authors to resolve formatting issues — not content disputes

### Proposal Format

Each URC is a design document with a standardized structure. The full format, including required and optional sections, is defined in `/urc-template.md`. Every URC must include a preamble, abstract, specification, rationale, security considerations, and copyright section. Motivation, backwards compatibility, test cases, and reference implementation are optional and included when relevant.

The preamble uses RFC 822–style headers: number, title (concise, without the number), type, status, author, creation date, and a `discussions-to` link to the forum thread (added when the proposal enters Discussion). It may also include relationship fields:

- **Extends:** the proposal builds upon or refines one or more earlier proposals, which remain valid unless explicitly superseded.
- **Supersedes:** the proposal replaces one or more earlier proposals. A superseded proposal's status must be updated and a reference to the superseding proposal added once that proposal reaches Final.

## Rationale

The URC process is intended to provide a consistent way to document and evaluate design decisions that affect the Uniswap ecosystem. Although these proposals are primarily written for use within the Uniswap ecosystem, some designs may prove broadly useful and evolve into widely reused infrastructure, such as Permit2. For this reason, the process emphasizes open discussion of design choices and tradeoffs. Making these considerations explicit allows proposals to be evaluated on their technical merits and, where applicable, adopted or extended by a wider audience.

This approach ensures that design decisions are recorded transparently and can serve both immediate ecosystem needs and longer-term reuse.

## Security Considerations

This proposal defines a documentation and design process and does not introduce direct security risks, but clearer and more transparent design discussions may help surface security-relevant assumptions and risks earlier in the development lifecycle.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
