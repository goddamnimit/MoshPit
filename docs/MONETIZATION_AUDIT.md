# Monetization Audit (2026-10-08)

Scope: the single paid feature, saving a recording directly to Photos
(`Capability.saveVideoToPhotos`, product `com.moshpit.app.pro`, non-consumable).

## Verified correct
- **Flow (Release):** `recorder.stop` -> `AppModel.entitled()` -> `ProManager.allows` -> `.gated`
  outcome -> clip kept in gallery + `presentUpgrade` -> `UpgradeSheet` -> `purchase()` ->
  `isPro` flips -> `bindProManager` -> `completePendingProAction` saves to Photos.
- **Free paths never gated:** share sheet (only the built-in "Save Video" activity is excluded
  for video files while un-entitled, `ShareSheetPresenter.excludedActivityTypes`), Save to Files,
  snapshots, gallery, social export, NDI/MJPEG, recording. `Capability` has exactly one case
  (pinned by `testOnlySaveToPhotosIsGated`).
- **StoreKit 2:** `Transaction.updates` listener started in `startStoreKit()` at init;
  entitlement from `Transaction.currentEntitlements`; revoked transactions excluded;
  `finish()` on verified transactions; unverified results throw `failedVerification` and never
  entitle; `.userCancelled` is silent, `.pending` shows an info message, errors show inline;
  UserDefaults cache avoids launch flash and is reconciled at launch.
- **Apple requirements:** Restore Purchases button (`AppStore.sync`) on the sheet; price from
  `Product.displayPrice`; no redeem-code UI or copy anywhere in the UI; no dark patterns.
- **Local testing:** `MoshPit/Configuration/MoshPit.storekit` exists (non-consumable
  `com.moshpit.app.pro`, USD 4.99) and the scheme's Run action references it. Nothing needed
  recreating despite the deletion in e17f59a (it was re-added later).
- **Privacy manifest:** no tracking, no collected data, UserDefaults with CA92.1 only. A grep
  found no other required-reason API use (file timestamps, uptime, disk space). Matches docs.
- **Tests:** entitled -> Photos path (`testEntitledUserStopSavesToPhotos`); not entitled ->
  upgrade sheet and no Photos write (`testFreeUserStopTriggersUpgradeAndSkipsPhotos`);
  share exclusion policy; `debugSetPro` precedence over the DEBUG bypass is exercised by every
  gated test, since `entitled()` returns true under DEBUG unless overridden. 4 SKTestSession
  tests skip in this environment ("configuration not reachable"), as in the baseline.

## Fixed
- Product-load failure was swallowed (`try?`), leaving an "Unlock — …" button. Now
  `loadProduct()` reports success, the sheet retries on appear, and `purchase()` shows
  "Can't reach the App Store... tap Unlock to try again."
- `restore()` ignored `AppStore.sync` errors and then said "No previous purchase found",
  which is misleading offline or after a cancelled sign-in. It now reports the failure.
- Sheet copy now says sharing and Save to Files are free and the purchase only unlocks
  direct save to Photos. Button reads "Unlock" until the price loads.

## Notes (no change made)
- If the user taps Not Now, the pending save closure is kept; an Ask-to-Buy approval later
  would still save that clip if its temp file exists. Acceptable and arguably desirable.
- `ProManager` still carries the redeem-code plumbing, intentionally unreachable.

## Needs your action
## App Store Connect (read-only check, 2026-10-08, signed in by you)
Nothing was edited, submitted, or changed.

**Findings**
- App "MoshPit — Datamosh" iOS 1.0 (build 18) is **Rejected**: submitted Jul 9, Apple reply
  Jul 22 under **Guideline 2.1(b) App Completeness**: the app references unlocking but the
  In-App Purchase was never submitted for review. Apple asks you to submit the IAP and upload a
  new binary, and notes an App Review screenshot is required for the IAP.
- IAP `MoshPit Pro`, Product ID `com.moshpit.app.pro` matches the code exactly. Type
  Non-Consumable. Status **Prepare for Submission** (draft, never submitted). Localization
  en-US: "MoshPit Pro" / "Save your recorded videos to Photos." USD base price set (175
  regions). Family Sharing is off, matching the .storekit file. Reference name is "53".
- **The IAP's Review Information screenshot is empty.** This is what blocks "Add for Review".
- **Paid Apps Agreement is "Pending User Info"; no bank account and no tax form** on file.
  Until these are complete, IAP purchases cannot work in production and the IAP cannot go
  live. (Free Apps Agreement is Active.)

**Needs your action (in this order)**
- [ ] Business > complete the Paid Apps Agreement: add Bank Account and Tax Form(s).
- [ ] On the IAP page: upload the review screenshot (the in-app Unlock sheet, e.g. from the
      Simulator on a 6.5"/6.9" iPhone size), and optionally rename the Reference Name from "53".
- [ ] Add review notes to the IAP (see suggested text below).
- [ ] Upload a **new build** (this fixed 18 per Apple), then on the new version page add the IAP
      under "In-App Purchases", and resubmit. A first IAP must go with a new app version.
- [ ] Reply to Apple's message if you want to explain; not required.
- Suggested review note: "Record a clip and stop. The clip lands in the free gallery and a
  sheet offers a one-time Unlock for saving directly to Photos. Sharing and Save to Files are
  free. Test with a sandbox Apple ID; Restore Purchases is on the same sheet."

**Not checked** (ran out of scope this pass; verify in ASC): App Privacy answers vs.
PrivacyInfo.xcprivacy (should be Data Not Collected / no tracking), age rating, screenshots,
description, keywords, support/privacy URLs, review notes on the app version.

**Still on device**
- [ ] On device: Xcode Run = bypass active (Save Video, no sheet); Archive/TestFlight = paywall.
