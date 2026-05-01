# Uniswap Requests for Comment (URCs)

Uniswap Requests for Comment (URCs) describe standards, interfaces, and processes for the Uniswap ecosystem. This repository is the canonical home for all URC documents.

## What is a URC?

A URC is a design document providing information to the Uniswap ecosystem, or describing a new standard, interface, or process related to Uniswap. URCs provide a clear technical description of the proposed change together with its rationale. See [URC-1](URCs/urc-1.md) for the full process specification.

## How to Submit a URC

1. **Copy the template.** Use [`urc-template.md`](urc-template.md) as your starting point.
2. **Write your proposal.** Fill in all required sections. Set the status to `Draft`.
3. **Open a pull request.** Add your proposal as `URCs/urc-N.md` where N is the next available number. Place any assets in `assets/urc-N/`.
4. **Request review.** A URC editor will review your submission for completeness.
5. **Start discussion.** When ready for community feedback, update the status to `Discussion` and post your proposal in the [URC Discussion category](https://gov.uniswap.org/) on the governance forum.

## URC Lifecycle

```
Draft → Discussion → Last Call (14 days) → Final
                                              ↓
                                          Superseded

Draft or Discussion → Withdrawn
Last Call → Discussion (if normative changes arise)
```

See [URC-1](URCs/urc-1.md) for complete status definitions and transition rules.

## Links

- [URC-1: Process Specification](URCs/urc-1.md)
- [URC Template](urc-template.md)
- [Uniswap Governance Forum](https://gov.uniswap.org/)
