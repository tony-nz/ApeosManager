# Apeos Manager

A macOS app for managing a fleet of FUJIFILM Apeos / ApeosPort multifunction printers:
supply levels, trays, device settings, user accounts, accounting limits, address books,
and job and fault logs — across every printer at once.

Built against Apeos C6570 / C3570 / C3530 devices. No vendor SDK is required.

## Features

- **Fleet overview** — status, toner and drum levels, counters, and a "needs attention"
  list aggregated across all printers.
- **Users** — the union of user accounts across the fleet, showing which printers hold
  each account. Create a user on many printers at once; edit membership per printer.
- **Account usage** — per-user copy / print / scan meters, colour and mono, with
  editable limits and counter reset.
- **Address book** — per printer and merged fleet-wide, with favourites.
- **Logs** — job history (who printed what, colour, size, sheets, impressions) and the
  device fault log, per printer and fleet-wide.
- **Discovery** — subnet scan to find printers.
- **Menu bar** — fleet status at a glance.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
export APEOS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
./build.sh
```

`security find-identity -v -p codesigning` lists available identities.

Signing is not optional in practice: keychain access is bound to the app's code
identity, so an unsigned build cannot read printer passwords saved by a previous build.

## The device API

None of this is publicly documented; it was derived by reading the web UI bundle each
device serves and verifying every call against real hardware. Two API families exist.

### JSON REST

Authenticated by a session cookie from `POST /LOGIN.cmd`, which takes form fields
`NAME` and `PSW`, each **Base64-encoded**, and answers `{"result":"0"}` on success.

| Endpoint | Purpose |
| --- | --- |
| `/home/api/device-status` | Status. Served without authentication on every model tested — the reliable discovery probe. |
| `/home/api/about` | Name, serial, firmware, contact fields |
| `/home/api/supplies-info` | Toner and drum levels |
| `/home/api/billing-counter` | Lifetime counters |
| `/home/api/paper-tray` | Tray sizes, media, status |
| `/home/api/faulthistory` | Fault log |
| `/jobs/api/job-list` | Job history |
| `/addressbook/api/addressbook` | Address book |
| `/permissions/api/*` | Capability descriptors only — **not** account data |

### SOAP (SSMI)

User, account and role records live here, not in the JSON API. SOAP 1.1, namespaces
are `http://www.fujifilm.com` + the service path, endpoints `/ssm/Management/Aaa/<Service>`.
The `/LOGIN.cmd` cookie authenticates; the `UsernameToken` header is optional.

## Findings worth knowing

Behaviour that is easy to get wrong, each confirmed against hardware:

- **Endpoint exposure varies by model.** Some devices serve `/home/api` anonymously;
  others return 403 for everything except `device-status`. Sign in before reading.
- **`GetUserInformation` `Responds` paths are relative to each `User`** —
  `Authentication/UserID`, not `Users/User/Authentication/UserID`. The prefixed form
  belongs to a different operation and silently selects nothing, returning HTTP 200
  with an empty result.
- **User types are `KO` and `CO`** (key operator / customer operator).
- **Sort order is `ascending`**, not `asc`; the abbreviation is rejected as
  `flt:InvalidMessage`.
- **`GetAccount` requires an `AccountType` element**, empty for all.
- **Creating a user uses `AddUserInformation` with an `Authentication` block only.**
  Including `Accounting` in the same request is rejected. Name and password are applied
  afterwards with `SetUserInformation`, which only works once the record exists.
- **A display name persists only via `Authentication/UserName`.** Writing
  `Accounting/UserName` returns success and discards the value.
- **Deleting a user does not use the `Users/User` shape** — its schema is
  `Category` (the literal string `Authentication`) plus `User{UserType, UserID}`.
- **`job-list` rejects any limit above 20** with HTTP 500. Paging uses
  `offsetJobID` plus `offsetJobIDType`, where the type is the previous job's *state*
  (`COMPLETED`), not a direction keyword.
- **`/addressbook/api/addressbook` requires `lang`**; without it every request is
  `400 INVALID_PARAMETER`. Its `ContactCount` is an *object* of per-channel totals with
  the real total nested inside under the same name.
- **Writes can succeed without applying.** Several operations return HTTP 200 with no
  fault and store nothing, so the app re-reads after every write and reports mismatches.

## Tools

`tools/` holds the probe scripts used to derive and verify the above. All read the
administrator password from the tty — never from a file, argument or environment
variable — and take the printer host as an argument.

Scripts prefixed `test-` that create, edit or delete records write to a live device.
They confirm before running and verify each step by reading back.

## Licence

MIT
